import Foundation
import ModelShellProxy
import MSPApple
import MSPCore

struct PhotoSorterWorkspace: MSPWorkspace {
    static let workspaceTrashDisplayRootPath = "/废纸篓"
    static let workspaceTrashStorageRootPath = "/.msp/workspace-trash"

    var rootPath: String { "/" }
    let photoLibraryFileSystem: PhotoLibraryWorkspaceFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { photoLibraryFileSystem }

    init(
        localWorkspaceURL: URL,
        photoLibraryMount: PhotoLibraryMount,
        usesPresentationPhotoLibraryReads: Bool = false
    ) {
        var localPolicy = MSPWorkspaceFileSystemPolicy.default
        localPolicy.trashConfiguration = .displayedTrash(
            displayRootPath: Self.workspaceTrashDisplayRootPath,
            storageRootPath: Self.workspaceTrashStorageRootPath
        )
        let localFileSystem = MSPFileManagerWorkspaceFileSystem(
            rootURL: localWorkspaceURL,
            policy: localPolicy
        )
        self.photoLibraryFileSystem = PhotoLibraryWorkspaceFileSystem(
            localFileSystem: localFileSystem,
            photoLibraryMount: photoLibraryMount,
            photoLibraryReadMode: usesPresentationPhotoLibraryReads ? .cachedOnly : .blocking
        )
    }
}

struct PhotoLibraryWorkspaceFileSystem: MSPWorkspaceSequentialFileReading, MSPWorkspaceBatchDirectoryEnumerating, MSPWorkspaceBatchCopying, MSPWorkspaceTrashCapable {
    private static let presentationAssetEnumerationPageSize = 128

    let localFileSystem: MSPFileManagerWorkspaceFileSystem
    let photoLibraryMount: PhotoLibraryMount
    private let photoLibraryReadMode: PhotoLibraryReadMode

    fileprivate init(
        localFileSystem: MSPFileManagerWorkspaceFileSystem,
        photoLibraryMount: PhotoLibraryMount,
        photoLibraryReadMode: PhotoLibraryReadMode = .blocking
    ) {
        self.localFileSystem = localFileSystem
        self.photoLibraryMount = photoLibraryMount
        self.photoLibraryReadMode = photoLibraryReadMode
    }

    var policy: MSPWorkspaceFileSystemPolicy {
        var policy = localFileSystem.policy
        policy.trashConfiguration = photoLibraryMount.photoLibraryTrashConfiguration
        return policy
    }

    var trashConfiguration: MSPWorkspaceTrashConfiguration? {
        photoLibraryMount.photoLibraryTrashConfiguration
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            return MSPResolvedPath(virtualPath: virtualPath)
        }
        return try localFileSystem.resolve(path, from: currentDirectory)
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            return try photoLibraryMount.photoLibraryTrashFileInfo(atDisplayPath: virtualPath)
        }
        if isPhotoLibraryPath(virtualPath) {
            return try photoLibraryStat(virtualPath, readMode: photoLibraryReadMode)
        }
        return try localFileSystem.stat(path, from: currentDirectory)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        try listDirectory(path, from: currentDirectory, limit: nil)
    }

    func listDirectory(_ path: String, from currentDirectory: String, limit: Int?) throws -> [MSPDirectoryEntry] {
        try listDirectory(path, from: currentDirectory, offset: 0, limit: limit)
    }

    func listDirectory(
        _ path: String,
        from currentDirectory: String,
        offset: Int,
        limit: Int?
    ) throws -> [MSPDirectoryEntry] {
        try listDirectory(
            path,
            from: currentDirectory,
            offset: offset,
            limit: limit,
            photoLibraryReadMode: photoLibraryReadMode
        )
    }

    func listDirectoryForPresentation(
        _ path: String,
        from currentDirectory: String,
        offset: Int = 0,
        limit: Int? = nil
    ) throws -> [MSPDirectoryEntry] {
        try listDirectory(
            path,
            from: currentDirectory,
            offset: offset,
            limit: limit,
            photoLibraryReadMode: .cachedOnly
        )
    }

    private func listDirectory(
        _ path: String,
        from currentDirectory: String,
        offset: Int,
        limit: Int?,
        photoLibraryReadMode: PhotoLibraryReadMode
    ) throws -> [MSPDirectoryEntry] {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            return try photoLibraryDirectoryEntries(
                virtualPath,
                offset: offset,
                limit: limit,
                readMode: photoLibraryReadMode
            )
        }

        if virtualPath == "/" {
            var entries = try localFileSystem.listDirectory(path, from: currentDirectory)
            entries.removeAll { $0.virtualPath == PhotoSorterWorkspace.workspaceTrashDisplayRootPath }
            entries.append(contentsOf: rootPhotoDirectoryEntries())
            entries.sort { $0.name < $1.name }
            return slice(entries, offset: offset, limit: limit)
        }
        return try localFileSystem.listDirectory(
            path,
            from: currentDirectory,
            offset: offset,
            limit: limit
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        try await enumerateDirectory(
            path,
            from: currentDirectory,
            options: .all,
            visitor: visitor
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            try await enumeratePhotoLibraryDirectoryEntries(
                virtualPath,
                options: options,
                readMode: photoLibraryReadMode,
                visitor: visitor
            )
            return
        }

        try await localFileSystem.enumerateDirectory(path, from: currentDirectory) { entry in
            guard options.includes(entry.type) else {
                return true
            }
            return try await visitor(entry)
        }
        if virtualPath == "/", options.includes(.directory) {
            for entry in rootPhotoDirectoryEntries() {
                guard try await visitor(entry) else {
                    return
                }
            }
        }
    }

    func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            try await enumeratePhotoLibraryDirectoryEntryBatches(
                virtualPath,
                options: options,
                batchSize: batchSize,
                readMode: photoLibraryReadMode,
                visitor: visitor
            )
            return
        }

        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        var shouldContinue = true

        try await localFileSystem.enumerateDirectory(path, from: currentDirectory) { entry in
            guard options.includes(entry.type) else {
                return true
            }
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                shouldContinue = try await visitor(batch)
                batch.removeAll(keepingCapacity: true)
            }
            return shouldContinue
        }

        if shouldContinue, virtualPath == "/", options.includes(.directory) {
            for entry in rootPhotoDirectoryEntries() {
                batch.append(entry)
                if batch.count >= resolvedBatchSize {
                    shouldContinue = try await visitor(batch)
                    batch.removeAll(keepingCapacity: true)
                    guard shouldContinue else {
                        return
                    }
                }
            }
        }

        if shouldContinue, !batch.isEmpty {
            _ = try await visitor(batch)
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
        }
        return try localFileSystem.readSymbolicLink(path, from: currentDirectory)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            let info = try photoLibraryStat(virtualPath, readMode: photoLibraryReadMode)
            guard info.type == .regularFile else {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
            guard let data = try photoLibraryMount.workspaceFileData(for: virtualPath) else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return data
        }
        return try localFileSystem.readFile(path, from: currentDirectory)
    }

    func readFileRange(
        _ path: String,
        from currentDirectory: String,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            let data = try readFile(virtualPath, from: "/")
            guard length > 0, offset < UInt64(data.count) else {
                return Data()
            }
            let start = Int(offset)
            let end = min(data.count, start + length)
            return data.subdata(in: start..<end)
        }
        return try localFileSystem.readFileRange(
            path,
            from: currentDirectory,
            offset: offset,
            length: length
        )
    }

    func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String
    ) throws -> (any MSPWorkspaceSequentialFileReader)? {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            return nil
        }
        return try localFileSystem.openSequentialFileReader(path, from: currentDirectory)
    }

    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        try localFileSystem.writeFile(path, data: data, from: currentDirectory, options: options)
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        try localFileSystem.appendFile(
            path,
            data: data,
            from: currentDirectory,
            options: options,
            creationMode: creationMode
        )
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if isPhotoLibraryPath(virtualPath) {
            guard PhotoLibraryMount.parentPath(of: virtualPath) == PhotoLibraryMount.userAlbumRootPath else {
                throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
            }
            if !intermediates {
                _ = try stat(PhotoLibraryMount.userAlbumRootPath, from: "/")
            }
            if (try? stat(virtualPath, from: "/")) != nil {
                throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
            }
            try photoLibraryMount.createPendingUserAlbum(at: virtualPath)
            return
        }
        try localFileSystem.createDirectory(path, from: currentDirectory, intermediates: intermediates)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        try localFileSystem.touch(path, from: currentDirectory)
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        if isPhotoLibraryPath(virtualPath) {
            let info = try photoLibraryStat(virtualPath, readMode: photoLibraryReadMode)
            if info.type == .directory {
                guard recursive else {
                    throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
                }
                guard virtualPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/") else {
                    throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
                }
                try photoLibraryMount.trashWorkspaceUserAlbum(at: virtualPath)
                return
            }
            try photoLibraryMount.trashWorkspaceAsset(at: virtualPath)
            return
        }
        try localFileSystem.remove(path, from: currentDirectory, recursive: recursive)
    }

    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws {
        let source = normalizedPath(sourcePath, from: currentDirectory)
        let destination = normalizedPath(destinationPath, from: currentDirectory)
        let sourceIsPhoto = isPhotoLibraryPath(source)
        let destinationIsPhoto = isPhotoLibraryPath(destination)
        if sourceIsPhoto || destinationIsPhoto {
            guard sourceIsPhoto, destinationIsPhoto else {
                throw MSPWorkspaceFileSystemError.accessDenied(sourceIsPhoto ? destination : source)
            }
            if !options.contains(.overwriteExisting),
               (try? stat(destination, from: "/")) != nil {
                throw MSPWorkspaceFileSystemError.alreadyExists(destination)
            }
            try photoLibraryMount.copyWorkspaceAsset(from: source, to: destination)
            return
        }
        try localFileSystem.copy(sourcePath, to: destinationPath, from: currentDirectory, options: options)
    }

    func copy(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        guard !requests.isEmpty else {
            return
        }
        let normalizedRequests = requests.map {
            MSPFileCopyRequest(
                sourcePath: normalizedPath($0.sourcePath, from: currentDirectory),
                destinationPath: normalizedPath($0.destinationPath, from: currentDirectory)
            )
        }
        let allPhotoLibraryCopies = normalizedRequests.allSatisfy {
            isPhotoLibraryPath($0.sourcePath) && isPhotoLibraryPath($0.destinationPath)
        }
        if allPhotoLibraryCopies {
            if !options.contains(.overwriteExisting) {
                for request in normalizedRequests where (try? stat(request.destinationPath, from: "/")) != nil {
                    throw MSPWorkspaceFileSystemError.alreadyExists(request.destinationPath)
                }
            }
            try photoLibraryMount.copyWorkspaceAssets(normalizedRequests.map {
                PhotoLibraryMount.WorkspaceAssetCopyRequest(
                    sourcePath: $0.sourcePath,
                    destinationPath: $0.destinationPath
                )
            })
            return
        }

        let allLocalCopies = normalizedRequests.allSatisfy {
            !isPhotoLibraryPath($0.sourcePath) && !isPhotoLibraryPath($0.destinationPath)
        }
        if allLocalCopies {
            for request in normalizedRequests {
                try localFileSystem.copy(
                    request.sourcePath,
                    to: request.destinationPath,
                    from: "/",
                    options: options
                )
            }
            return
        }

        for request in requests {
            try copy(
                request.sourcePath,
                to: request.destinationPath,
                from: currentDirectory,
                options: options
            )
        }
    }

    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws {
        let source = normalizedPath(sourcePath, from: currentDirectory)
        let destination = normalizedPath(destinationPath, from: currentDirectory)
        let sourceIsPhoto = isPhotoLibraryPath(source)
        let destinationIsPhoto = isPhotoLibraryPath(destination)
        if sourceIsPhoto || destinationIsPhoto {
            guard sourceIsPhoto, destinationIsPhoto else {
                throw MSPWorkspaceFileSystemError.accessDenied(sourceIsPhoto ? destination : source)
            }
            if !options.contains(.overwriteExisting),
               (try? stat(destination, from: "/")) != nil {
                throw MSPWorkspaceFileSystemError.alreadyExists(destination)
            }
            try photoLibraryMount.moveWorkspaceAsset(from: source, to: destination)
            return
        }
        try localFileSystem.move(sourcePath, to: destinationPath, from: currentDirectory, options: options)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        let source = normalizedPath(sourcePath, from: currentDirectory)
        let destination = normalizedPath(linkPath, from: currentDirectory)
        guard !isPhotoLibraryPath(source), !isPhotoLibraryPath(destination) else {
            throw MSPWorkspaceFileSystemError.accessDenied(isPhotoLibraryPath(source) ? source : destination)
        }
        try localFileSystem.createHardLink(source: sourcePath, at: linkPath, from: currentDirectory)
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        let destination = normalizedPath(linkPath, from: currentDirectory)
        guard !isPhotoLibraryPath(destination) else {
            throw MSPWorkspaceFileSystemError.accessDenied(destination)
        }
        try localFileSystem.createSymbolicLink(target: target, at: linkPath, from: currentDirectory)
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        let virtualPath = normalizedPath(path, from: currentDirectory)
        guard !isPhotoLibraryPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        try localFileSystem.chmod(path, mode: mode, from: currentDirectory)
    }

    private func photoLibraryStat(_ virtualPath: String, readMode: PhotoLibraryReadMode) throws -> MSPFileInfo {
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            return try photoLibraryMount.photoLibraryTrashFileInfo(atDisplayPath: virtualPath)
        }
        if photoLibraryDirectoryPathExists(virtualPath) {
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .directory,
                modificationDate: Date(),
                permissions: 0o555
            )
        }
        if isDirectUserAlbumPath(virtualPath) {
            guard let album = userAlbums(readMode: readMode)?.first(where: { $0.virtualPath == virtualPath }) else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return albumFileInfo(virtualPath: album.virtualPath)
        }
        if readMode == .cachedOnly {
            guard let asset = photoLibraryMount.presentationAsset(at: virtualPath) else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return assetFileInfo(asset)
        }
        switch photoLibraryMount.cachedAssetLookup(at: virtualPath) {
        case let .found(asset):
            return assetFileInfo(asset)
        case .knownMissing:
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        case .unknown:
            break
        }
        if let cachedAlbums = photoLibraryMount.cachedUserAlbums(),
           let album = cachedAlbums.first(where: { $0.virtualPath == virtualPath }) {
            return albumFileInfo(virtualPath: album.virtualPath)
        }
        if isUserAlbumDescendantPath(virtualPath) {
            guard let asset = photoLibraryMount.presentationAsset(at: virtualPath) else {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return assetFileInfo(asset)
        }
        if let asset = try photoLibraryMount.asset(at: virtualPath) {
            return assetFileInfo(asset)
        }
        if let album = photoLibraryMount.userAlbums().first(where: { $0.virtualPath == virtualPath }) {
            return albumFileInfo(virtualPath: album.virtualPath)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    private func photoLibraryDirectoryEntries(
        _ virtualPath: String,
        offset: Int,
        limit: Int?,
        readMode: PhotoLibraryReadMode
    ) throws -> [MSPDirectoryEntry] {
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            return slice(
                try photoLibraryMount.listPhotoLibraryTrash(virtualPath),
                offset: offset,
                limit: limit
            )
        }

        switch virtualPath {
        case "/相册":
            return slice([
                directoryEntry(name: "系统", virtualPath: PhotoLibraryMount.systemAlbumRootPath),
                directoryEntry(name: "用户", virtualPath: PhotoLibraryMount.userAlbumRootPath)
            ], offset: offset, limit: limit)
        case "/相册/系统":
            return slice(PhotoLibraryMount.systemAlbumDirectories.map { directoryName in
                directoryEntry(
                    name: directoryName,
                    virtualPath: PhotoLibraryMount.join(PhotoLibraryMount.systemAlbumRootPath, directoryName)
                )
            }, offset: offset, limit: limit)
        case "/相册/用户":
            let albums = slice(userAlbums(readMode: readMode) ?? [], offset: offset, limit: limit)
            return albums.map { album in
                albumEntry(album)
            }
        case "/图库":
            return try assetDirectoryEntries(
                in: virtualPath,
                offset: offset,
                limit: limit,
                readMode: readMode
            ).map(assetEntry)
        default:
            if PhotoLibraryMount.isSystemAlbumMediaDirectory(virtualPath) {
                return try assetDirectoryEntries(
                    in: virtualPath,
                    offset: offset,
                    limit: limit,
                    readMode: readMode
                ).map(assetEntry)
            }
            if virtualPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/") {
                guard let albums = userAlbums(readMode: readMode) else {
                    return []
                }
                guard albums.contains(where: { $0.virtualPath == virtualPath }) else {
                    throw MSPWorkspaceFileSystemError.notFound(virtualPath)
                }
                return try assetDirectoryEntries(
                    in: virtualPath,
                    offset: offset,
                    limit: limit,
                    readMode: .cachedOnly
                ).map(assetEntry)
            }
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
    }

    private func userAlbums(readMode: PhotoLibraryReadMode) -> [PhotoLibraryMount.MountedAlbum]? {
        switch readMode {
        case .blocking:
            return photoLibraryMount.userAlbums()
        case .cachedOnly:
            return photoLibraryMount.presentationUserAlbums()
        }
    }

    private func assetDirectoryEntries(
        in virtualPath: String,
        offset: Int,
        limit: Int?,
        readMode: PhotoLibraryReadMode
    ) throws -> [PhotoLibraryMount.MountedAssetDirectoryEntry] {
        switch readMode {
        case .blocking:
            return try photoLibraryMount.assetDirectoryEntries(in: virtualPath, offset: offset, limit: limit)
        case .cachedOnly:
            return photoLibraryMount.presentationAssets(in: virtualPath, offset: offset, limit: limit).map {
                PhotoLibraryMount.MountedAssetDirectoryEntry(
                    name: $0.name,
                    virtualPath: $0.virtualPath,
                    creationDate: $0.creationDate,
                    modificationDate: $0.modificationDate
                )
            }
        }
    }

    private func enumeratePhotoLibraryDirectoryEntries(
        _ virtualPath: String,
        options: MSPDirectoryEnumerationOptions,
        readMode: PhotoLibraryReadMode,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            for entry in try photoLibraryMount.listPhotoLibraryTrash(virtualPath) where options.includes(entry.type) {
                guard try await visitor(entry) else {
                    return
                }
            }
            return
        }

        switch virtualPath {
        case "/相册":
            guard options.includes(.directory) else {
                return
            }
            for entry in [
                directoryEntry(name: "系统", virtualPath: PhotoLibraryMount.systemAlbumRootPath),
                directoryEntry(name: "用户", virtualPath: PhotoLibraryMount.userAlbumRootPath)
            ] {
                guard try await visitor(entry) else {
                    return
                }
            }
        case "/相册/系统":
            guard options.includes(.directory) else {
                return
            }
            for directoryName in PhotoLibraryMount.systemAlbumDirectories {
                let entry = directoryEntry(
                    name: directoryName,
                    virtualPath: PhotoLibraryMount.join(PhotoLibraryMount.systemAlbumRootPath, directoryName)
                )
                guard try await visitor(entry) else {
                    return
                }
            }
        case "/相册/用户":
            guard options.includes(.directory) else {
                return
            }
            for album in userAlbums(readMode: readMode) ?? [] {
                guard try await visitor(albumEntry(album)) else {
                    return
                }
            }
        case "/图库":
            guard options.includes(.regularFile) else {
                return
            }
            try await enumerateAssetDirectoryEntries(
                in: virtualPath,
                readMode: readMode
            ) { entry in
                try await visitor(assetEntry(entry))
            }
        default:
            if PhotoLibraryMount.isSystemAlbumMediaDirectory(virtualPath) {
                guard options.includes(.regularFile) else {
                    return
                }
                try await enumerateAssetDirectoryEntries(
                    in: virtualPath,
                    readMode: readMode
                ) { entry in
                    try await visitor(assetEntry(entry))
                }
                return
            }
            if virtualPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/") {
                guard userAlbums(readMode: readMode)?.contains(where: { $0.virtualPath == virtualPath }) == true else {
                    throw MSPWorkspaceFileSystemError.notFound(virtualPath)
                }
                guard options.includes(.regularFile) else {
                    return
                }
                try await enumerateAssetDirectoryEntries(
                    in: virtualPath,
                    readMode: readMode
                ) { entry in
                    try await visitor(assetEntry(entry))
                }
                return
            }
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
    }

    private func enumeratePhotoLibraryDirectoryEntryBatches(
        _ virtualPath: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        readMode: PhotoLibraryReadMode,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            try await emitDirectoryEntryBatches(
                try photoLibraryMount.listPhotoLibraryTrash(virtualPath),
                options: options,
                batchSize: batchSize,
                visitor: visitor
            )
            return
        }

        switch virtualPath {
        case "/相册":
            guard options.includes(.directory) else {
                return
            }
            try await emitDirectoryEntryBatches([
                directoryEntry(name: "系统", virtualPath: PhotoLibraryMount.systemAlbumRootPath),
                directoryEntry(name: "用户", virtualPath: PhotoLibraryMount.userAlbumRootPath)
            ], options: options, batchSize: batchSize, visitor: visitor)
        case "/相册/系统":
            guard options.includes(.directory) else {
                return
            }
            try await emitDirectoryEntryBatches(
                PhotoLibraryMount.systemAlbumDirectories.map { directoryName in
                    directoryEntry(
                        name: directoryName,
                        virtualPath: PhotoLibraryMount.join(PhotoLibraryMount.systemAlbumRootPath, directoryName)
                    )
                },
                options: options,
                batchSize: batchSize,
                visitor: visitor
            )
        case "/相册/用户":
            guard options.includes(.directory) else {
                return
            }
            try await emitDirectoryEntryBatches(
                (userAlbums(readMode: readMode) ?? []).map(albumEntry),
                options: options,
                batchSize: batchSize,
                visitor: visitor
            )
        case "/图库":
            guard options.includes(.regularFile) else {
                return
            }
            try await enumerateAssetDirectoryEntryBatches(
                in: virtualPath,
                batchSize: batchSize,
                readMode: readMode,
                visitor: visitor
            )
        default:
            if PhotoLibraryMount.isSystemAlbumMediaDirectory(virtualPath) {
                guard options.includes(.regularFile) else {
                    return
                }
                try await enumerateAssetDirectoryEntryBatches(
                    in: virtualPath,
                    batchSize: batchSize,
                    readMode: readMode,
                    visitor: visitor
                )
                return
            }
            if virtualPath.hasPrefix(PhotoLibraryMount.userAlbumRootPath + "/") {
                guard userAlbums(readMode: readMode)?.contains(where: { $0.virtualPath == virtualPath }) == true else {
                    throw MSPWorkspaceFileSystemError.notFound(virtualPath)
                }
                guard options.includes(.regularFile) else {
                    return
                }
                try await enumerateAssetDirectoryEntryBatches(
                    in: virtualPath,
                    batchSize: batchSize,
                    readMode: readMode,
                    visitor: visitor
                )
                return
            }
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
    }

    private func enumerateAssetDirectoryEntryBatches(
        in virtualPath: String,
        batchSize: Int,
        readMode: PhotoLibraryReadMode,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        if readMode == .cachedOnly {
            try await enumeratePresentationAssetDirectoryEntryBatches(
                in: virtualPath,
                batchSize: batchSize,
                visitor: visitor
            )
            return
        }
        try await photoLibraryMount.enumerateAssetDirectoryEntryBatches(
            in: virtualPath,
            batchSize: batchSize
        ) { entries in
            try await visitor(entries.map(assetEntry))
        }
    }

    private func enumerateAssetDirectoryEntries(
        in virtualPath: String,
        readMode: PhotoLibraryReadMode,
        visitor: (PhotoLibraryMount.MountedAssetDirectoryEntry) async throws -> Bool
    ) async throws {
        if readMode == .cachedOnly {
            try await enumeratePresentationAssetDirectoryEntries(
                in: virtualPath,
                visitor: visitor
            )
            return
        }
        try await photoLibraryMount.enumerateAssetDirectoryEntries(in: virtualPath, visitor: visitor)
    }

    private func enumeratePresentationAssetDirectoryEntries(
        in virtualPath: String,
        visitor: (PhotoLibraryMount.MountedAssetDirectoryEntry) async throws -> Bool
    ) async throws {
        var offset = 0
        while true {
            let entries = try assetDirectoryEntries(
                in: virtualPath,
                offset: offset,
                limit: Self.presentationAssetEnumerationPageSize,
                readMode: .cachedOnly
            )
            guard !entries.isEmpty else {
                return
            }
            for entry in entries {
                guard try await visitor(entry) else {
                    return
                }
            }
            offset += entries.count
            if entries.count < Self.presentationAssetEnumerationPageSize {
                return
            }
        }
    }

    private func enumeratePresentationAssetDirectoryEntryBatches(
        in virtualPath: String,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let resolvedBatchSize = max(1, batchSize)
        var offset = 0
        while true {
            let entries = try assetDirectoryEntries(
                in: virtualPath,
                offset: offset,
                limit: resolvedBatchSize,
                readMode: .cachedOnly
            ).map(assetEntry)
            guard !entries.isEmpty else {
                return
            }
            guard try await visitor(entries) else {
                return
            }
            offset += entries.count
            if entries.count < resolvedBatchSize {
                return
            }
        }
    }

    private func emitDirectoryEntryBatches(
        _ entries: [MSPDirectoryEntry],
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        for entry in entries where options.includes(entry.type) {
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                guard try await visitor(batch) else {
                    return
                }
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            _ = try await visitor(batch)
        }
    }

    private func rootDirectoryEntry(_ directoryName: String) -> MSPDirectoryEntry {
        directoryEntry(name: directoryName, virtualPath: "/" + directoryName)
    }

    private func rootPhotoDirectoryEntries() -> [MSPDirectoryEntry] {
        var entries = PhotoLibraryMount.rootDirectories.map { directoryName in
            rootDirectoryEntry(directoryName)
        }
        if let displayRootPath = trashConfiguration?.displayRootPath,
           let displayName = displayRootPath.split(separator: "/").last.map(String.init) {
            entries.append(directoryEntry(name: displayName, virtualPath: displayRootPath))
        }
        return entries
    }

    private func directoryEntry(name: String, virtualPath: String) -> MSPDirectoryEntry {
        MSPDirectoryEntry(
            name: name,
            info: MSPFileInfo(
                virtualPath: virtualPath,
                type: .directory,
                modificationDate: Date(),
                permissions: 0o555
            )
        )
    }

    private func slice<T>(_ entries: [T], offset: Int, limit: Int?) -> [T] {
        let startIndex = min(max(offset, 0), entries.count)
        let endIndex = limit.map { min(startIndex + max($0, 0), entries.count) } ?? entries.count
        return Array(entries[startIndex..<endIndex])
    }

    private func albumEntry(_ album: PhotoLibraryMount.MountedAlbum) -> MSPDirectoryEntry {
        MSPDirectoryEntry(
            name: album.name,
            info: albumFileInfo(virtualPath: album.virtualPath)
        )
    }

    private func assetEntry(_ asset: PhotoLibraryMount.MountedAsset) -> MSPDirectoryEntry {
        MSPDirectoryEntry(
            name: asset.name,
            info: assetFileInfo(asset)
        )
    }

    private func assetEntry(_ entry: PhotoLibraryMount.MountedAssetDirectoryEntry) -> MSPDirectoryEntry {
        MSPDirectoryEntry(
            name: entry.name,
            info: assetFileInfo(entry)
        )
    }

    private func albumFileInfo(virtualPath: String) -> MSPFileInfo {
        MSPFileInfo(
            virtualPath: virtualPath,
            type: .directory,
            modificationDate: Date(),
            permissions: 0o555
        )
    }

    private func assetFileInfo(_ asset: PhotoLibraryMount.MountedAsset) -> MSPFileInfo {
        MSPFileInfo(
            virtualPath: asset.virtualPath,
            type: .regularFile,
            size: nil,
            modificationDate: asset.modificationDate ?? asset.creationDate,
            permissions: 0o444
        )
    }

    private func assetFileInfo(_ entry: PhotoLibraryMount.MountedAssetDirectoryEntry) -> MSPFileInfo {
        MSPFileInfo(
            virtualPath: entry.virtualPath,
            type: .regularFile,
            size: nil,
            modificationDate: entry.modificationDate ?? entry.creationDate,
            permissions: 0o444
        )
    }

    private func isPhotoLibraryPath(_ virtualPath: String) -> Bool {
        if virtualPath == "/" {
            return false
        }
        if photoLibraryMount.isPhotoLibraryTrashDisplayPath(virtualPath) {
            return true
        }
        return PhotoLibraryMount.rootDirectories.contains { directoryName in
            virtualPath == "/" + directoryName || virtualPath.hasPrefix("/" + directoryName + "/")
        }
    }

    private func photoLibraryDirectoryPathExists(_ virtualPath: String) -> Bool {
        if virtualPath == "/图库"
            || virtualPath == PhotoLibraryMount.albumRootPath
            || virtualPath == PhotoLibraryMount.systemAlbumRootPath
            || virtualPath == PhotoLibraryMount.userAlbumRootPath {
            return true
        }

        return PhotoLibraryMount.isSystemAlbumMediaDirectory(virtualPath)
    }

    private func isDirectUserAlbumPath(_ virtualPath: String) -> Bool {
        userAlbumRelativeComponents(virtualPath)?.count == 1
    }

    private func isUserAlbumDescendantPath(_ virtualPath: String) -> Bool {
        guard let components = userAlbumRelativeComponents(virtualPath) else {
            return false
        }
        return components.count > 1
    }

    private func userAlbumRelativeComponents(_ virtualPath: String) -> [String]? {
        let normalized = PhotoLibraryMount.normalizeVirtualPath(virtualPath)
        let prefix = PhotoLibraryMount.userAlbumRootPath + "/"
        guard normalized.hasPrefix(prefix) else {
            return nil
        }
        let relativePath = String(normalized.dropFirst(prefix.count))
        let components = relativePath.split(separator: "/").map(String.init)
        return components.isEmpty ? nil : components
    }

    private func normalizedPath(_ path: String, from currentDirectory: String) -> String {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            absolute = currentDirectory == "/"
                ? "/" + path
                : currentDirectory + "/" + path
        }
        return PhotoLibraryMount.normalizeVirtualPath(absolute)
    }

    func trashRecords() throws -> [MSPWorkspaceTrashRecord] {
        photoLibraryMount.photoLibraryTrashRecords()
    }

    func listTrash(_ path: String) throws -> [MSPDirectoryEntry] {
        try photoLibraryMount.listPhotoLibraryTrash(path)
    }

    func restoreTrash(
        _ paths: [String],
        from currentDirectory: String,
        collisionPolicy: MSPWorkspaceTrashRestoreCollisionPolicy
    ) throws -> [MSPWorkspaceTrashRestoreSummary] {
        _ = collisionPolicy
        return try paths.map { path in
            let displayPath = normalizedPath(path, from: currentDirectory)
            return try photoLibraryMount.restoreWorkspaceTrash(displayPath: displayPath)
        }
    }

    func emptyTrash(authorization: MSPWorkspaceTrashEmptyAuthorization) throws -> Int {
        _ = authorization
        throw MSPWorkspaceFileSystemError.accessDenied(trashConfiguration?.displayRootPath ?? "/最近删除")
    }

    func emptyWorkspaceTrash(authorization: MSPWorkspaceTrashEmptyAuthorization) throws -> Int {
        try localFileSystem.emptyTrash(authorization: authorization)
    }

    func listWorkspaceTrashForPresentation(limit: Int?) throws -> [MSPDirectoryEntry] {
        var usedNames = Set<String>()
        let records = try localFileSystem.trashRecords()
            .sorted {
                if $0.trashedAt == $1.trashedAt {
                    return $0.id < $1.id
                }
                return $0.trashedAt > $1.trashedAt
            }
        let limitedRecords = limit.map { Array(records.prefix(max(0, $0))) } ?? records
        return limitedRecords.map { record in
            let displayName = uniquedWorkspaceTrashDisplayName(
                record.originalName,
                usedNames: &usedNames
            )
            return MSPDirectoryEntry(
                name: displayName,
                info: MSPFileInfo(
                    virtualPath: record.trashPath,
                    type: record.isDirectory ? .directory : .regularFile,
                    size: nil,
                    modificationDate: record.trashedAt
                )
            )
        }
    }

    func restoreWorkspaceTrash(at displayPath: String) throws -> [MSPWorkspaceTrashRestoreSummary] {
        try localFileSystem.restoreTrash(
            [displayPath],
            from: "/",
            collisionPolicy: .unique
        )
    }

    func restoreAllWorkspaceTrash() throws -> [MSPWorkspaceTrashRestoreSummary] {
        let trashPaths = try localFileSystem.trashRecords().map(\.trashPath)
        guard !trashPaths.isEmpty else {
            return []
        }
        return try localFileSystem.restoreTrash(
            trashPaths,
            from: "/",
            collisionPolicy: .unique
        )
    }
}

private func uniquedWorkspaceTrashDisplayName(
    _ name: String,
    usedNames: inout Set<String>
) -> String {
    guard usedNames.contains(name) else {
        usedNames.insert(name)
        return name
    }

    let nsName = name as NSString
    let base = nsName.deletingPathExtension.isEmpty ? name : nsName.deletingPathExtension
    let ext = nsName.pathExtension
    var index = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        if !usedNames.contains(candidate) {
            usedNames.insert(candidate)
            return candidate
        }
        index += 1
    }
}

private enum PhotoLibraryReadMode: Equatable {
    case blocking
    case cachedOnly
}

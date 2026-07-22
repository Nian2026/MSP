import XCTest
import MSPCore

final class MSPCoreTests: XCTestCase {
    func testCommandResultSuccess() {
        let result = MSPCommandResult.success(stdout: "ok\n")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ok\n")
    }

    func testWorkspacePathNormalizationClampsAtVirtualRoot() {
        XCTAssertEqual(
            MSPWorkspacePathResolver.normalize("../../outside.txt", from: "/docs"),
            "/outside.txt"
        )
        XCTAssertEqual(
            MSPWorkspacePathResolver.normalize("notes/../README.md", from: "/docs"),
            "/docs/README.md"
        )
    }

    func testWorkspacePolicyDetectsHiddenPathComponents() {
        let policy = MSPWorkspaceFileSystemPolicy(hiddenPathComponents: [".msp", ".internal"])

        XCTAssertTrue(policy.isHidden("/.msp/state.json"))
        XCTAssertTrue(policy.isHidden("/docs/.internal/state.json"))
        XCTAssertFalse(policy.isHidden("/docs/public.txt"))
    }

    func testWorkspacePolicyHidesTrashStorageButNotDisplayedTrashRoot() {
        let policy = MSPWorkspaceFileSystemPolicy(
            hiddenPathComponents: [],
            trashConfiguration: .displayedTrash(
                displayRootPath: "/废纸篓",
                storageRootPath: "/.msp/trash"
            )
        )

        XCTAssertTrue(policy.isHidden("/.msp/trash"))
        XCTAssertTrue(policy.isHidden("/.msp/trash/items/a"))
        XCTAssertFalse(policy.isHidden("/废纸篓"))
        XCTAssertFalse(policy.isHidden("/废纸篓/docs/a.txt"))
    }

    func testTrashConfigurationDecodesLegacyPayloadWithOriginalHierarchyStyle() throws {
        let data = Data(
            #"{"storageRootPath":"/.msp/trash","displayRootPath":"/废纸篓","restoreCollisionPolicy":"unique"}"#.utf8
        )

        let configuration = try JSONDecoder().decode(
            MSPWorkspaceTrashConfiguration.self,
            from: data
        )

        XCTAssertEqual(configuration.displayStyle, .originalHierarchy)
        XCTAssertEqual(configuration.displayRootPath, "/废纸篓")
    }

    func testDisplayedTrashConfigurationSupportsFlatPresentation() {
        let configuration = MSPWorkspaceTrashConfiguration.displayedTrash(
            displayRootPath: "/废纸篓",
            displayStyle: .flat
        )

        XCTAssertEqual(configuration.displayStyle, .flat)
    }

    func testCompositeWorkspaceSynthesizesNestedMountParents() throws {
        let base = MSPCoreMemoryFileSystem()
        let mounted = MSPCoreMemoryFileSystem(files: [
            "/截图/a.jpg": Data("image".utf8)
        ])
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: base,
            mounts: [
                MSPWorkspaceMount(path: "/相册/系统", fileSystem: mounted)
            ],
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        XCTAssertEqual(try fileSystem.stat("/相册", from: "/").type, .directory)
        XCTAssertThrowsError(try fileSystem.readFile("/相册", from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .isDirectory("/相册"))
        }
        XCTAssertEqual(try fileSystem.listDirectory("/", from: "/").map(\.virtualPath), ["/相册"])
        XCTAssertEqual(try fileSystem.listDirectory("/相册", from: "/").map(\.virtualPath), ["/相册/系统"])
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/系统", from: "/").map(\.virtualPath),
            ["/相册/系统/截图"]
        )
        XCTAssertEqual(
            try fileSystem.listDirectory("/相册/系统/截图", from: "/").map(\.virtualPath),
            ["/相册/系统/截图/a.jpg"]
        )
        XCTAssertEqual(
            String(decoding: try fileSystem.readFile("/相册/系统/截图/a.jpg", from: "/"), as: UTF8.self),
            "image"
        )
        try fileSystem.chmod("/相册", mode: 0o700, from: "/")
    }

    func testCompositeWorkspaceReadFileRangeRoutesToMountedBackendWithoutFullRead() throws {
        let mounted = MSPCoreMemoryFileSystem(files: [
            "/big.bin": Data("abcdef".utf8)
        ])
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ]
        )

        let slice = try fileSystem.readFileRange("/media/big.bin", from: "/", offset: 2, length: 3)

        XCTAssertEqual(String(decoding: slice, as: UTF8.self), "cde")
        XCTAssertEqual(mounted.readFileRangeCallCount, 1)
        XCTAssertEqual(mounted.readFileCallCount, 0)
    }

    func testWorkspaceFileInputStreamUsesSingleSequentialReaderWhenAvailable() async throws {
        let fileData = Data((0..<128).map { UInt8($0 % 251) })
        let fileSystem = MSPCoreMemoryFileSystem(files: [
            "/big.bin": fileData
        ])
        let stream = MSPWorkspaceFileInputStream(
            fileSystem: fileSystem,
            path: "/big.bin",
            currentDirectory: "/",
            chunkSize: 7
        )
        var output = Data()

        while let chunk = try await stream.read(maxBytes: 7) {
            output.append(chunk)
        }

        XCTAssertEqual(output, fileData)
        XCTAssertEqual(fileSystem.sequentialOpenCount, 1)
        XCTAssertEqual(fileSystem.readFileRangeCallCount, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
    }

    func testCompositeWorkspaceUsesMountedRootMetadataForMountDirectory() throws {
        let mountedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let mounted = MSPCoreMemoryFileSystem(
            files: [
                "/clip.txt": Data("clip".utf8)
            ],
            modificationDate: mountedDate
        )
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ],
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        XCTAssertEqual(try fileSystem.stat("/media", from: "/").modificationDate, mountedDate)
        XCTAssertEqual(
            try fileSystem.listDirectory("/", from: "/").first { $0.virtualPath == "/media" }?.info.modificationDate,
            mountedDate
        )
    }

    func testCompositeWorkspaceTypedAndBatchEnumerationDelegateToMountedBackend() async throws {
        let mounted = MSPCoreMemoryFileSystem(
            files: [
                "/a.txt": Data("a".utf8),
                "/folder/nested.txt": Data("nested".utf8)
            ],
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ],
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        var typedPaths: [String] = []
        try await fileSystem.enumerateDirectory(
            "/media",
            from: "/",
            options: MSPDirectoryEnumerationOptions(typeFilter: [.regularFile])
        ) { entry in
            typedPaths.append(entry.virtualPath)
            return true
        }

        var batchPaths: [String] = []
        try await fileSystem.enumerateDirectoryBatches(
            "/media",
            from: "/",
            options: .all,
            batchSize: 2
        ) { entries in
            batchPaths.append(contentsOf: entries.map(\.virtualPath))
            return true
        }

        XCTAssertEqual(typedPaths, ["/media/a.txt"])
        XCTAssertEqual(mounted.typedEnumerationOptions.first, MSPDirectoryEnumerationOptions(typeFilter: [.regularFile]))
        XCTAssertEqual(mounted.batchEnumerationBatchSizes, [2])
        XCTAssertEqual(batchPaths.sorted(), ["/media/a.txt", "/media/folder"])
    }

    func testCompositeWorkspaceBaseBatchEnumerationHonorsBatchSize() async throws {
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(
                files: [
                    "/a.txt": Data("a".utf8),
                    "/b.txt": Data("b".utf8),
                    "/c.txt": Data("c".utf8)
                ],
                policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
            ),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: MSPCoreMemoryFileSystem())
            ],
            policy: MSPWorkspaceFileSystemPolicy(directoryOrdering: .name)
        )

        var batches: [[String]] = []
        try await fileSystem.enumerateDirectoryBatches(
            "/",
            from: "/",
            options: .all,
            batchSize: 2
        ) { entries in
            batches.append(entries.map(\.virtualPath))
            return true
        }

        XCTAssertEqual(batches, [["/a.txt", "/b.txt"], ["/c.txt", "/media"]])
    }

    func testCompositeWorkspaceRebasesMountedBackendErrors() throws {
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: MSPCoreMemoryFileSystem())
            ]
        )

        XCTAssertThrowsError(try fileSystem.stat("/media/missing.txt", from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .notFound("/media/missing.txt"))
        }
    }

    func testCompositeWorkspaceCrossBackendCopyAndMovePreserveCreateParentDirectories() throws {
        let base = MSPCoreMemoryFileSystem()
        let mounted = MSPCoreMemoryFileSystem(files: [
            "/clip.txt": Data("clip".utf8)
        ])
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: base,
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ]
        )

        try fileSystem.copy(
            "/media/clip.txt",
            to: "/docs/new/clip.txt",
            from: "/",
            options: [.createParentDirectories]
        )
        XCTAssertEqual(
            String(decoding: try fileSystem.readFile("/docs/new/clip.txt", from: "/"), as: UTF8.self),
            "clip"
        )

        try fileSystem.move(
            "/docs/new/clip.txt",
            to: "/media/moved/deep/clip.txt",
            from: "/",
            options: [.createParentDirectories]
        )
        XCTAssertThrowsError(try fileSystem.stat("/docs/new/clip.txt", from: "/"))
        XCTAssertEqual(
            String(decoding: try fileSystem.readFile("/media/moved/deep/clip.txt", from: "/"), as: UTF8.self),
            "clip"
        )
    }

    func testCompositeWorkspaceBatchCopyDelegatesWithinMountedBackend() throws {
        let mounted = MSPCoreMemoryFileSystem(files: [
            "/a.txt": Data("a".utf8),
            "/b.txt": Data("b".utf8)
        ])
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ]
        )

        try fileSystem.copy(
            [
                MSPFileCopyRequest(sourcePath: "/media/a.txt", destinationPath: "/media/copies/a.txt"),
                MSPFileCopyRequest(sourcePath: "/media/b.txt", destinationPath: "/media/copies/b.txt")
            ],
            from: "/",
            options: [.createParentDirectories]
        )

        XCTAssertEqual(
            mounted.batchCopyRequests,
            [[
                MSPFileCopyRequest(sourcePath: "/a.txt", destinationPath: "/copies/a.txt"),
                MSPFileCopyRequest(sourcePath: "/b.txt", destinationPath: "/copies/b.txt")
            ]]
        )
        XCTAssertEqual(
            String(decoding: try fileSystem.readFile("/media/copies/a.txt", from: "/"), as: UTF8.self),
            "a"
        )
        XCTAssertEqual(
            String(decoding: try fileSystem.readFile("/media/copies/b.txt", from: "/"), as: UTF8.self),
            "b"
        )
    }

    func testCompositeWorkspaceMountedSymbolicLinksPreserveVirtualTargets() throws {
        let mounted = MSPCoreMemoryFileSystem(files: [
            "/target.txt": Data("target".utf8)
        ])
        let fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: MSPCoreMemoryFileSystem(),
            mounts: [
                MSPWorkspaceMount(path: "/media", fileSystem: mounted)
            ]
        )

        try fileSystem.createSymbolicLink(target: "/media/target.txt", at: "/media/link", from: "/")

        XCTAssertEqual(try fileSystem.readSymbolicLink("/media/link", from: "/"), "/media/target.txt")
        XCTAssertEqual(
            try fileSystem.stat("/media/link", from: "/").symbolicLinkTarget,
            "/media/target.txt"
        )
        XCTAssertThrowsError(try fileSystem.createSymbolicLink(target: "/docs/target.txt", at: "/media/external", from: "/")) { error in
            XCTAssertEqual(error as? MSPWorkspaceFileSystemError, .accessDenied("/docs/target.txt"))
        }
    }
}

private final class MSPCoreMemoryFileSystem: MSPWorkspaceSequentialFileReading, MSPWorkspaceBatchDirectoryEnumerating, MSPWorkspaceBatchCopying, @unchecked Sendable {
    let policy: MSPWorkspaceFileSystemPolicy
    private var directories: Set<String>
    private var files: [String: Data]
    private var symbolicLinks: [String: String]
    private var modificationDate: Date?
    private(set) var readFileCallCount = 0
    private(set) var readFileRangeCallCount = 0
    private(set) var sequentialOpenCount = 0
    private(set) var typedEnumerationOptions: [MSPDirectoryEnumerationOptions] = []
    private(set) var batchEnumerationBatchSizes: [Int] = []
    private(set) var batchCopyRequests: [[MSPFileCopyRequest]] = []

    init(
        files: [String: Data] = [:],
        symbolicLinks: [String: String] = [:],
        policy: MSPWorkspaceFileSystemPolicy = MSPWorkspaceFileSystemPolicy(directoryOrdering: .name),
        modificationDate: Date? = nil
    ) {
        self.policy = policy
        self.modificationDate = modificationDate
        self.files = Dictionary(uniqueKeysWithValues: files.map { path, data in
            (MSPWorkspacePathResolver.normalize(path), data)
        })
        self.symbolicLinks = Dictionary(uniqueKeysWithValues: symbolicLinks.map { path, target in
            (MSPWorkspacePathResolver.normalize(path), target)
        })
        self.directories = ["/"]
        for path in Array(self.files.keys) + Array(self.symbolicLinks.keys) {
            var parent = Self.parentPath(of: path)
            while parent != "/" {
                directories.insert(parent)
                parent = Self.parentPath(of: parent)
            }
        }
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .directory,
                modificationDate: modificationDate,
                permissions: 0o755
            )
        }
        if let target = symbolicLinks[virtualPath] {
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .symbolicLink,
                size: 0,
                modificationDate: modificationDate,
                permissions: 0o777,
                symbolicLinkTarget: target
            )
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(
            virtualPath: virtualPath,
            type: .regularFile,
            size: Int64(data.count),
            modificationDate: modificationDate,
            permissions: 0o644
        )
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard directories.contains(virtualPath) else {
            if files[virtualPath] != nil {
                throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        let childPaths = Set(
            files.keys.filter { Self.parentPath(of: $0) == virtualPath }
                + symbolicLinks.keys.filter { Self.parentPath(of: $0) == virtualPath }
                + directories.filter { $0 != "/" && Self.parentPath(of: $0) == virtualPath }
        )
        return policy.directoryOrdering.ordered(try childPaths.map { childPath in
            MSPDirectoryEntry(name: Self.name(of: childPath), info: try stat(childPath, from: "/"))
        })
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        for entry in try listDirectory(path, from: currentDirectory) {
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        typedEnumerationOptions.append(options)
        for entry in try listDirectory(path, from: currentDirectory) where options.includes(entry.type) {
            guard try await visitor(entry) else {
                return
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
        batchEnumerationBatchSizes.append(batchSize)
        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        try await enumerateDirectory(path, from: currentDirectory, options: options) { entry in
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                let shouldContinue = try await visitor(batch)
                batch.removeAll(keepingCapacity: true)
                return shouldContinue
            }
            return true
        }
        if !batch.isEmpty {
            _ = try await visitor(batch)
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let target = symbolicLinks[virtualPath] else {
            if files[virtualPath] != nil || directories.contains(virtualPath) {
                throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return target
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        readFileCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        readFileRangeCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String
    ) throws -> (any MSPWorkspaceSequentialFileReader)? {
        sequentialOpenCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPCoreDataSequentialFileReader(data: data)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        let parent = Self.parentPath(of: virtualPath)
        if options.contains(.createParentDirectories) {
            try createDirectory(parent, from: "/", intermediates: true)
        }
        guard directories.contains(parent) else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
        if files[virtualPath] != nil, !options.contains(.overwriteExisting) {
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath != "/" else {
            return
        }
        let parent = Self.parentPath(of: virtualPath)
        if !directories.contains(parent) {
            guard intermediates else {
                throw MSPWorkspaceFileSystemError.notDirectory(parent)
            }
            try createDirectory(parent, from: "/", intermediates: true)
        }
        directories.insert(virtualPath)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if files[virtualPath] == nil {
            try writeFile(virtualPath, data: Data(), from: "/", options: [])
        }
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if symbolicLinks.removeValue(forKey: virtualPath) != nil {
            return
        }
        if files.removeValue(forKey: virtualPath) != nil {
            return
        }
        guard directories.contains(virtualPath), virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        let hasChildren = files.keys.contains { Self.parentPath(of: $0) == virtualPath }
            || directories.contains { $0 != virtualPath && Self.parentPath(of: $0) == virtualPath }
        if hasChildren, !recursive {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        files = files.filter { !$0.key.hasPrefix(virtualPath + "/") }
        symbolicLinks = symbolicLinks.filter { !$0.key.hasPrefix(virtualPath + "/") }
        directories = directories.filter { $0 == "/" || ($0 != virtualPath && !$0.hasPrefix(virtualPath + "/")) }
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        var writeOptions: MSPFileWriteOptions = []
        if options.contains(.overwriteExisting) {
            writeOptions.insert(.overwriteExisting)
        }
        if options.contains(.createParentDirectories) {
            writeOptions.insert(.createParentDirectories)
        }
        try writeFile(
            destinationPath,
            data: try readFile(sourcePath, from: currentDirectory),
            from: currentDirectory,
            options: writeOptions
        )
    }

    func copy(
        _ requests: [MSPFileCopyRequest],
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        batchCopyRequests.append(requests)
        for request in requests {
            try copy(
                request.sourcePath,
                to: request.destinationPath,
                from: currentDirectory,
                options: options
            )
        }
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        var copyOptions: MSPFileCopyOptions = []
        if options.contains(.overwriteExisting) {
            copyOptions.insert(.overwriteExisting)
        }
        if options.contains(.createParentDirectories) {
            copyOptions.insert(.createParentDirectories)
        }
        try copy(sourcePath, to: destinationPath, from: currentDirectory, options: copyOptions)
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        try copy(sourcePath, to: linkPath, from: currentDirectory, options: [])
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(linkPath, from: currentDirectory).virtualPath
        let parent = Self.parentPath(of: virtualPath)
        guard directories.contains(parent) else {
            throw MSPWorkspaceFileSystemError.notDirectory(parent)
        }
        guard files[virtualPath] == nil,
              symbolicLinks[virtualPath] == nil,
              !directories.contains(virtualPath)
        else {
            throw MSPWorkspaceFileSystemError.alreadyExists(virtualPath)
        }
        symbolicLinks[virtualPath] = target
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        _ = try stat(path, from: currentDirectory)
    }

    private static func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func name(of path: String) -> String {
        MSPWorkspacePathResolver.components(in: path).last ?? ""
    }
}

private final class MSPCoreDataSequentialFileReader: MSPWorkspaceSequentialFileReader, @unchecked Sendable {
    private let data: Data
    private var offset = 0
    private var closed = false

    init(data: Data) {
        self.data = data
    }

    func read(upToCount count: Int) throws -> Data? {
        guard !closed, offset < data.count else {
            return nil
        }
        let end = min(data.count, offset + max(1, count))
        let chunk = data.subdata(in: offset..<end)
        offset = end
        return chunk
    }

    func close() throws {
        closed = true
    }
}

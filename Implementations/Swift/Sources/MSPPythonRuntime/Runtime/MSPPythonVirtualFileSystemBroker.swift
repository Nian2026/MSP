import Foundation
import MSPCore

public final class MSPPythonVirtualFileSystemBroker: @unchecked Sendable {
    private static let implicitDirectoryPaths: Set<String> = ["/tmp"]

    private let directoryURL: URL
    private let baseContext: MSPCommandContext
    private let lock = NSLock()
    private var isStopped = false
    private var processedRequestIDs = Set<String>()
    private var thread: Thread?

    public init(directoryURL: URL, baseContext: MSPCommandContext) throws {
        self.directoryURL = directoryURL
        self.baseContext = baseContext
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func start() {
        guard baseContext.workspace != nil else {
            return
        }
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.withLock {
            isStopped = true
        }
        while thread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private var stopped: Bool {
        lock.withLock { isStopped }
    }

    private func runLoop() {
        while !stopped {
            autoreleasepool {
                processAvailableRequests()
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func processAvailableRequests() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("vfs-request-")
            && file.pathExtension == "json" {
            processRequest(at: file)
        }
    }

    private func processRequest(at url: URL) {
        let requestData: Data
        do {
            requestData = try Data(contentsOf: url)
        } catch {
            return
        }

        let request: MSPPythonVFSRequest
        do {
            request = try JSONDecoder().decode(MSPPythonVFSRequest.self, from: requestData)
        } catch {
            if let requestID = requestID(in: requestData) {
                write(
                    .failure(.init(
                        type: "ValueError",
                        path: nil,
                        message: "invalid MSP Python VFS request JSON: \(error)"
                    )),
                    id: requestID
                )
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        let shouldProcess = lock.withLock { () -> Bool in
            guard !processedRequestIDs.contains(request.id) else {
                return false
            }
            processedRequestIDs.insert(request.id)
            return true
        }
        guard shouldProcess else {
            return
        }

        let response = handle(request)
        write(response, id: request.id)
        try? FileManager.default.removeItem(at: url)
    }

    private func handle(_ request: MSPPythonVFSRequest) -> MSPPythonVFSResponse {
        guard let workspace = baseContext.workspace else {
            return .failure(.init(type: "PermissionError", path: request.path, message: "workspace is unavailable"))
        }
        let fileSystem = workspace.fileSystem
        let currentDirectory = MSPWorkspacePathResolver.normalize(request.cwd ?? baseContext.currentDirectory)

        do {
            switch request.action {
            case "resolve":
                let resolved = try fileSystem.resolve(requiredPath(request), from: currentDirectory)
                return .success(path: resolved.virtualPath)
            case "stat":
                let info = try statFollowingSymbolicLinks(
                    requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                return .success(info: MSPPythonVFSInfo(info))
            case "lstat":
                let info = try lstatInfo(
                    requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                return .success(info: MSPPythonVFSInfo(info))
            case "listdir":
                let entries = try listDirectoryFollowingSymbolicLinks(
                    requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                return .success(entries: entries.map(MSPPythonVFSEntry.init))
            case "read_file":
                let data = try fileSystem.readFile(requiredPath(request), from: currentDirectory)
                return .success(data: data.base64EncodedString())
            case "write_file":
                let data = Data(base64Encoded: request.dataB64 ?? "") ?? Data()
                try ensureImplicitParentDirectoryIfNeeded(
                    for: requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                var options: MSPFileWriteOptions = []
                if request.overwrite ?? true {
                    options.insert(.overwriteExisting)
                }
                if request.createParentDirectories ?? false {
                    options.insert(.createParentDirectories)
                }
                try fileSystem.writeFile(
                    requiredPath(request),
                    data: data,
                    from: currentDirectory,
                    options: options,
                    creationMode: request.creationMode.map { UInt16($0) }
                )
                return .success()
            case "append_file":
                let data = Data(base64Encoded: request.dataB64 ?? "") ?? Data()
                try ensureImplicitParentDirectoryIfNeeded(
                    for: requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                try fileSystem.appendFile(
                    requiredPath(request),
                    data: data,
                    from: currentDirectory,
                    options: request.createParentDirectories == true ? [.createParentDirectories] : [],
                    creationMode: request.creationMode.map { UInt16($0) }
                )
                return .success()
            case "mkdir":
                try rejectExplicitImplicitDirectoryCreationIfNeeded(
                    requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                try ensureImplicitParentDirectoryIfNeeded(
                    for: requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                try fileSystem.createDirectory(
                    requiredPath(request),
                    from: currentDirectory,
                    intermediates: request.intermediates ?? false,
                    creationMode: request.creationMode.map { UInt16($0) }
                )
                return .success()
            case "remove", "unlink":
                try fileSystem.remove(
                    requiredPath(request),
                    from: currentDirectory,
                    recursive: request.recursive ?? false
                )
                return .success()
            case "rmdir":
                try removeEmptyDirectory(
                    requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                )
                return .success()
            case "rename", "replace":
                try fileSystem.move(
                    requiredPath(request),
                    to: requiredDestination(request),
                    from: currentDirectory,
                    options: request.overwrite == false ? [] : [.overwriteExisting]
                )
                return .success()
            case "readlink":
                let target = try fileSystem.readSymbolicLink(requiredPath(request), from: currentDirectory)
                return .success(value: target)
            case "chmod":
                try fileSystem.chmod(
                    requiredPath(request),
                    mode: UInt16(request.mode ?? 0),
                    from: currentDirectory
                )
                return .success()
            case "utime":
                if let modificationTime = request.modificationTime,
                   let timestampingFileSystem = fileSystem as? MSPWorkspaceFileTimestamping {
                    guard modificationTime.isFinite else {
                        return .failure(.init(
                            type: "ValueError",
                            path: request.path,
                            message: "utime modification_time must be finite"
                        ))
                    }
                    try timestampingFileSystem.setModificationDate(
                        requiredPath(request),
                        modificationDate: Date(timeIntervalSince1970: modificationTime),
                        from: currentDirectory
                    )
                } else {
                    try fileSystem.touch(requiredPath(request), from: currentDirectory)
                }
                return .success()
            case "access":
                return .success(boolValue: accessExists(
                    try requiredPath(request),
                    from: currentDirectory,
                    fileSystem: fileSystem
                ))
            default:
                return .failure(.init(
                    type: "ValueError",
                    path: request.path,
                    message: "unsupported MSP Python VFS action: \(request.action)"
                ))
            }
        } catch {
            return .failure(errorPayload(from: error, fallbackPath: request.path))
        }
    }

    private func accessExists(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) -> Bool {
        if (try? statFollowingSymbolicLinks(path, from: currentDirectory, fileSystem: fileSystem)) != nil {
            return true
        }
        let normalized = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        return Self.isImplicitDirectoryPath(normalized)
    }

    private static func isImplicitDirectoryPath(_ path: String) -> Bool {
        implicitDirectoryPaths.contains(MSPWorkspacePathResolver.normalize(path))
    }

    private func implicitDirectoryInfo(_ path: String) -> MSPFileInfo? {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard Self.isImplicitDirectoryPath(normalized) else {
            return nil
        }
        return MSPFileInfo(
            virtualPath: normalized,
            type: .directory,
            size: 0,
            permissions: 0o777,
            fileIdentity: "msp-python-implicit-directory:\(normalized)"
        )
    }

    private func ensureImplicitParentDirectoryIfNeeded(
        for path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let normalizedPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        let parentVirtualPath = parentPath(of: normalizedPath)
        guard Self.isImplicitDirectoryPath(parentVirtualPath) else {
            return
        }

        do {
            let info = try fileSystem.stat(parentVirtualPath, from: "/")
            guard info.type == .directory else {
                throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
            }
        } catch MSPWorkspaceFileSystemError.notFound {
            try fileSystem.createDirectory(
                parentVirtualPath,
                from: "/",
                intermediates: true,
                creationMode: 0o777
            )
        }
    }

    private func rejectExplicitImplicitDirectoryCreationIfNeeded(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let normalizedPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        guard Self.isImplicitDirectoryPath(normalizedPath) else {
            return
        }
        if let info = try? fileSystem.stat(normalizedPath, from: "/"),
           info.type != .directory {
            throw MSPWorkspaceFileSystemError.notDirectory(normalizedPath)
        }
        if (try? fileSystem.stat(normalizedPath, from: "/")) == nil {
            try? fileSystem.createDirectory(
                normalizedPath,
                from: "/",
                intermediates: true,
                creationMode: 0o777
            )
        }
        throw MSPWorkspaceFileSystemError.alreadyExists(normalizedPath)
    }

    private func requiredPath(_ request: MSPPythonVFSRequest) throws -> String {
        guard let path = request.path, !path.isEmpty else {
            throw MSPWorkspaceFileSystemError.invalidPath("")
        }
        return path
    }

    private func requiredDestination(_ request: MSPPythonVFSRequest) throws -> String {
        guard let destination = request.destination, !destination.isEmpty else {
            throw MSPWorkspaceFileSystemError.invalidPath("")
        }
        return destination
    }

    private func statFollowingSymbolicLinks(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws -> MSPFileInfo {
        let originalPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        var currentPath = originalPath
        var visited = Set<String>()

        for _ in 0..<40 {
            let info: MSPFileInfo
            do {
                info = try lstatInfo(currentPath, from: "/", fileSystem: fileSystem)
            } catch MSPWorkspaceFileSystemError.notFound where currentPath != originalPath {
                throw MSPWorkspaceFileSystemError.notFound(originalPath)
            }
            guard info.type == .symbolicLink else {
                return info
            }
            guard !visited.contains(info.virtualPath) else {
                throw MSPWorkspaceFileSystemError.io(path: originalPath, operation: "stat")
            }
            visited.insert(info.virtualPath)
            let target = try info.symbolicLinkTarget
                ?? fileSystem.readSymbolicLink(info.virtualPath, from: "/")
            currentPath = MSPWorkspacePathResolver.normalize(
                target,
                from: parentPath(of: info.virtualPath)
            )
        }

        throw MSPWorkspaceFileSystemError.io(path: originalPath, operation: "stat")
    }

    private func lstatInfo(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws -> MSPFileInfo {
        do {
            return try fileSystem.stat(path, from: currentDirectory)
        } catch MSPWorkspaceFileSystemError.notFound {
            let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
            if let info = implicitDirectoryInfo(virtualPath) {
                return info
            }
            let target: String
            do {
                target = try fileSystem.readSymbolicLink(virtualPath, from: "/")
            } catch {
                throw MSPWorkspaceFileSystemError.notFound(virtualPath)
            }
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .symbolicLink,
                size: Int64(target.utf8.count),
                permissions: 0o777,
                symbolicLinkTarget: target,
                fileIdentity: nil
            )
        }
    }

    private func listDirectoryFollowingSymbolicLinks(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws -> [MSPDirectoryEntry] {
        let originalPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        var currentPath = originalPath
        var visited = Set<String>()

        for _ in 0..<40 {
            let info: MSPFileInfo
            do {
                info = try lstatInfo(currentPath, from: "/", fileSystem: fileSystem)
            } catch MSPWorkspaceFileSystemError.notFound where currentPath != originalPath {
                throw MSPWorkspaceFileSystemError.notFound(originalPath)
            }
            guard info.type == .symbolicLink else {
                guard info.type == .directory else {
                    throw MSPWorkspaceFileSystemError.notDirectory(originalPath)
                }
                if Self.isImplicitDirectoryPath(info.virtualPath) {
                    do {
                        return try fileSystem.listDirectory(info.virtualPath, from: "/")
                    } catch MSPWorkspaceFileSystemError.notFound {
                        return []
                    } catch MSPWorkspaceFileSystemError.io(_, _) {
                        return []
                    }
                }
                let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
                guard info.virtualPath != originalPath else {
                    return entries
                }
                return entries.map {
                    rebaseDirectoryEntry($0, requestedDirectoryPath: originalPath)
                }
            }
            guard !visited.contains(info.virtualPath) else {
                throw MSPWorkspaceFileSystemError.io(path: originalPath, operation: "list")
            }
            visited.insert(info.virtualPath)
            let target = try info.symbolicLinkTarget
                ?? fileSystem.readSymbolicLink(info.virtualPath, from: "/")
            currentPath = MSPWorkspacePathResolver.normalize(
                target,
                from: parentPath(of: info.virtualPath)
            )
        }

        throw MSPWorkspaceFileSystemError.io(path: originalPath, operation: "list")
    }

    private func rebaseDirectoryEntry(
        _ entry: MSPDirectoryEntry,
        requestedDirectoryPath: String
    ) -> MSPDirectoryEntry {
        var info = entry.info
        info.virtualPath = joinVirtualPath(parent: requestedDirectoryPath, child: entry.name)
        return MSPDirectoryEntry(name: entry.name, info: info)
    }

    private func parentPath(of path: String) -> String {
        let normalized = MSPWorkspacePathResolver.normalize(path)
        guard normalized != "/" else {
            return "/"
        }
        let components = MSPWorkspacePathResolver.components(in: normalized)
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func joinVirtualPath(parent: String, child: String) -> String {
        let normalizedParent = MSPWorkspacePathResolver.normalize(parent)
        if normalizedParent == "/" {
            return "/" + child
        }
        return normalizedParent + "/" + child
    }

    private func removeEmptyDirectory(
        _ path: String,
        from currentDirectory: String,
        fileSystem: any MSPWorkspaceFileSystem
    ) throws {
        let info = try fileSystem.stat(path, from: currentDirectory)
        guard info.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(info.virtualPath)
        }
        let entries = try fileSystem.listDirectory(info.virtualPath, from: "/")
        guard entries.isEmpty else {
            throw MSPPythonVFSDirectoryNotEmpty(path: info.virtualPath)
        }
        try fileSystem.remove(info.virtualPath, from: "/", recursive: true)
    }

    private func errorPayload(from error: Error, fallbackPath: String?) -> MSPPythonVFSError {
        if let directoryNotEmpty = error as? MSPPythonVFSDirectoryNotEmpty {
            return MSPPythonVFSError(
                type: "DirectoryNotEmptyError",
                path: directoryNotEmpty.path,
                message: "Directory not empty"
            )
        }
        guard let fileSystemError = error as? MSPWorkspaceFileSystemError else {
            return MSPPythonVFSError(type: "OSError", path: fallbackPath, message: "\(error)")
        }
        switch fileSystemError {
        case .accessDenied(let path), .hiddenPath(let path):
            return MSPPythonVFSError(type: "PermissionError", path: path, message: fileSystemError.description)
        case .invalidPath(let path), .encodingFailed(let path), .io(let path, _):
            return MSPPythonVFSError(type: "OSError", path: path, message: fileSystemError.description)
        case .notFound(let path):
            return MSPPythonVFSError(type: "FileNotFoundError", path: path, message: fileSystemError.description)
        case .notDirectory(let path):
            return MSPPythonVFSError(type: "NotADirectoryError", path: path, message: fileSystemError.description)
        case .isDirectory(let path):
            return MSPPythonVFSError(type: "IsADirectoryError", path: path, message: fileSystemError.description)
        case .directoryNotEmpty(let path):
            return MSPPythonVFSError(type: "DirectoryNotEmptyError", path: path, message: fileSystemError.description)
        case .notSymbolicLink(let path):
            return MSPPythonVFSError(type: "OSError", path: path, message: fileSystemError.description)
        case .alreadyExists(let path):
            return MSPPythonVFSError(type: "FileExistsError", path: path, message: fileSystemError.description)
        }
    }

    private func write(_ response: MSPPythonVFSResponse, id: String) {
        let responseURL = directoryURL.appendingPathComponent("vfs-response-\(id).json")
        let temporaryURL = directoryURL.appendingPathComponent("vfs-response-\(id).json.tmp")
        do {
            try writeEncodedResponse(response, responseURL: responseURL, temporaryURL: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            let fallback = MSPPythonVFSResponse.failure(.init(
                type: "OSError",
                path: nil,
                message: "MSP Python VFS response encoding failed: \(error)"
            ))
            do {
                try writeEncodedResponse(fallback, responseURL: responseURL, temporaryURL: temporaryURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                NSLog(
                    "MSP Python VFS response write failed id=%@ summary=%@ error=%@",
                    id,
                    response.writeFailureSummary,
                    "\(error)"
                )
            }
        }
    }

    private func writeEncodedResponse(
        _ response: MSPPythonVFSResponse,
        responseURL: URL,
        temporaryURL: URL
    ) throws {
        try JSONEncoder().encode(response).write(to: temporaryURL)
        if FileManager.default.fileExists(atPath: responseURL.path) {
            try FileManager.default.removeItem(at: responseURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: responseURL)
    }

    private func requestID(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: #""id"\s*:\s*""#, options: .regularExpression) else {
            return nil
        }
        var value = ""
        var index = keyRange.upperBound
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value.isEmpty ? nil : value
            } else {
                value.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }
}

private struct MSPPythonVFSDirectoryNotEmpty: Error {
    var path: String
}

private struct MSPPythonVFSRequest: Decodable {
    var id: String
    var action: String
    var path: String?
    var destination: String?
    var cwd: String?
    var dataB64: String?
    var overwrite: Bool?
    var createParentDirectories: Bool?
    var intermediates: Bool?
    var recursive: Bool?
    var creationMode: Int?
    var mode: Int?
    var modificationTime: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case path
        case destination
        case cwd
        case dataB64 = "data_b64"
        case overwrite
        case createParentDirectories = "create_parent_directories"
        case intermediates
        case recursive
        case creationMode = "creation_mode"
        case mode
        case modificationTime = "modification_time"
    }
}

private struct MSPPythonVFSResponse: Encodable {
    var ok: Bool
    var error: MSPPythonVFSError? = nil
    var path: String? = nil
    var value: String? = nil
    var boolValue: Bool? = nil
    var dataB64: String? = nil
    var info: MSPPythonVFSInfo? = nil
    var entries: [MSPPythonVFSEntry]? = nil

    static func success(
        path: String? = nil,
        value: String? = nil,
        boolValue: Bool? = nil,
        data: String? = nil,
        info: MSPPythonVFSInfo? = nil,
        entries: [MSPPythonVFSEntry]? = nil
    ) -> MSPPythonVFSResponse {
        MSPPythonVFSResponse(
            ok: true,
            path: path,
            value: value,
            boolValue: boolValue,
            dataB64: data,
            info: info,
            entries: entries
        )
    }

    static func failure(_ error: MSPPythonVFSError) -> MSPPythonVFSResponse {
        MSPPythonVFSResponse(ok: false, error: error)
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case path
        case value
        case boolValue = "bool_value"
        case dataB64 = "data_b64"
        case info
        case entries
    }
}

private struct MSPPythonVFSError: Encodable {
    var type: String
    var path: String?
    var message: String
}

private struct MSPPythonVFSInfo: Encodable {
    var virtualPath: String
    var type: String
    var size: Int64?
    var modificationTime: TimeInterval?
    var permissions: UInt16?
    var symbolicLinkTarget: String?
    var fileIdentity: String?

    init(_ info: MSPFileInfo) {
        self.virtualPath = info.virtualPath
        self.type = info.type.rawValue
        self.size = info.size
        let modificationTime = info.modificationDate?.timeIntervalSince1970
        self.modificationTime = modificationTime?.isFinite == true ? modificationTime : nil
        self.permissions = info.permissions
        self.symbolicLinkTarget = info.symbolicLinkTarget
        self.fileIdentity = info.fileIdentity
    }

    enum CodingKeys: String, CodingKey {
        case virtualPath = "virtual_path"
        case type
        case size
        case modificationTime = "modification_time"
        case permissions
        case symbolicLinkTarget = "symbolic_link_target"
        case fileIdentity = "file_identity"
    }
}

private struct MSPPythonVFSEntry: Encodable {
    var name: String
    var info: MSPPythonVFSInfo

    init(_ entry: MSPDirectoryEntry) {
        self.name = entry.name
        self.info = MSPPythonVFSInfo(entry.info)
    }
}

private extension MSPPythonVFSResponse {
    var writeFailureSummary: String {
        [
            "ok=\(ok)",
            "has_error=\(error != nil)",
            "has_path=\(path != nil)",
            "has_value=\(value != nil)",
            "has_bool=\(boolValue != nil)",
            "data_b64_chars=\(dataB64?.count ?? 0)",
            "has_info=\(info != nil)",
            "entries=\(entries?.count ?? 0)"
        ].joined(separator: " ")
    }
}

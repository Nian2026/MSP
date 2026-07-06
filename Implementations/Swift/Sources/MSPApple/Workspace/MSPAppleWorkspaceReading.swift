import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func openSequentialFileReader(
        _ path: String,
        from currentDirectory: String = "/"
    ) throws -> (any MSPWorkspaceSequentialFileReader)? {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            return MSPAppleDataSequentialFileReader(data: try readTrashFile(atDisplayPath: virtualPath))
        }
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        let info = try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
        guard info.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }

        do {
            return MSPAppleFileHandleSequentialFileReader(
                handle: try FileHandle(forReadingFrom: resolvedURL.url),
                virtualPath: resolvedURL.resolved.virtualPath
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "read"
            )
        }
    }

    public func readFile(_ path: String, from currentDirectory: String = "/") throws -> Data {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            return try readTrashFile(atDisplayPath: virtualPath)
        }
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        let info = try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
        guard info.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }

        do {
            return try Data(contentsOf: resolvedURL.url)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "read"
            )
        }
    }

    public func readFileRange(
        _ path: String,
        from currentDirectory: String = "/",
        offset: UInt64,
        length: Int
    ) throws -> Data {
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            let data = try readTrashFile(atDisplayPath: virtualPath)
            guard length > 0, offset < UInt64(data.count) else {
                return Data()
            }
            let start = Int(offset)
            let end = min(data.count, start + length)
            return data.subdata(in: start..<end)
        }
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        let info = try fileInfo(virtualPath: resolvedURL.resolved.virtualPath, url: resolvedURL.url)
        guard info.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }
        guard length > 0 else {
            return Data()
        }

        do {
            let handle = try FileHandle(forReadingFrom: resolvedURL.url)
            defer {
                try? handle.close()
            }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "read"
            )
        }
    }

    public func readSymbolicLink(
        _ path: String,
        from currentDirectory: String = "/"
    ) throws -> String {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)

        do {
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: resolvedURL.url.path
            )
            return try virtualSymbolicLinkTarget(
                destination,
                linkVirtualPath: resolvedURL.resolved.virtualPath
            )
        } catch let error as MSPWorkspaceFileSystemError {
            throw error
        } catch {
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(
                atPath: resolvedURL.url.path,
                isDirectory: &isDirectory
            )
            if exists {
                throw MSPWorkspaceFileSystemError.notSymbolicLink(resolvedURL.resolved.virtualPath)
            }
            throw MSPWorkspaceFileSystemError.notFound(resolvedURL.resolved.virtualPath)
        }
    }
}

private final class MSPAppleFileHandleSequentialFileReader: MSPWorkspaceSequentialFileReader, @unchecked Sendable {
    private let handle: FileHandle
    private let virtualPath: String
    private var closed = false

    init(handle: FileHandle, virtualPath: String) {
        self.handle = handle
        self.virtualPath = virtualPath
    }

    func read(upToCount count: Int) throws -> Data? {
        guard !closed else {
            return nil
        }
        guard count > 0 else {
            return Data()
        }
        do {
            return try handle.read(upToCount: count)
        } catch {
            throw MSPWorkspaceFileSystemError.io(path: virtualPath, operation: "read")
        }
    }

    func close() throws {
        guard !closed else {
            return
        }
        closed = true
        do {
            try handle.close()
        } catch {
            throw MSPWorkspaceFileSystemError.io(path: virtualPath, operation: "close")
        }
    }
}

private final class MSPAppleDataSequentialFileReader: MSPWorkspaceSequentialFileReader, @unchecked Sendable {
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

import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String = "/",
        options: MSPFileWriteOptions = [.overwriteExisting]
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        let parentVirtualPath = parentPath(of: resolvedURL.resolved.virtualPath)

        if options.contains(.createParentDirectories), parentVirtualPath != "/" {
            try createDirectory(parentVirtualPath, from: "/", intermediates: true)
        }

        let parentURL = try resolveURL(parentVirtualPath, from: "/", requireExisting: true)
        let parentInfo = try fileInfo(virtualPath: parentVirtualPath, url: parentURL.url)
        guard parentInfo.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
        }

        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: resolvedURL.url.path,
            isDirectory: &isDirectory
        )
        if exists, isDirectory.boolValue {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }
        if exists, !options.contains(.overwriteExisting) {
            throw MSPWorkspaceFileSystemError.alreadyExists(resolvedURL.resolved.virtualPath)
        }

        do {
            var writingOptions: Data.WritingOptions = []
            if options.contains(.atomic) {
                writingOptions.insert(.atomic)
            }
            try data.write(to: resolvedURL.url, options: writingOptions)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "write"
            )
        }
    }

    public func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String = "/",
        options: MSPFileWriteOptions = [.overwriteExisting],
        creationMode: UInt16?
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        let existed = FileManager.default.fileExists(atPath: resolvedURL.url.path)
        try writeFile(path, data: data, from: currentDirectory, options: options)
        guard !existed, let creationMode else {
            return
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(creationMode & 0o777))],
                ofItemAtPath: resolvedURL.url.path
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "chmod"
            )
        }
    }

    public func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String = "/",
        options: MSPFileWriteOptions = [.createParentDirectories],
        creationMode: UInt16? = nil
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        let parentVirtualPath = parentPath(of: resolvedURL.resolved.virtualPath)

        if options.contains(.createParentDirectories), parentVirtualPath != "/" {
            try createDirectory(parentVirtualPath, from: "/", intermediates: true)
        }

        let parentURL = try resolveURL(parentVirtualPath, from: "/", requireExisting: true)
        let parentInfo = try fileInfo(virtualPath: parentVirtualPath, url: parentURL.url)
        guard parentInfo.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
        }

        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: resolvedURL.url.path,
            isDirectory: &isDirectory
        )
        if exists, isDirectory.boolValue {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }
        if !exists {
            guard FileManager.default.createFile(atPath: resolvedURL.url.path, contents: Data()) else {
                throw MSPWorkspaceFileSystemError.io(
                    path: resolvedURL.resolved.virtualPath,
                    operation: "write"
                )
            }
            if let creationMode {
                do {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: Int(creationMode & 0o777))],
                        ofItemAtPath: resolvedURL.url.path
                    )
                } catch {
                    throw MSPWorkspaceFileSystemError.io(
                        path: resolvedURL.resolved.virtualPath,
                        operation: "chmod"
                    )
                }
            }
        }

        guard !data.isEmpty else {
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: resolvedURL.url)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "write"
            )
        }
    }

    public func createDirectory(
        _ path: String,
        from currentDirectory: String = "/",
        intermediates: Bool = false
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        guard resolvedURL.resolved.virtualPath != "/" else {
            return
        }

        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: resolvedURL.url.path,
            isDirectory: &isDirectory
        )
        if exists {
            guard isDirectory.boolValue else {
                throw MSPWorkspaceFileSystemError.notDirectory(resolvedURL.resolved.virtualPath)
            }
            return
        }

        if !intermediates {
            let parentVirtualPath = parentPath(of: resolvedURL.resolved.virtualPath)
            let parentURL = try resolveURL(parentVirtualPath, from: "/", requireExisting: true)
            let parentInfo = try fileInfo(virtualPath: parentVirtualPath, url: parentURL.url)
            guard parentInfo.type == .directory else {
                throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: resolvedURL.url,
                withIntermediateDirectories: intermediates
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "mkdir"
            )
        }
    }

    public func createDirectory(
        _ path: String,
        from currentDirectory: String = "/",
        intermediates: Bool = false,
        creationMode: UInt16?
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        let existed = FileManager.default.fileExists(atPath: resolvedURL.url.path)
        try createDirectory(path, from: currentDirectory, intermediates: intermediates)
        guard !existed, let creationMode else {
            return
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(creationMode & 0o777))],
                ofItemAtPath: resolvedURL.url.path
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "chmod"
            )
        }
    }

    public func touch(_ path: String, from currentDirectory: String = "/") throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        if FileManager.default.fileExists(atPath: resolvedURL.url.path) {
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: resolvedURL.url.path
                )
            } catch {
                throw MSPWorkspaceFileSystemError.io(
                    path: resolvedURL.resolved.virtualPath,
                    operation: "touch"
                )
            }
        } else {
            try writeFile(
                resolvedURL.resolved.virtualPath,
                data: Data(),
                from: "/",
                options: [.overwriteExisting]
            )
        }
    }

    public func touch(
        _ path: String,
        from currentDirectory: String = "/",
        creationMode: UInt16?
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        if FileManager.default.fileExists(atPath: resolvedURL.url.path) {
            try touch(path, from: currentDirectory)
        } else {
            try writeFile(
                resolvedURL.resolved.virtualPath,
                data: Data(),
                from: "/",
                options: [.overwriteExisting],
                creationMode: creationMode
            )
        }
    }

    public func setModificationDate(
        _ path: String,
        modificationDate: Date,
        from currentDirectory: String = "/"
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: true)
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: resolvedURL.url.path
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolvedURL.resolved.virtualPath,
                operation: "utime"
            )
        }
    }

    public func chmod(
        _ path: String,
        mode: UInt16,
        from currentDirectory: String = "/"
    ) throws {
        let resolved = try resolveURL(path, from: currentDirectory, requireExisting: true)
        guard resolved.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.accessDenied("/")
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int(mode & 0o777))],
                ofItemAtPath: resolved.url.path
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: resolved.resolved.virtualPath,
                operation: "chmod"
            )
        }
    }
}

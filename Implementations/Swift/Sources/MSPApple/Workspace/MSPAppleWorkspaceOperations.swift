import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func remove(
        _ path: String,
        from currentDirectory: String = "/",
        recursive: Bool = false
    ) throws {
        let resolvedURL = try resolveURL(path, from: currentDirectory, requireExisting: false)
        guard resolvedURL.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.accessDenied("/")
        }
        guard !isTrashDisplayPath(resolvedURL.resolved.virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(resolvedURL.resolved.virtualPath)
        }

        let itemState = itemState(at: resolvedURL.url)
        guard itemState.exists else {
            throw MSPWorkspaceFileSystemError.notFound(resolvedURL.resolved.virtualPath)
        }
        let isDirectoryPackageFile = itemState.isDirectory
            && !itemState.isSymbolicLink
            && policy.presentsDirectoryPackageAsFile(resolvedURL.resolved.virtualPath)
        if itemState.isDirectory, !itemState.isSymbolicLink, !recursive, !isDirectoryPackageFile {
            throw MSPWorkspaceFileSystemError.isDirectory(resolvedURL.resolved.virtualPath)
        }

        guard trashConfiguration != nil else {
            throw MSPWorkspaceFileSystemError.accessDenied(resolvedURL.resolved.virtualPath)
        }
        try moveToTrash(resolvedURL, isDirectory: itemState.isDirectory && !itemState.isSymbolicLink)
    }

    public func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String = "/",
        options: MSPFileCopyOptions = []
    ) throws {
        let source = try resolveURL(sourcePath, from: currentDirectory, requireExisting: true)
        let destination = try resolveURL(destinationPath, from: currentDirectory, requireExisting: false)
        guard source.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.accessDenied("/")
        }
        guard destination.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.alreadyExists("/")
        }

        let sourceInfo = try fileInfo(virtualPath: source.resolved.virtualPath, url: source.url)
        if sourceInfo.type == .directory, !options.contains(.recursive) {
            throw MSPWorkspaceFileSystemError.isDirectory(source.resolved.virtualPath)
        }

        try ensureParentDirectory(
            of: destination.resolved.virtualPath,
            createIfNeeded: options.contains(.createParentDirectories)
        )

        let destinationExists = FileManager.default.fileExists(atPath: destination.url.path)
        if destinationExists {
            guard options.contains(.overwriteExisting) else {
                throw MSPWorkspaceFileSystemError.alreadyExists(destination.resolved.virtualPath)
            }
            try remove(destination.resolved.virtualPath, from: "/", recursive: true)
        }

        do {
            try FileManager.default.copyItem(at: source.url, to: destination.url)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: destination.resolved.virtualPath,
                operation: "copy"
            )
        }
    }

    public func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String = "/",
        options: MSPFileMoveOptions = [.overwriteExisting]
    ) throws {
        let source = try resolveURL(sourcePath, from: currentDirectory, requireExisting: true)
        let destination = try resolveURL(destinationPath, from: currentDirectory, requireExisting: false)
        guard source.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.accessDenied("/")
        }
        guard destination.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.alreadyExists("/")
        }

        if source.url == destination.url {
            return
        }

        let sourceState = itemState(at: source.url)
        let sourceIsDirectory = sourceState.isDirectory
            && !sourceState.isSymbolicLink
            && !policy.presentsDirectoryPackageAsFile(source.resolved.virtualPath)

        try ensureParentDirectory(
            of: destination.resolved.virtualPath,
            createIfNeeded: options.contains(.createParentDirectories)
        )

        let destinationState = itemState(at: destination.url)
        if destinationState.exists {
            guard options.contains(.overwriteExisting) else {
                throw MSPWorkspaceFileSystemError.alreadyExists(destination.resolved.virtualPath)
            }
            let destinationIsDirectory = destinationState.isDirectory
                && !destinationState.isSymbolicLink
                && !policy.presentsDirectoryPackageAsFile(destination.resolved.virtualPath)
            if sourceIsDirectory, !destinationIsDirectory {
                throw MSPWorkspaceFileSystemError.notDirectory(destination.resolved.virtualPath)
            }
            if !sourceIsDirectory, destinationIsDirectory {
                throw MSPWorkspaceFileSystemError.isDirectory(destination.resolved.virtualPath)
            }
            if sourceIsDirectory, destinationIsDirectory {
                let destinationEntries = try FileManager.default.contentsOfDirectory(atPath: destination.url.path)
                guard destinationEntries.isEmpty else {
                    throw MSPWorkspaceFileSystemError.directoryNotEmpty(destination.resolved.virtualPath)
                }
            }
            do {
                try FileManager.default.removeItem(at: destination.url)
            } catch {
                throw MSPWorkspaceFileSystemError.io(
                    path: destination.resolved.virtualPath,
                    operation: "move"
                )
            }
        }

        do {
            try FileManager.default.moveItem(at: source.url, to: destination.url)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: destination.resolved.virtualPath,
                operation: "move"
            )
        }
    }

    public func createSymbolicLink(
        target: String,
        at linkPath: String,
        from currentDirectory: String = "/"
    ) throws {
        let link = try resolveURL(linkPath, from: currentDirectory, requireExisting: false)
        guard link.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.alreadyExists("/")
        }
        try ensureParentDirectory(of: link.resolved.virtualPath, createIfNeeded: false)
        if itemState(at: link.url).exists {
            throw MSPWorkspaceFileSystemError.alreadyExists(link.resolved.virtualPath)
        }

        let destination: String
        if target.hasPrefix("/") {
            destination = try resolveURL(target, from: currentDirectory, requireExisting: false).url.path
        } else {
            destination = target
        }

        do {
            try FileManager.default.createSymbolicLink(
                atPath: link.url.path,
                withDestinationPath: destination
            )
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: link.resolved.virtualPath,
                operation: "symlink"
            )
        }
    }

    public func createHardLink(
        source sourcePath: String,
        at linkPath: String,
        from currentDirectory: String = "/"
    ) throws {
        let source = try resolveURL(sourcePath, from: currentDirectory, requireExisting: true)
        let link = try resolveURL(linkPath, from: currentDirectory, requireExisting: false)
        guard source.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.isDirectory("/")
        }
        guard link.resolved.virtualPath != "/" else {
            throw MSPWorkspaceFileSystemError.alreadyExists("/")
        }

        let sourceInfo = try fileInfo(virtualPath: source.resolved.virtualPath, url: source.url)
        guard sourceInfo.type != .directory else {
            throw MSPWorkspaceFileSystemError.isDirectory(source.resolved.virtualPath)
        }

        try ensureParentDirectory(of: link.resolved.virtualPath, createIfNeeded: false)
        if itemState(at: link.url).exists {
            throw MSPWorkspaceFileSystemError.alreadyExists(link.resolved.virtualPath)
        }

        do {
            try FileManager.default.linkItem(at: source.url, to: link.url)
        } catch {
            throw MSPWorkspaceFileSystemError.io(
                path: link.resolved.virtualPath,
                operation: "link"
            )
        }
    }

    func ensureParentDirectory(
        of virtualPath: String,
        createIfNeeded: Bool
    ) throws {
        let parentVirtualPath = parentPath(of: virtualPath)
        if createIfNeeded, parentVirtualPath != "/" {
            try createDirectory(parentVirtualPath, from: "/", intermediates: true)
        }
        let parent = try resolveURL(parentVirtualPath, from: "/", requireExisting: true)
        let parentInfo = try fileInfo(virtualPath: parentVirtualPath, url: parent.url)
        guard parentInfo.type == .directory else {
            throw MSPWorkspaceFileSystemError.notDirectory(parentVirtualPath)
        }
    }
}

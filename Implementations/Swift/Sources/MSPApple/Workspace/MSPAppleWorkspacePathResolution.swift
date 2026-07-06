import Foundation
import MSPCore

extension MSPFileManagerWorkspaceFileSystem {
    public func resolve(_ path: String, from currentDirectory: String = "/") throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        if isTrashDisplayPath(virtualPath) {
            return MSPResolvedPath(virtualPath: virtualPath)
        }
        return try resolveURL(path, from: currentDirectory, requireExisting: false).resolved
    }

    func resolveURL(
        _ path: String,
        from currentDirectory: String,
        requireExisting: Bool
    ) throws -> (resolved: MSPResolvedPath, url: URL) {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }

        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        guard !isTrashDisplayPath(virtualPath) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }
        guard !policy.isHidden(virtualPath) else {
            throw MSPWorkspaceFileSystemError.hiddenPath(virtualPath)
        }
        if let packageFileAncestor = policy.directoryPackageFileAncestor(in: virtualPath) {
            throw MSPWorkspaceFileSystemError.notDirectory(packageFileAncestor)
        }

        let resolvedURL = url(forVirtualPath: virtualPath)
        guard contains(resolvedURL.standardizedFileURL, in: rootURL.standardizedFileURL) else {
            throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
        }

        try validateSymlinkContainment(
            virtualPath: virtualPath,
            requireExisting: requireExisting
        )

        return (
            MSPResolvedPath(virtualPath: virtualPath, physicalPath: resolvedURL.path),
            resolvedURL
        )
    }

    func url(forVirtualPath virtualPath: String) -> URL {
        var url = rootURL
        for component in MSPWorkspacePathResolver.components(in: virtualPath) {
            url.appendPathComponent(component, isDirectory: false)
        }
        return url.standardizedFileURL
    }

    func validateSymlinkContainment(
        virtualPath: String,
        requireExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let canonicalRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL

        var rootIsDirectory = ObjCBool(false)
        let rootExists = fileManager.fileExists(
            atPath: rootURL.path,
            isDirectory: &rootIsDirectory
        )
        guard rootExists, rootIsDirectory.boolValue else {
            throw MSPWorkspaceFileSystemError.notDirectory("/")
        }

        var cursor = rootURL
        let components = MSPWorkspacePathResolver.components(in: virtualPath)
        guard !components.isEmpty else {
            return
        }

        for component in components {
            cursor.appendPathComponent(component, isDirectory: false)
            let exists = fileManager.fileExists(atPath: cursor.path)
            if exists {
                let resolvedExistingURL = cursor
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard contains(resolvedExistingURL, in: canonicalRootURL) else {
                    throw MSPWorkspaceFileSystemError.accessDenied(virtualPath)
                }
            } else {
                if requireExisting {
                    throw MSPWorkspaceFileSystemError.notFound(virtualPath)
                }
                return
            }
        }
    }

    func contains(_ child: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    func virtualSymbolicLinkTarget(
        _ destination: String,
        linkVirtualPath: String
    ) throws -> String {
        guard destination.hasPrefix("/") else {
            return destination
        }

        let targetURL = URL(fileURLWithPath: destination).standardizedFileURL
        let standardizedRootURL = rootURL.standardizedFileURL
        guard contains(targetURL, in: standardizedRootURL) else {
            throw MSPWorkspaceFileSystemError.accessDenied(linkVirtualPath)
        }
        return virtualPath(forContainedURL: targetURL)
    }

    func virtualPath(forContainedURL url: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let childComponents = url.standardizedFileURL.pathComponents
        let relativeComponents = childComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty else {
            return "/"
        }
        return "/" + relativeComponents.joined(separator: "/")
    }

    func joinVirtualPath(parent: String, child: String) -> String {
        if parent == "/" {
            return "/" + child
        }
        return parent + "/" + child
    }

    func parentPath(of virtualPath: String) -> String {
        var components = MSPWorkspacePathResolver.components(in: virtualPath)
        guard !components.isEmpty else {
            return "/"
        }
        components.removeLast()
        guard !components.isEmpty else {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }
}

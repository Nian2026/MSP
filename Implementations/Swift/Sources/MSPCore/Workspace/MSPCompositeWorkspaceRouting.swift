import Foundation

enum MSPCompositeBackend {
    case base
    case mount(MSPWorkspaceMount)
}

struct MSPCompositeRoute {
    var backend: MSPCompositeBackend
    var virtualPath: String
    var backendPath: String
    var identity: String

    var isMountRoot: Bool {
        if case .mount(let mount) = backend {
            return virtualPath == mount.path
        }
        return false
    }
}

extension MSPCompositeWorkspaceFileSystem {
    func route(_ path: String, from currentDirectory: String) throws -> MSPCompositeRoute {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        for mount in mounts where virtualPath == mount.path || virtualPath.hasPrefix(mount.path + "/") {
            return MSPCompositeRoute(
                backend: .mount(mount),
                virtualPath: virtualPath,
                backendPath: backendPath(forMountedVirtualPath: virtualPath, mountPath: mount.path),
                identity: "mount:\(mount.path)"
            )
        }
        return MSPCompositeRoute(
            backend: .base,
            virtualPath: virtualPath,
            backendPath: virtualPath,
            identity: "base"
        )
    }

    func fileSystem(for route: MSPCompositeRoute) -> any MSPWorkspaceFileSystem {
        switch route.backend {
        case .base:
            return baseFileSystem
        case .mount(let mount):
            return mount.fileSystem
        }
    }
}

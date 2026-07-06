import Foundation

public struct MSPCompositeWorkspace: MSPWorkspace {
    public var rootPath: String { "/" }
    public let fileSystem: any MSPWorkspaceFileSystem

    public init(
        baseFileSystem: any MSPWorkspaceFileSystem,
        mounts: [MSPWorkspaceMount],
        policy: MSPWorkspaceFileSystemPolicy = .default
    ) {
        self.fileSystem = MSPCompositeWorkspaceFileSystem(
            baseFileSystem: baseFileSystem,
            mounts: mounts,
            policy: policy
        )
    }
}

public struct MSPWorkspaceMount: Sendable {
    public var path: String
    public var fileSystem: any MSPWorkspaceFileSystem

    public init(path: String, fileSystem: any MSPWorkspaceFileSystem) {
        self.path = MSPWorkspacePathResolver.normalize(path)
        self.fileSystem = fileSystem
    }
}

public final class MSPCompositeWorkspaceFileSystem: MSPWorkspaceSequentialFileReading, MSPWorkspaceBatchDirectoryEnumerating, MSPWorkspaceBatchCopying, @unchecked Sendable {
    public let policy: MSPWorkspaceFileSystemPolicy

    let baseFileSystem: any MSPWorkspaceFileSystem
    let mounts: [MSPWorkspaceMount]

    public init(
        baseFileSystem: any MSPWorkspaceFileSystem,
        mounts: [MSPWorkspaceMount],
        policy: MSPWorkspaceFileSystemPolicy = .default
    ) {
        self.baseFileSystem = baseFileSystem
        self.mounts = mounts
            .map { MSPWorkspaceMount(path: $0.path, fileSystem: $0.fileSystem) }
            .filter { $0.path != "/" }
            .sorted { $0.path.count > $1.path.count }
        self.policy = policy
    }
}

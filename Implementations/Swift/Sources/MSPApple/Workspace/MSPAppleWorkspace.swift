import Foundation
import MSPCore

public struct MSPAppleWorkspace: MSPWorkspace {
    public var rootPath: String { "/" }
    public let rootURL: URL
    public let fileSystem: any MSPWorkspaceFileSystem

    public init(
        rootURL: URL,
        policy: MSPWorkspaceFileSystemPolicy = .default,
        createIfNeeded: Bool = true
    ) throws {
        let standardizedRootURL = rootURL.standardizedFileURL
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: standardizedRootURL,
                withIntermediateDirectories: true
            )
        }
        self.rootURL = standardizedRootURL
        self.fileSystem = MSPFileManagerWorkspaceFileSystem(
            rootURL: standardizedRootURL,
            policy: policy
        )
    }
}

public struct MSPFileManagerWorkspaceFileSystem: MSPWorkspaceSequentialFileReading, MSPWorkspaceBatchDirectoryEnumerating, MSPWorkspaceTrashCapable, MSPWorkspaceFileTimestamping {
    public let rootURL: URL
    public let policy: MSPWorkspaceFileSystemPolicy

    public var trashConfiguration: MSPWorkspaceTrashConfiguration? {
        policy.trashConfiguration
    }

    public init(
        rootURL: URL,
        policy: MSPWorkspaceFileSystemPolicy = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.policy = policy
    }
}

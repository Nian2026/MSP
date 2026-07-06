import Foundation
import ModelShellProxy
import MSPCore

struct WorkspaceFileNode: Identifiable, Equatable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var type: MSPFileType
    var size: Int64?
    var modificationDate: Date?
    var mediaKind: WorkspaceFileMediaKind?
    var children: [WorkspaceFileNode]?

    init(
        name: String,
        path: String,
        type: MSPFileType,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        mediaKind: WorkspaceFileMediaKind? = nil,
        children: [WorkspaceFileNode]? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.modificationDate = modificationDate
        self.mediaKind = mediaKind
        self.children = children
    }

    var isDirectory: Bool {
        type == .directory
    }

    var isChatPackage: Bool {
        name.hasSuffix(".chat")
    }

    static func loadChildren(
        path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        remainingDepth: Int
    ) throws -> [WorkspaceFileNode] {
        try loadChildren(
            path: path,
            remainingDepth: remainingDepth
        ) { childPath in
            try fileSystem.listDirectory(childPath, from: "/")
        }
    }

    static func loadChildren(
        path: String,
        remainingDepth: Int,
        listDirectory: (String) throws -> [MSPDirectoryEntry]
    ) throws -> [WorkspaceFileNode] {
        guard remainingDepth > 0 else {
            return []
        }

        return try listDirectory(path).map { entry in
            let childPath = entry.virtualPath
            let children: [WorkspaceFileNode]?
            if entry.type == .directory, remainingDepth > 1 {
                children = try loadChildren(
                    path: childPath,
                    remainingDepth: remainingDepth - 1,
                    listDirectory: listDirectory
                )
            } else {
                children = nil
            }

            return WorkspaceFileNode(
                name: entry.name,
                path: childPath,
                type: entry.type,
                size: entry.info.size,
                modificationDate: entry.info.modificationDate,
                mediaKind: entry.type == .regularFile
                    ? WorkspaceFileMediaKind.inferred(fromFileName: entry.name)
                    : nil,
                children: children
            )
        }
    }
}

struct WorkspaceDirectoryPage: Equatable, Sendable {
    var nodes: [WorkspaceFileNode]
    var hasMore: Bool
}

struct WorkspaceFileOpenContext: Equatable, Sendable {
    var directoryPath: String
    var loadedNodes: [WorkspaceFileNode]
    var loadedNodeCount: Int
    var hasMoreNodes: Bool
}

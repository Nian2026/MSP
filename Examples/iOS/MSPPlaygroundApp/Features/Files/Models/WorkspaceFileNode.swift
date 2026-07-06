import Foundation
import ModelShellProxy

struct WorkspaceFileNode: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var path: String
    var type: MSPFileType
    var size: Int64?
    var children: [WorkspaceFileNode]?

    var isDirectory: Bool {
        type == .directory
    }

    static func loadChildren(
        path: String,
        fileSystem: any MSPWorkspaceFileSystem,
        remainingDepth: Int
    ) throws -> [WorkspaceFileNode] {
        guard remainingDepth > 0 else {
            return []
        }

        return try fileSystem.listDirectory(path, from: "/").map { entry in
            let childPath = entry.virtualPath
            let children: [WorkspaceFileNode]?
            if entry.type == .directory {
                children = try loadChildren(
                    path: childPath,
                    fileSystem: fileSystem,
                    remainingDepth: remainingDepth - 1
                )
            } else {
                children = nil
            }

            return WorkspaceFileNode(
                name: entry.name,
                path: childPath,
                type: entry.type,
                size: entry.info.size,
                children: children
            )
        }
    }
}

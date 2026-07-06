import SwiftUI

struct WorkspaceFileTreeView: View {
    var state: WorkspaceFileTreeState
    var reloadToken: String = "pending"
    var rootName = "/"
    var rootPath = "/"
    var showsRoot = true
    var openFile: (WorkspaceFileNode, WorkspaceFileOpenContext?) -> Void = { _, _ in }
    var deleteChatPackage: ((WorkspaceFileNode) -> Void)?
    var restoreTrashItem: ((WorkspaceFileNode) -> Void)?
    var loadChildren: (String) async throws -> [WorkspaceFileNode] = { _ in [] }
    var loadDirectoryPage: (String, Int) async throws -> WorkspaceDirectoryPage = { _, _ in
        WorkspaceDirectoryPage(nodes: [], hasMore: false)
    }
    var loadThumbnail: (WorkspaceFileNode, CGSize) async -> WorkspaceFileThumbnail? = { _, _ in nil }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .photoSorterFont(size: 15)
                    .foregroundStyle(MSPDesignTokens.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let nodes):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if showsRoot {
                            WorkspaceFileNodeRow(
                                node: WorkspaceFileNode(
                                    name: rootName,
                                    path: rootPath,
                                    type: .directory,
                                    size: nil,
                                    modificationDate: nil,
                                    mediaKind: nil,
                                    children: nodes
                                ),
                                depth: 0,
                                reloadToken: reloadToken,
                                openFile: openFile,
                                deleteChatPackage: deleteChatPackage,
                                restoreTrashItem: restoreTrashItem,
                                loadChildren: loadChildren,
                                loadDirectoryPage: loadDirectoryPage,
                                loadThumbnail: loadThumbnail
                            )
                        } else {
                            let openContext = WorkspaceFileOpenContext(
                                directoryPath: rootPath,
                                loadedNodes: nodes,
                                loadedNodeCount: nodes.count,
                                hasMoreNodes: false
                            )
                            ForEach(nodes) { node in
                                WorkspaceFileNodeRow(
                                    node: node,
                                    depth: 0,
                                    reloadToken: reloadToken,
                                    openContext: openContext,
                                    openFile: openFile,
                                    deleteChatPackage: deleteChatPackage,
                                    restoreTrashItem: restoreTrashItem,
                                    canRestoreTrashItem: restoreTrashItem != nil,
                                    loadChildren: loadChildren,
                                    loadDirectoryPage: loadDirectoryPage,
                                    loadThumbnail: loadThumbnail
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

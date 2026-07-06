import SwiftUI

struct WorkspaceFileTreeView: View {
    var state: WorkspaceFileTreeState
    var openFile: (WorkspaceFileNode) -> Void = { _ in }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .mspPlaygroundFont(size: 16)
                    .foregroundStyle(MSPDesignTokens.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let nodes):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        WorkspaceFileNodeRow(
                            node: WorkspaceFileNode(
                                name: "/",
                                path: "/",
                                type: .directory,
                                size: nil,
                                children: nodes
                            ),
                            depth: 0,
                            openFile: openFile
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

import SwiftUI

struct WorkspaceDrawerView: View {
    var treeState: WorkspaceFileTreeState
    var openFile: (WorkspaceFileNode) -> Void = { _ in }

    var body: some View {
        WorkspaceFileTreeView(
            state: treeState,
            openFile: openFile
        )
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
    }
}

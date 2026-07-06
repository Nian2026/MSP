import SwiftUI

struct WorkspaceFileNodeRow: View {
    var node: WorkspaceFileNode
    var depth: Int
    var openFile: (WorkspaceFileNode) -> Void = { _ in }
    @State private var isExpanded = true

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            Button {
                if node.isDirectory {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } else {
                    openFile(node)
                }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)

            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    WorkspaceFileNodeRow(
                        node: child,
                        depth: depth + 1,
                        openFile: openFile
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .mspPlaygroundFont(size: 17, weight: .bold)
                    .frame(width: 22, height: 22)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }

            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .mspPlaygroundFont(size: 24, weight: .semibold)
                .foregroundStyle(node.isDirectory ? MSPDesignTokens.accent : MSPDesignTokens.secondaryInk)
                .frame(width: 32, height: 32)

            Text(node.name)
                .mspPlaygroundFont(size: 24)
                .foregroundStyle(MSPDesignTokens.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let size = node.size, !node.isDirectory {
                Text("\(size)b")
                    .mspPlaygroundFont(size: 16)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

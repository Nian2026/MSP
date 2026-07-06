import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct WorkspaceFileNodeRow: View {
    var node: WorkspaceFileNode
    var depth: Int
    var reloadToken: String = "pending"
    var openContext: WorkspaceFileOpenContext?
    var openFile: (WorkspaceFileNode, WorkspaceFileOpenContext?) -> Void = { _, _ in }
    var deleteChatPackage: ((WorkspaceFileNode) -> Void)?
    var restoreTrashItem: ((WorkspaceFileNode) -> Void)?
    var canRestoreTrashItem = false
    var loadChildren: (String) async throws -> [WorkspaceFileNode] = { _ in [] }
    var loadDirectoryPage: (String, Int) async throws -> WorkspaceDirectoryPage = { _, _ in
        WorkspaceDirectoryPage(nodes: [], hasMore: false)
    }
    var loadThumbnail: (WorkspaceFileNode, CGSize) async -> WorkspaceFileThumbnail? = { _, _ in nil }
    @State private var isExpanded: Bool
    @State private var loadedChildren: [WorkspaceFileNode]?
    @State private var hasMoreChildren = false
    @State private var isLoadingChildren = false
    @State private var isLoadingNextPage = false
    @State private var loadError: String?
    @State private var thumbnail: WorkspaceFileThumbnail?
    @State private var lastLoadedReloadToken: String?

    init(
        node: WorkspaceFileNode,
        depth: Int,
        reloadToken: String = "pending",
        openContext: WorkspaceFileOpenContext? = nil,
        openFile: @escaping (WorkspaceFileNode, WorkspaceFileOpenContext?) -> Void = { _, _ in },
        deleteChatPackage: ((WorkspaceFileNode) -> Void)? = nil,
        restoreTrashItem: ((WorkspaceFileNode) -> Void)? = nil,
        canRestoreTrashItem: Bool = false,
        loadChildren: @escaping (String) async throws -> [WorkspaceFileNode] = { _ in [] },
        loadDirectoryPage: @escaping (String, Int) async throws -> WorkspaceDirectoryPage = { _, _ in
            WorkspaceDirectoryPage(nodes: [], hasMore: false)
        },
        loadThumbnail: @escaping (WorkspaceFileNode, CGSize) async -> WorkspaceFileThumbnail? = { _, _ in nil }
    ) {
        self.node = node
        self.depth = depth
        self.reloadToken = reloadToken
        self.openContext = openContext
        self.openFile = openFile
        self.deleteChatPackage = deleteChatPackage
        self.restoreTrashItem = restoreTrashItem
        self.canRestoreTrashItem = canRestoreTrashItem
        self.loadChildren = loadChildren
        self.loadDirectoryPage = loadDirectoryPage
        self.loadThumbnail = loadThumbnail
        _isExpanded = State(initialValue: depth == 0)
        _loadedChildren = State(initialValue: node.children)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            rowButton

            if isLoadingChildren {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, CGFloat(depth + 1) * 14 + 24)
            }

            if let loadError {
                Text(loadError)
                    .photoSorterFont(size: 15)
                    .foregroundStyle(MSPDesignTokens.error)
                    .padding(.leading, CGFloat(depth + 1) * 14 + 24)
            }

            if isExpanded, let children = loadedChildren, !node.isChatPackage {
                let childOpenContext = WorkspaceFileOpenContext(
                    directoryPath: node.path,
                    loadedNodes: children,
                    loadedNodeCount: children.count,
                    hasMoreNodes: hasMoreChildren
                )
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    WorkspaceFileNodeRow(
                        node: child,
                        depth: depth + 1,
                        reloadToken: reloadToken,
                        openContext: childOpenContext,
                        openFile: openFile,
                        deleteChatPackage: deleteChatPackage,
                        restoreTrashItem: restoreTrashItem,
                        canRestoreTrashItem: restoreTrashItem != nil,
                        loadChildren: loadChildren,
                        loadDirectoryPage: loadDirectoryPage,
                        loadThumbnail: loadThumbnail
                    )
                    .onAppear {
                        guard index >= max(children.count - 12, 0) else {
                            return
                        }
                        Task {
                            await loadNextPageIfNeeded()
                        }
                    }
                }
            }
        }
        .onChange(of: node.children) { _, freshChildren in
            updateLoadedChildren(from: freshChildren)
        }
        .onChange(of: reloadToken) { _, freshToken in
            guard node.isDirectory,
                  depth > 0,
                  (freshToken.hasPrefix("ready-") || freshToken.contains("-tree-"))
            else {
                return
            }
            if isExpanded {
                Task {
                    await reloadDirectoryFromFirstPage(reloadToken: freshToken)
                }
            } else if loadedChildren != nil {
                invalidateLoadedDirectory()
            }
        }
        .task(id: thumbnailTaskID) {
            await loadThumbnailIfNeeded()
        }
        .onChange(of: thumbnailTaskID) { _, _ in
            thumbnail = nil
        }
    }

    @ViewBuilder
    private var rowButton: some View {
        if let restoreTrashItem, canRestoreTrashItem {
            Button {
                openFile(node, openContext)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
            .contextMenu {
                Button {
                    restoreTrashItem(node)
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
            }
        } else if node.isDirectory && !node.isChatPackage {
            Button {
                Task {
                    await toggleDirectory()
                }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
        } else if let deleteChatPackage, node.isChatPackage {
            Button {
                openFile(node, openContext)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
            .contextMenu {
                Button(role: .destructive) {
                    deleteChatPackage(node)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        } else {
            Button {
                openFile(node, openContext)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(node.name)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if node.isDirectory && !node.isChatPackage {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .photoSorterFont(size: 15, weight: .bold)
                    .frame(width: 18, height: 18)
            } else {
                Color.clear.frame(width: 18, height: 18)
            }

            fileIconOrThumbnail

            Text(node.name)
                .photoSorterFont(size: 22)
                .foregroundStyle(MSPDesignTokens.ink)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let size = node.size, !node.isDirectory {
                Text("\(size)b")
                    .photoSorterFont(size: 14)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var thumbnailDimension: CGFloat {
        40
    }

    private var thumbnailRequestSize: CGSize {
        CGSize(width: thumbnailDimension * 3, height: thumbnailDimension * 3)
    }

    private var thumbnailTaskID: String {
        let modifiedMilliseconds = node.modificationDate
            .map { Int($0.timeIntervalSince1970 * 1000) }
            .map(String.init) ?? ""
        return [
            node.path,
            node.mediaKind?.rawValue ?? "",
            reloadToken,
            modifiedMilliseconds,
            "\(Int(thumbnailRequestSize.width))x\(Int(thumbnailRequestSize.height))"
        ].joined(separator: "|")
    }

    @ViewBuilder
    private var fileIconOrThumbnail: some View {
        if node.isChatPackage {
            Image(systemName: "bubble.left.and.bubble.right")
                .photoSorterFont(size: 22, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.accent)
                .frame(width: thumbnailDimension, height: thumbnailDimension)
        } else if node.isDirectory {
            Image(systemName: "folder")
                .photoSorterFont(size: 22, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.accent)
                .frame(width: thumbnailDimension, height: thumbnailDimension)
        } else if let thumbnail {
            thumbnailImage(thumbnail)
                .frame(width: thumbnailDimension, height: thumbnailDimension)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(videoGlyphOverlay)
        } else {
            Image(systemName: fileIconName)
                .photoSorterFont(size: 22, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.secondaryInk)
                .frame(width: thumbnailDimension, height: thumbnailDimension)
                .overlay(videoGlyphOverlay)
        }
    }

    @ViewBuilder
    private func thumbnailImage(_ thumbnail: WorkspaceFileThumbnail) -> some View {
#if canImport(UIKit)
        if let image = UIImage(data: thumbnail.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: fileIconName)
                .photoSorterFont(size: 22, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.secondaryInk)
        }
#elseif canImport(AppKit)
        if let image = NSImage(data: thumbnail.data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: fileIconName)
                .photoSorterFont(size: 22, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.secondaryInk)
        }
#else
        Image(systemName: fileIconName)
            .photoSorterFont(size: 22, weight: .semibold)
            .foregroundStyle(MSPDesignTokens.secondaryInk)
#endif
    }

    @ViewBuilder
    private var videoGlyphOverlay: some View {
        if node.mediaKind == .video {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.55))
                    .frame(width: 14, height: 14)
                Image(systemName: "play.fill")
                    .photoSorterFont(size: 7, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.leading, 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var fileIconName: String {
        switch node.mediaKind {
        case .image:
            return "photo"
        case .video:
            return "film"
        case nil:
            return "doc.text"
        }
    }

    @MainActor
    private func toggleDirectory() async {
        if isExpanded {
            withAnimation(.easeOut(duration: 0.16)) {
                isExpanded = false
            }
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            isExpanded = true
        }

        guard !isLoadingChildren else {
            return
        }
        if loadedChildren != nil,
           lastLoadedReloadToken == reloadToken {
            return
        }

        isLoadingChildren = true
        loadError = nil
        do {
            try await loadFirstDirectoryPage()
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingChildren = false
    }

    @MainActor
    private func loadNextPageIfNeeded() async {
        guard isExpanded,
              hasMoreChildren,
              !isLoadingChildren,
              !isLoadingNextPage,
              var children = loadedChildren
        else {
            return
        }

        isLoadingNextPage = true
        defer {
            isLoadingNextPage = false
        }

        do {
            let page = try await loadDirectoryPage(node.path, children.count)
            let existingIDs = Set(children.map(\.id))
            let freshNodes = page.nodes.filter { !existingIDs.contains($0.id) }
            children.append(contentsOf: freshNodes)
            loadedChildren = children
            hasMoreChildren = page.hasMore && !freshNodes.isEmpty
            lastLoadedReloadToken = reloadToken
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func updateLoadedChildren(from freshChildren: [WorkspaceFileNode]?) {
        guard let freshChildren, loadedChildren != freshChildren else {
            return
        }
        loadedChildren = freshChildren
        hasMoreChildren = false
        loadError = nil
        lastLoadedReloadToken = reloadToken
    }

    @MainActor
    private func invalidateLoadedDirectory() {
        loadedChildren = nil
        hasMoreChildren = false
        isLoadingNextPage = false
        loadError = nil
        lastLoadedReloadToken = nil
    }

    @MainActor
    private func reloadDirectoryFromFirstPage(reloadToken token: String? = nil) async {
        guard node.isDirectory, !isLoadingChildren else {
            return
        }
        isLoadingChildren = true
        isLoadingNextPage = false
        loadError = nil
        do {
            try await loadFirstDirectoryPage()
            lastLoadedReloadToken = token ?? reloadToken
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingChildren = false
    }

    @MainActor
    private func loadFirstDirectoryPage() async throws {
        let page = try await loadDirectoryPage(node.path, 0)
        loadedChildren = page.nodes
        hasMoreChildren = page.hasMore
        lastLoadedReloadToken = reloadToken
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard !node.isDirectory, node.mediaKind != nil else {
            thumbnail = nil
            return
        }
        let loadedThumbnail = await loadThumbnail(node, thumbnailRequestSize)
        guard !Task.isCancelled else {
            return
        }
        thumbnail = loadedThumbnail
    }
}

import SwiftUI

struct WorkspaceDrawerView: View {
    var treeState: WorkspaceFileTreeState
    var trashTreeState: WorkspaceFileTreeState = .loaded([])
    var workspaceTreeRevision = 0
    var workspaceTrashRevision = 0
    var agentAccessMode: PhotoSorterAgentAccessMode = .standard
    var photoLibraryIndexStatus: PhotoLibraryIndexStatus = .idle
    var photoLibraryOCRCacheStatus: PhotoSorterMediaOCRCacheStatus = .idle
    var photoLibraryVLMSummaryCacheStatus: PhotoSorterMediaVLMStatus = .unavailable
    var photoLibraryPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus = .idle
    var photoLibraryWorkspaceChangeSummary: PhotoLibraryWorkspaceChangeSummary = .idle
    var isSyncingPhotoLibraryWorkspaceChanges = false
    var photoLibraryWorkspaceSyncError: String?
    var workspaceTrashErrorMessage: String?
    var isEmptyingWorkspaceTrash = false
    var isRestoringWorkspaceTrash = false
    var openFile: (WorkspaceFileNode, WorkspaceFileOpenContext?) -> Void = { _, _ in }
    var deleteChatPackage: (WorkspaceFileNode) -> Void = { _ in }
    var restoreTrashItem: (WorkspaceFileNode) -> Void = { _ in }
    var startOCRCachePreheat: () -> Void = {}
    var pauseOCRCachePreheat: () -> Void = {}
    var resumeOCRCachePreheat: () -> Void = {}
    var startVLMSummaryCachePreheat: () -> Void = {}
    var pauseVLMSummaryCachePreheat: () -> Void = {}
    var resumeVLMSummaryCachePreheat: () -> Void = {}
    var startPlaceCachePreheat: () -> Void = {}
    var pausePlaceCachePreheat: () -> Void = {}
    var resumePlaceCachePreheat: () -> Void = {}
    var syncPhotoLibraryWorkspaceChanges: () -> Void = {}
    var refreshWorkspaceTrash: () -> Void = {}
    var emptyWorkspaceTrash: () -> Void = {}
    var restoreAllWorkspaceTrash: () -> Void = {}
    var loadChildren: (String) async throws -> [WorkspaceFileNode] = { _ in [] }
    var loadDirectoryPage: (String, Int) async throws -> WorkspaceDirectoryPage = { _, _ in
        WorkspaceDirectoryPage(nodes: [], hasMore: false)
    }
    var loadThumbnail: (WorkspaceFileNode, CGSize) async -> WorkspaceFileThumbnail? = { _, _ in nil }
    @State private var drawerMode: WorkspaceDrawerMode = .workspace
    @State private var isEmptyTrashConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            switch drawerMode {
            case .workspace:
                workspaceContent
            case .trash:
                trashContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
        .alert("清空废纸篓？", isPresented: $isEmptyTrashConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                emptyWorkspaceTrash()
            }
        } message: {
            Text("废纸篓中的工作区文件会被永久删除。")
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 0) {
            PhotoLibraryIndexStatusView(status: photoLibraryIndexStatus)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 8)

            PhotoLibraryOCRCacheStatusView(
                status: photoLibraryOCRCacheStatus,
                startPreheat: startOCRCachePreheat,
                pausePreheat: pauseOCRCachePreheat,
                resumePreheat: resumeOCRCachePreheat
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            PhotoLibraryVLMSummaryCacheStatusView(
                status: photoLibraryVLMSummaryCacheStatus,
                isFullAccess: agentAccessMode == .full,
                startPreheat: startVLMSummaryCachePreheat,
                pausePreheat: pauseVLMSummaryCachePreheat,
                resumePreheat: resumeVLMSummaryCachePreheat
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            PhotoLibraryPlaceCacheStatusView(
                status: photoLibraryPlaceCacheStatus,
                isFullAccess: agentAccessMode == .full,
                startPreheat: startPlaceCachePreheat,
                pausePreheat: pausePlaceCachePreheat,
                resumePreheat: resumePlaceCachePreheat
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            PhotoLibraryWorkspaceChangesStatusView(
                summary: photoLibraryWorkspaceChangeSummary,
                isSyncing: isSyncingPhotoLibraryWorkspaceChanges,
                errorMessage: photoLibraryWorkspaceSyncError,
                syncChanges: syncPhotoLibraryWorkspaceChanges
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            workspaceTreeHeader
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            WorkspaceFileTreeView(
                state: treeState,
                reloadToken: workspaceTreeReloadToken,
                openFile: openFile,
                deleteChatPackage: deleteChatPackage,
                loadChildren: loadChildren,
                loadDirectoryPage: loadDirectoryPage,
                loadThumbnail: loadThumbnail
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trashContent: some View {
        VStack(spacing: 0) {
            trashHeader
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if let workspaceTrashErrorMessage, !workspaceTrashErrorMessage.isEmpty {
                Text(workspaceTrashErrorMessage)
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            WorkspaceFileTreeView(
                state: trashTreeState,
                reloadToken: workspaceTrashReloadToken,
                rootName: "废纸篓",
                rootPath: PhotoSorterWorkspace.workspaceTrashDisplayRootPath,
                showsRoot: false,
                openFile: { _, _ in },
                restoreTrashItem: restoreTrashItem,
                loadChildren: loadChildren,
                loadDirectoryPage: loadDirectoryPage,
                loadThumbnail: loadThumbnail
            )
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var workspaceTreeHeader: some View {
        HStack(spacing: 10) {
            Text("工作区")
                .photoSorterFont(size: 16, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.ink)

            Spacer(minLength: 8)

            Button {
                drawerMode = .trash
                refreshWorkspaceTrash()
            } label: {
                Label("废纸篓", systemImage: "trash")
                    .photoSorterFont(size: 13, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开废纸篓")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trashHeader: some View {
        HStack(spacing: 8) {
            Button {
                drawerMode = .workspace
            } label: {
                Image(systemName: "chevron.left")
                    .photoSorterFont(size: 18, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回工作区")

            Text("废纸篓")
                .photoSorterFont(size: 20, weight: .semibold)
                .foregroundStyle(MSPDesignTokens.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                restoreAllWorkspaceTrash()
            } label: {
                if isRestoringWorkspaceTrash {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 82, height: 36)
                } else {
                    Text("全部恢复")
                        .photoSorterFont(size: 14, weight: .semibold)
                        .foregroundStyle(MSPDesignTokens.ink)
                        .frame(width: 82, height: 36)
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorkspaceTrashEmpty || isRestoringWorkspaceTrash || isEmptyingWorkspaceTrash)
            .accessibilityLabel("全部恢复废纸篓")

            Button {
                isEmptyTrashConfirmationPresented = true
            } label: {
                if isEmptyingWorkspaceTrash {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 56, height: 36)
                } else {
                    Text("清空")
                        .photoSorterFont(size: 14, weight: .semibold)
                        .foregroundStyle(MSPDesignTokens.error)
                        .frame(width: 56, height: 36)
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorkspaceTrashEmpty || isEmptyingWorkspaceTrash || isRestoringWorkspaceTrash)
            .accessibilityLabel("清空废纸篓")
        }
    }

    private var workspaceTreeReloadToken: String {
        let explicitTreeRefresh = workspaceTreeRevision > 0 ? "-tree-\(workspaceTreeRevision)" : ""
        guard photoLibraryIndexStatus.phase == .ready else {
            return "pending-\(photoLibraryWorkspaceChangeSummary.version)\(explicitTreeRefresh)"
        }
        return "ready-\(photoLibraryIndexStatus.version)-workspace-\(photoLibraryWorkspaceChangeSummary.version)\(explicitTreeRefresh)"
    }

    private var workspaceTrashReloadToken: String {
        "trash-\(workspaceTrashRevision)-workspace-\(photoLibraryWorkspaceChangeSummary.version)"
    }

    private var isWorkspaceTrashEmpty: Bool {
        guard case .loaded(let nodes) = trashTreeState else {
            return true
        }
        return nodes.isEmpty
    }
}

private enum WorkspaceDrawerMode {
    case workspace
    case trash
}

private struct PhotoLibraryWorkspaceChangesStatusView: View {
    var summary: PhotoLibraryWorkspaceChangeSummary
    var isSyncing: Bool
    var errorMessage: String?
    var syncChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: summary.hasChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(summary.hasChanges ? MSPDesignTokens.accent : MSPDesignTokens.secondaryInk)
                    .frame(width: 18, height: 18)

                Text("系统相册同步")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }

                PhotoSorterLiquidGlassTextButton("同步", controlSize: .small, fontSize: 12) {
                    syncChanges()
                }
                .disabled(!summary.hasChanges || isSyncing)
            }

            Text(message)
                .photoSorterFont(size: 13)
                .foregroundStyle(errorMessage == nil ? MSPDesignTokens.secondaryInk : MSPDesignTokens.error)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if isSyncing {
            return "正在准备或同步系统相册"
        }
        guard summary.hasChanges else {
            return "没有待同步变更"
        }
        return [
            summary.trashedAssetCount > 0 ? "删除 \(summary.trashedAssetCount)" : nil,
            summary.deletedAlbumCount > 0 ? "删除相册 \(summary.deletedAlbumCount)" : nil,
            summary.pendingAlbumCreationCount > 0 ? "新建相册 \(summary.pendingAlbumCreationCount)" : nil,
            summary.pendingAlbumMembershipAdditionCount > 0 ? "加入相册 \(summary.pendingAlbumMembershipAdditionCount)" : nil,
            summary.pendingAlbumMembershipRemovalCount > 0 ? "移出相册 \(summary.pendingAlbumMembershipRemovalCount)" : nil
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct PhotoLibraryPlaceCacheStatusView: View {
    var status: PhotoSorterMediaPlaceCacheStatus
    var isFullAccess: Bool
    var startPreheat: () -> Void
    var pausePreheat: () -> Void
    var resumePreheat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .frame(width: 18, height: 18)

                Text("地点缓存")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(status.cachedCount)/\(status.totalCount)")
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)

                preheatButton
            }

            if status.isPreheating || status.isPaused {
                if let progress = status.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let message = messageText, !message.isEmpty {
                Text(message)
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preheatButton: some View {
        if status.isPreheating {
            PhotoSorterLiquidGlassTextButton("暂停", controlSize: .small, fontSize: 12) {
                pausePreheat()
            }
            .disabled(!isFullAccess)
        } else if status.isPaused {
            PhotoSorterLiquidGlassTextButton("继续", controlSize: .small, fontSize: 12) {
                resumePreheat()
            }
            .disabled(!isFullAccess)
        } else {
            PhotoSorterLiquidGlassTextButton("开始", controlSize: .small, fontSize: 12) {
                startPreheat()
            }
            .disabled(!isFullAccess || status.totalCount == 0 || status.cachedCount >= status.totalCount)
        }
    }

    private var messageText: String? {
        if !isFullAccess {
            return "完全访问模式后可缓存地点"
        }
        return status.message
    }
}

private struct PhotoLibraryVLMSummaryCacheStatusView: View {
    var status: PhotoSorterMediaVLMStatus
    var isFullAccess: Bool
    var startPreheat: () -> Void
    var pausePreheat: () -> Void
    var resumePreheat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .frame(width: 18, height: 18)

                Text("视觉摘要缓存")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(status.cachedCount)/\(status.totalCount)")
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)

                preheatButton
            }

            if status.isPreheating || status.isPaused {
                if let progress = status.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(statusLine)
                .photoSorterFont(size: 13)
                .foregroundStyle(MSPDesignTokens.secondaryInk)
                .lineLimit(1)

            if let message = messageText, !message.isEmpty {
                Text(message)
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preheatButton: some View {
        if status.isPreheating {
            PhotoSorterLiquidGlassTextButton("暂停", controlSize: .small, fontSize: 12) {
                pausePreheat()
            }
            .disabled(!isFullAccess)
        } else if status.isPaused {
            PhotoSorterLiquidGlassTextButton("继续", controlSize: .small, fontSize: 12) {
                resumePreheat()
            }
            .disabled(!isFullAccess)
        } else {
            PhotoSorterLiquidGlassTextButton("开始", controlSize: .small, fontSize: 12) {
                startPreheat()
            }
            .disabled(
                !isFullAccess
                    || !status.primaryProvider.isLiveSummarizationAvailable
                    || status.totalCount == 0
                    || status.cachedCount >= status.totalCount
            )
        }
    }

    private var statusLine: String {
        "模型状态：\(modelStateText) · 本批 \(status.processedInCurrentBatch)/\(status.batchLimit) · 失败 \(status.failedInCurrentBatch) · 跳过 \(status.skippedInCurrentBatch)"
    }

    private var modelStateText: String {
        switch status.primaryProvider.modelState {
        case .notInstalled:
            return "未安装"
        case .installed:
            return "已安装"
        case .unavailable:
            return "不可用"
        case .running:
            return "正在运行"
        }
    }

    private var messageText: String? {
        if !isFullAccess {
            return "完全访问模式后可缓存视觉摘要"
        }
        return status.message ?? status.primaryProvider.reason
    }
}

private struct PhotoLibraryOCRCacheStatusView: View {
    var status: PhotoSorterMediaOCRCacheStatus
    var startPreheat: () -> Void
    var pausePreheat: () -> Void
    var resumePreheat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .frame(width: 18, height: 18)

                Text("OCR缓存")
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(status.cachedCount)/\(status.totalCount)")
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)

                preheatButton
            }

            if status.isPreheating || status.isPaused {
                if let progress = status.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preheatButton: some View {
        if status.isPreheating {
            PhotoSorterLiquidGlassTextButton("暂停", controlSize: .small, fontSize: 12) {
                pausePreheat()
            }
        } else if status.isPaused {
            PhotoSorterLiquidGlassTextButton("继续", controlSize: .small, fontSize: 12) {
                resumePreheat()
            }
        } else {
            PhotoSorterLiquidGlassTextButton("开始", controlSize: .small, fontSize: 12) {
                startPreheat()
            }
            .disabled(status.totalCount == 0 || status.cachedCount >= status.totalCount)
        }
    }
}

private struct PhotoLibraryIndexStatusView: View {
    var status: PhotoLibraryIndexStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(symbolColor)
                    .frame(width: 18, height: 18)

                Text(title)
                    .photoSorterFont(size: 15, weight: .semibold)
                    .foregroundStyle(MSPDesignTokens.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let countText {
                    Text(countText)
                        .photoSorterFont(size: 13)
                        .foregroundStyle(MSPDesignTokens.secondaryInk)
                        .lineLimit(1)
                }
            }

            switch status.phase {
            case .loadingPersisted, .building, .refreshing, .rebuilding, .validating, .dirty:
                if let progress = status.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                Text(status.message ?? "照片库同步失败")
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.error)
                    .lineLimit(2)
            case .ready, .idle:
                EmptyView()
            }

            if let currentPath = status.currentPath,
               status.phase == .building || status.phase == .refreshing || status.phase == .rebuilding || status.phase == .validating {
                Text(currentPath)
                    .photoSorterFont(size: 13)
                    .foregroundStyle(MSPDesignTokens.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status.phase {
        case .idle:
            return "照片库索引待启动"
        case .loadingPersisted:
            return "正在加载照片库缓存"
        case .validating:
            return "正在校验照片库"
        case .building:
            return "正在同步照片库"
        case .refreshing:
            return "正在刷新照片库"
        case .rebuilding:
            return "正在重建照片库"
        case .ready:
            return "照片库已同步"
        case .dirty:
            return "照片库需要刷新"
        case .failed:
            return "照片库同步失败"
        }
    }

    private var symbolName: String {
        switch status.phase {
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .dirty:
            return "arrow.clockwise.circle"
        case .idle:
            return "photo.on.rectangle"
        case .loadingPersisted, .validating, .building, .refreshing, .rebuilding:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var symbolColor: Color {
        switch status.phase {
        case .failed:
            return MSPDesignTokens.error
        case .ready:
            return MSPDesignTokens.accent
        default:
            return MSPDesignTokens.secondaryInk
        }
    }

    private var countText: String? {
        guard let total = status.total, total > 0 else {
            return nil
        }
        return "\(min(status.processed, total))/\(total)"
    }
}

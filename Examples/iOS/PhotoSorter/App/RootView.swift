import SwiftUI
#if canImport(AVKit)
import AVKit
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = MSPPlaygroundViewModel()
    @State private var isWorkspaceDrawerOpen = ProcessInfo.processInfo.arguments.contains("--msp-workspace-drawer-open")
    @State private var appFontScale = PhotoSorterTypography.loadFontScale()
    private let isModelConfigurationAvailable = !ProcessInfo.processInfo.arguments.contains("--msp-hide-model-settings")

    var body: some View {
        ZStack {
            MSPDesignTokens.pageBackground
                .ignoresSafeArea()

            WorkspaceDrawerContainer(isOpen: $isWorkspaceDrawerOpen) {
                ChatView(
                    viewModel: viewModel,
                    isModelConfigurationAvailable: isModelConfigurationAvailable,
                    fontScale: $appFontScale
                )
            } drawer: {
                WorkspaceDrawerView(
                    treeState: viewModel.fileTreeState,
                    trashTreeState: viewModel.workspaceTrashTreeState,
                    workspaceTreeRevision: viewModel.workspaceTreeRevision,
                    workspaceTrashRevision: viewModel.workspaceTrashRevision,
                    agentAccessMode: viewModel.agentAccessMode,
                    photoLibraryIndexStatus: viewModel.photoLibraryIndexStatus,
                    photoLibraryOCRCacheStatus: viewModel.photoLibraryOCRCacheStatus,
                    photoLibraryVLMSummaryCacheStatus: viewModel.photoLibraryVLMSummaryCacheStatus,
                    photoLibraryPlaceCacheStatus: viewModel.photoLibraryPlaceCacheStatus,
                    photoLibraryWorkspaceChangeSummary: viewModel.photoLibraryWorkspaceChangeSummary,
                    isSyncingPhotoLibraryWorkspaceChanges: viewModel.isSyncingPhotoLibraryWorkspaceChanges,
                    photoLibraryWorkspaceSyncError: viewModel.photoLibraryWorkspaceSyncError,
                    workspaceTrashErrorMessage: viewModel.workspaceTrashErrorMessage,
                    isEmptyingWorkspaceTrash: viewModel.isEmptyingWorkspaceTrash,
                    isRestoringWorkspaceTrash: viewModel.isRestoringWorkspaceTrash,
                    openFile: { node, context in
                        viewModel.openWorkspaceFile(node, context: context)
                    },
                    deleteChatPackage: viewModel.deleteWorkspaceChatPackage,
                    restoreTrashItem: viewModel.restoreWorkspaceTrashItem,
                    startOCRCachePreheat: viewModel.startOCRCachePreheatBatch,
                    pauseOCRCachePreheat: viewModel.pauseOCRCachePreheat,
                    resumeOCRCachePreheat: viewModel.resumeOCRCachePreheat,
                    startVLMSummaryCachePreheat: viewModel.startVLMSummaryCachePreheatBatch,
                    pauseVLMSummaryCachePreheat: viewModel.pauseVLMSummaryCachePreheat,
                    resumeVLMSummaryCachePreheat: viewModel.resumeVLMSummaryCachePreheat,
                    startPlaceCachePreheat: viewModel.startPlaceCachePreheatBatch,
                    pausePlaceCachePreheat: viewModel.pausePlaceCachePreheat,
                    resumePlaceCachePreheat: viewModel.resumePlaceCachePreheat,
                    syncPhotoLibraryWorkspaceChanges: viewModel.requestSyncPhotoLibraryWorkspaceChanges,
                    refreshWorkspaceTrash: viewModel.refreshWorkspaceTrash,
                    emptyWorkspaceTrash: viewModel.emptyWorkspaceTrash,
                    restoreAllWorkspaceTrash: viewModel.restoreAllWorkspaceTrash,
                    loadChildren: viewModel.loadWorkspaceChildren,
                    loadDirectoryPage: viewModel.loadWorkspaceDirectoryPage,
                    loadThumbnail: viewModel.loadWorkspaceThumbnail
                )
            }
        }
        .task {
            viewModel.updateScenePhase(scenePhase)
            await viewModel.start()
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            viewModel.updateScenePhase(newPhase)
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.updateApplicationForegroundState(
                isActive: true,
                source: "UIApplication.didBecomeActive"
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.updateApplicationForegroundState(
                isActive: false,
                source: "UIApplication.willResignActive"
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.updateApplicationForegroundState(
                isActive: false,
                source: "UIApplication.didEnterBackground"
            )
        }
#endif
        .environment(\.photoSorterFontScale, appFontScale)
        .dynamicTypeSize(PhotoSorterTypography.dynamicTypeSize(for: appFontScale))
        .onChange(of: appFontScale) { _, newValue in
            let clampedScale = PhotoSorterTypography.clampedScale(newValue)
            if clampedScale != newValue {
                appFontScale = clampedScale
            }
            PhotoSorterTypography.saveFontScale(clampedScale)
        }
        .photoSorterPreviewCover(
            item: $viewModel.workspaceMediaPreview,
            restoreFromTrash: viewModel.restoreWorkspaceTrashFromPreview,
            showPrevious: viewModel.showPreviousWorkspacePreviewItem,
            showNext: viewModel.showNextWorkspacePreviewItem,
            selectItem: { path in
                viewModel.selectWorkspacePreviewItem(path: path)
            },
            preparePage: { path in
                viewModel.prepareWorkspacePreviewPage(path: path)
            }
        )
#if canImport(QuickLook)
        .quickLookPreview($viewModel.workspaceQuickLookURL)
#endif
        .sheet(item: $viewModel.mediaViewAuthorizationPrompt) { prompt in
            PhotoSorterMediaViewAuthorizationSheet(
                prompt: prompt,
                allowSelected: { selectedItemIDs, note, reviewedItems, skippedFailures in
                    viewModel.allowMediaViewAuthorization(
                        selectedItemIDs: selectedItemIDs,
                        note: note,
                        reviewedItems: reviewedItems,
                        skippedFailures: skippedFailures
                    )
                },
                denyAll: viewModel.denyMediaViewAuthorization,
                cancel: { reviewedItems, skippedFailures in
                    viewModel.cancelMediaViewAuthorization(
                        reviewedItems: reviewedItems,
                        skippedFailures: skippedFailures
                    )
                }
            )
        }
        .sheet(item: $viewModel.photoLibraryWorkspaceSyncConfirmation) { confirmation in
            PhotoLibraryWorkspaceSyncConfirmationSheet(
                confirmation: confirmation,
                confirmSync: viewModel.confirmSyncPhotoLibraryWorkspaceChanges
            )
        }
    }
}

private struct WorkspaceMediaPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var preview: WorkspaceMediaPreview
    @State private var selectedPath: String
    var restoreFromTrash: (WorkspaceMediaPreview) -> Void
    var showPrevious: () -> Void
    var showNext: () -> Void
    var selectItem: (String) -> Void
    var preparePage: (String) -> Void

    init(
        preview: WorkspaceMediaPreview,
        restoreFromTrash: @escaping (WorkspaceMediaPreview) -> Void = { _ in },
        showPrevious: @escaping () -> Void = {},
        showNext: @escaping () -> Void = {},
        selectItem: @escaping (String) -> Void = { _ in },
        preparePage: @escaping (String) -> Void = { _ in }
    ) {
        self.preview = preview
        self.restoreFromTrash = restoreFromTrash
        self.showPrevious = showPrevious
        self.showNext = showNext
        self.selectItem = selectItem
        self.preparePage = preparePage
        _selectedPath = State(initialValue: preview.path)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                galleryPager
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                galleryNavigationOverlay
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
            .navigationTitle(preview.title)
            .photoSorterPreviewNavigationStyle()
            .onChange(of: preview.path) { _, path in
                guard selectedPath != path else {
                    return
                }
                selectedPath = path
            }
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    PhotoSorterToolbarTextButton("完成") {
                        dismiss()
                    }
                }
                if preview.canRestoreFromTrash {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            restoreFromTrash(preview)
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(preview.isRestoringFromTrash)
                    }
                }
#else
                ToolbarItem(placement: .automatic) {
                    PhotoSorterToolbarTextButton("完成") {
                        dismiss()
                    }
                }
                if preview.canRestoreFromTrash {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            restoreFromTrash(preview)
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(preview.isRestoringFromTrash)
                    }
                }
#endif
            }
        }
    }

    private var previewSelection: Binding<String> {
        Binding(
            get: {
                selectedPath
            },
            set: { path in
                guard path != selectedPath else {
                    return
                }
                selectedPath = path
                selectItem(path)
                preparePage(path)
            }
        )
    }

    @ViewBuilder
    private var galleryPager: some View {
        if preview.galleryItems.isEmpty {
            previewPage(for: preview.path)
        } else {
            TabView(selection: previewSelection) {
                ForEach(preview.galleryItems) { item in
                    previewPage(for: item.path)
                        .tag(item.path)
                        .onAppear {
                            preparePage(item.path)
                        }
                }
            }
            .photoSorterPreviewPagerStyle()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func previewPage(for path: String) -> some View {
        ZStack {
#if canImport(UIKit)
            if preview.isLoading(path) || (path == preview.path && preview.isLoading) {
                ProgressView("正在加载预览…")
            } else if let media = preview.media(for: path) {
                PhotoSorterMediaPreviewContent(media: media, resetID: path)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let imageData = preview.imageData(for: path) {
                PhotoSorterZoomableMediaDataImage(data: imageData, resetID: path)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if path != preview.path {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "无法预览",
                    systemImage: "photo",
                    description: Text(preview.message(for: path) ?? preview.message ?? "这个文件暂时没有可用预览。")
                )
            }
#else
            ContentUnavailableView(
                "无法预览",
                systemImage: "photo",
                description: Text(preview.message(for: path) ?? preview.message ?? "这个平台暂时没有可用预览。")
            )
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var galleryNavigationOverlay: some View {
        if preview.canNavigateToPreviousGalleryItem
            || preview.canNavigateToNextGalleryItem
            || preview.isLoadingMoreGalleryItems {
            HStack {
                galleryNavigationButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "上一张",
                    isEnabled: preview.canNavigateToPreviousGalleryItem,
                    action: showPreviousPage
                )

                Spacer(minLength: 0)

                galleryNavigationButton(
                    systemName: "chevron.right",
                    accessibilityLabel: "下一张",
                    isEnabled: preview.canNavigateToNextGalleryItem && !preview.isLoadingMoreGalleryItems,
                    action: showNextPage
                )
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if preview.isLoadingMoreGalleryItems {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private func galleryNavigationButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .photoSorterFont(size: 28, weight: .semibold)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func showPreviousPage() {
        selectLoadedPage(offset: -1, fallback: showPrevious)
    }

    private func showNextPage() {
        selectLoadedPage(offset: 1, fallback: showNext)
    }

    private func selectLoadedPage(offset: Int, fallback: () -> Void) {
        guard let currentIndex = preview.galleryItems.firstIndex(where: { $0.path == selectedPath }) else {
            fallback()
            return
        }
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0, targetIndex < preview.galleryItems.count else {
            fallback()
            return
        }

        let path = preview.galleryItems[targetIndex].path
        selectedPath = path
        selectItem(path)
        preparePage(path)
    }

}

private struct PhotoLibraryWorkspaceSyncConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let confirmation: PhotoLibraryWorkspaceSyncConfirmation
    var confirmSync: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("确认同步到系统相册")
                    .photoSorterFont(size: 20, weight: .semibold)
                    .foregroundStyle(Color.primary)

                VStack(alignment: .leading, spacing: 10) {
                    summaryRow("删除照片", count: confirmation.changeSet.trashedAssetLocalIdentifiers.count)
                    summaryRow("新建相册", count: confirmation.changeSet.createdAlbums.count)
                    summaryRow("删除相册", count: confirmation.changeSet.deletedAlbums.count)
                    summaryRow("加入相册", count: confirmation.changeSet.membershipAdditionCount)
                    summaryRow("移出相册", count: confirmation.changeSet.membershipRemovalCount)
                }

                Text("删除照片会进入系统相册的最近删除。删除相册会移除相册本身；如果是用 rm -r 删除相册，其中照片也会进入系统最近删除。本 App 不提供清空最近删除。")
                    .photoSorterFont(size: 13)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(5)

                if !confirmation.changeSet.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("需要先处理的冲突")
                            .photoSorterFont(size: 14, weight: .semibold)
                            .foregroundStyle(MSPDesignTokens.error)
                        ForEach(confirmation.changeSet.conflicts) { conflict in
                            Text(conflict.message)
                                .photoSorterFont(size: 12)
                                .foregroundStyle(MSPDesignTokens.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    PhotoSorterLiquidGlassTextButton("取消") {
                        dismiss()
                    }

                    Spacer(minLength: 0)

                    PhotoSorterLiquidGlassTextButton("确认同步", role: .destructive) {
                        confirmSync()
                        dismiss()
                    }
                    .disabled(confirmation.changeSet.hasConflicts)
                }
            }
            .padding(18)
            .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
            .navigationTitle("同步确认")
            .photoSorterPreviewNavigationStyle()
        }
        .interactiveDismissDisabled(false)
    }

    private func summaryRow(_ title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .photoSorterFont(size: 15, weight: .medium)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text("\(count)")
                .photoSorterFont(size: 15, weight: .semibold)
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        }
    }
}

private extension PhotoLibraryWorkspaceSyncChangeSet {
    var membershipAdditionCount: Int {
        membershipAdditions.reduce(0) { $0 + $1.assetLocalIdentifiers.count }
    }

    var membershipRemovalCount: Int {
        membershipRemovals.reduce(0) { $0 + $1.assetLocalIdentifiers.count }
    }
}

private struct PhotoSorterMediaViewAuthorizationSheet: View {
    let prompt: PhotoSorterMediaViewAuthorizationPrompt
    var allowSelected: (Set<UUID>, String, [PhotoSorterMediaViewItem], [PhotoSorterMediaViewFailure]) -> Void
    var denyAll: () -> Void
    var cancel: ([PhotoSorterMediaViewItem], [PhotoSorterMediaViewFailure]) -> Void
    @State private var selectedItemIDs: Set<UUID>
    @State private var loadedItemsByIndex: [Int: PhotoSorterMediaViewItem]
    @State private var failuresByIndex: [Int: PhotoSorterMediaViewFailure] = [:]
    @State private var loadingIndices: Set<Int> = []
    @State private var manualSelectionByIndex: [Int: Bool] = [:]
    @State private var expandedReasonSlotIDs: Set<Int> = []
    @State private var previewItem: PhotoSorterMediaViewItem?
    @State private var note = ""
    @State private var isControlPanelCollapsed = false
    @GestureState private var controlPanelDragOffset: CGFloat = 0

    init(
        prompt: PhotoSorterMediaViewAuthorizationPrompt,
        allowSelected: @escaping (Set<UUID>, String, [PhotoSorterMediaViewItem], [PhotoSorterMediaViewFailure]) -> Void,
        denyAll: @escaping () -> Void,
        cancel: @escaping ([PhotoSorterMediaViewItem], [PhotoSorterMediaViewFailure]) -> Void
    ) {
        self.prompt = prompt
        self.allowSelected = allowSelected
        self.denyAll = denyAll
        self.cancel = cancel
        let initialItems = Dictionary(uniqueKeysWithValues: prompt.items.enumerated().map { index, item in
            (index, item)
        })
        _loadedItemsByIndex = State(initialValue: initialItems)
        _selectedItemIDs = State(initialValue: Set(prompt.items.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlPanel

                GeometryReader { proxy in
                    let columns = Self.columns(for: proxy.size.width)
                    let columnWidth = Self.columnWidth(for: proxy.size.width)
                    let bottomInset = max(proxy.safeAreaInsets.bottom, 14)
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(reviewSlots) { slot in
                                    PhotoSorterMediaViewAuthorizationCell(
                                        slot: slot,
                                        thumbnailWidth: columnWidth,
                                        isSelected: slot.item.map { selectedItemIDs.contains($0.id) } ?? false,
                                        toggleSelection: {
                                            toggleSelection(for: slot.id)
                                        },
                                        preview: {
                                            if let item = slot.item {
                                                previewItem = item
                                            }
                                        },
                                        isReasonExpanded: expandedReasonSlotIDs.contains(slot.id),
                                        toggleReasonExpansion: {
                                            toggleReasonExpansion(for: slot.id)
                                        }
                                    )
                                    .frame(width: columnWidth, alignment: .top)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 6)
                            .padding(.bottom, bottomInset + 74)
                        }

                        floatingActionBar(bottomInset: bottomInset)
                    }
                }
            }
            .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
            .navigationTitle(isControlPanelCollapsed ? "" : navigationTitle)
            .photoSorterPreviewNavigationStyle()
#if os(iOS)
            .toolbar(isControlPanelCollapsed ? .hidden : .visible, for: .navigationBar)
#endif
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            recordMediaAskSheetDiagnostic("media_ask_sheet_appear", fields: [
                "paths": "\(reviewPaths.count)",
                "preloaded": "\(prompt.items.count)"
            ])
        }
        .task(id: prompt.id) {
            await loadProgressiveItemsIfNeeded()
        }
        .sheet(item: $previewItem) { item in
            PhotoSorterMediaViewAuthorizationPreview(item: item)
        }
    }

    private var reviewPaths: [String] {
        if !prompt.pendingPaths.isEmpty {
            return prompt.pendingPaths
        }
        return prompt.items.map(\.path)
    }

    private var reviewSlots: [PhotoSorterMediaViewAuthorizationSlot] {
        reviewPaths.indices.map { index in
            PhotoSorterMediaViewAuthorizationSlot(
                id: index,
                path: reviewPaths[index],
                item: loadedItemsByIndex[index],
                failure: failuresByIndex[index],
                isLoading: prompt.itemLoader != nil
                    && loadedItemsByIndex[index] == nil
                    && failuresByIndex[index] == nil,
                reason: prompt.reasonsByPath[reviewPaths[index]]
            )
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            if !isControlPanelCollapsed {
                controlPanelContent
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            controlPanelHandle
                .padding(.top, isControlPanelCollapsed ? 2 : 0)
                .padding(.bottom, isControlPanelCollapsed ? 2 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .offset(y: isControlPanelCollapsed ? max(controlPanelDragOffset, 0) : min(controlPanelDragOffset, 0))
        .gesture(controlPanelDragGesture)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isControlPanelCollapsed)
    }

    private var controlPanelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(authorizationTitle)
                .photoSorterFont(size: 17, weight: .semibold)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if prompt.purpose == .askUser {
                Text("取消勾选不想包含的媒体，也可以在备注里告诉 Agent 接下来怎么处理。")
                    .photoSorterFont(size: 13, weight: .medium)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.limitSkippedPaths.isEmpty {
                Text(prompt.purpose == .askUser ? "还有 \(prompt.limitSkippedPaths.count) 个媒体超过单次上限，本次不会预览。" : "还有 \(prompt.limitSkippedPaths.count) 张超过单次上限，本次不会发送。")
                    .photoSorterFont(size: 13, weight: .medium)
                    .foregroundStyle(Color.secondary)
            }
            HStack(spacing: 10) {
                PhotoSorterLiquidGlassTextButton("全选") {
                    setLoadedSelection(true)
                }
                PhotoSorterLiquidGlassTextButton("取消全选") {
                    setLoadedSelection(false)
                }
                Spacer(minLength: 0)
                Text("已选 \(selectedItemIDs.count)/已加载 \(loadedItemsByIndex.count)，共 \(reviewPaths.count)")
                    .photoSorterFont(size: 13, weight: .medium)
                    .foregroundStyle(Color.secondary)
            }
            if prompt.purpose == .askUser {
                VStack(alignment: .leading, spacing: 6) {
                    Text("给 Agent 的备注")
                        .photoSorterFont(size: 13, weight: .semibold)
                        .foregroundStyle(Color.secondary)
                    TextEditor(text: $note)
                        .photoSorterFont(size: 14, weight: .regular)
                        .frame(minHeight: 76, maxHeight: 96)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                        )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var authorizationTitle: String {
        if prompt.purpose == .askUser {
            if let message = prompt.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
            return "请选择要继续处理的媒体"
        }
        return "模型请求查看以下图片"
    }

    private var navigationTitle: String {
        prompt.purpose == .askUser ? "媒体确认" : "敏感读取确认"
    }

    private var controlPanelHandle: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isControlPanelCollapsed.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 44, height: 5)
                .frame(width: 96, height: isControlPanelCollapsed ? 20 : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isControlPanelCollapsed ? "展开媒体确认选项" : "收起媒体确认选项")
    }

    private func floatingActionBar(bottomInset: CGFloat) -> some View {
        HStack(spacing: 12) {
            if prompt.purpose == .askUser {
                PhotoSorterLiquidGlassTextButton("取消", controlSize: .large, fontSize: 18) {
                    cancel(
                        reviewedItemsInOrder(),
                        decisionFailures(notReviewedMessage: "not reviewed because user cancelled before preview loaded")
                    )
                }
                .frame(minHeight: 50)
            } else {
                PhotoSorterLiquidGlassTextButton("拒绝全部", role: .destructive, controlSize: .large, fontSize: 18) {
                    denyAll()
                }
                .frame(minHeight: 50)
            }

            Spacer(minLength: 0)

            PhotoSorterLiquidGlassTextButton(
                prompt.purpose == .askUser ? "确认已选 (\(selectedItemIDs.count))" : "允许已选 (\(selectedItemIDs.count))",
                controlSize: .large,
                fontSize: 18
            ) {
                let reviewedItems = reviewedItemsInOrder()
                let reviewedItemIDs = Set(reviewedItems.map(\.id))
                allowSelected(
                    selectedItemIDs.intersection(reviewedItemIDs),
                    note,
                    reviewedItems,
                    decisionFailures(notReviewedMessage: "not reviewed because user confirmed before preview loaded")
                )
            }
            .frame(minHeight: 50)
            .disabled(prompt.purpose != .askUser && selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, max(bottomInset - 2, 8))
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private var controlPanelDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($controlPanelDragOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let verticalTranslation = value.translation.height
                let verticalVelocity = value.predictedEndTranslation.height - value.translation.height
                if verticalTranslation < -34 || verticalVelocity < -58 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isControlPanelCollapsed = true
                    }
                } else if verticalTranslation > 34 || verticalVelocity > 58 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isControlPanelCollapsed = false
                    }
                }
            }
    }

    private static func columns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columnCount(for: width))
    }

    private static func columnCount(for width: CGFloat) -> Int {
        let count: Int
        if width < 700 {
            count = 2
        } else if width < 1020 {
            count = 3
        } else {
            count = 4
        }
        return count
    }

    private static func columnWidth(for width: CGFloat) -> CGFloat {
        let count = columnCount(for: width)
        let totalSpacing = CGFloat(max(count - 1, 0)) * 14
        let availableWidth = max(width - 36 - totalSpacing, 120)
        return availableWidth / CGFloat(max(count, 1))
    }

    private func loadProgressiveItemsIfNeeded() async {
        guard let itemLoader = prompt.itemLoader else {
            return
        }
        let paths = reviewPaths
        guard !paths.isEmpty else {
            return
        }
        await MainActor.run {
            loadingIndices = Set(paths.indices)
        }
        let batchSize = 8
        var startIndex = 0
        while startIndex < paths.count, !Task.isCancelled {
            let endIndex = min(startIndex + batchSize, paths.count)
            await withTaskGroup(of: PhotoSorterMediaViewLoadResult.self) { group in
                for index in startIndex..<endIndex {
                    let path = paths[index]
                    group.addTask {
                        await itemLoader.load(index: index, path: path)
                    }
                }
                for await result in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    await MainActor.run {
                        applyLoadResult(result)
                    }
                }
            }
            startIndex = endIndex
        }
    }

    private func applyLoadResult(_ result: PhotoSorterMediaViewLoadResult) {
        loadingIndices.remove(result.index)
        if let previousItem = loadedItemsByIndex[result.index] {
            selectedItemIDs.remove(previousItem.id)
        }
        if let item = result.item {
            failuresByIndex[result.index] = nil
            loadedItemsByIndex[result.index] = item
            if manualSelectionByIndex[result.index] ?? true {
                selectedItemIDs.insert(item.id)
            }
            return
        }
        loadedItemsByIndex[result.index] = nil
        let fallbackPath = reviewPaths.indices.contains(result.index) ? reviewPaths[result.index] : ""
        failuresByIndex[result.index] = result.failure ?? PhotoSorterMediaViewFailure(
            path: fallbackPath,
            message: "preview unavailable"
        )
    }

    private func toggleSelection(for index: Int) {
        guard let item = loadedItemsByIndex[index] else {
            return
        }
        let newSelection = !selectedItemIDs.contains(item.id)
        manualSelectionByIndex[index] = newSelection
        if newSelection {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
    }

    private func setLoadedSelection(_ isSelected: Bool) {
        for (index, item) in loadedItemsByIndex {
            manualSelectionByIndex[index] = isSelected
            if isSelected {
                selectedItemIDs.insert(item.id)
            } else {
                selectedItemIDs.remove(item.id)
            }
        }
    }

    private func toggleReasonExpansion(for index: Int) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            if expandedReasonSlotIDs.contains(index) {
                expandedReasonSlotIDs.remove(index)
            } else {
                expandedReasonSlotIDs.insert(index)
            }
        }
    }

    private func reviewedItemsInOrder() -> [PhotoSorterMediaViewItem] {
        reviewPaths.indices.compactMap { loadedItemsByIndex[$0] }
    }

    private func decisionFailures(notReviewedMessage: String) -> [PhotoSorterMediaViewFailure] {
        var failures: [PhotoSorterMediaViewFailure] = []
        for index in reviewPaths.indices {
            if let failure = failuresByIndex[index] {
                failures.append(failure)
            } else if loadedItemsByIndex[index] == nil {
                failures.append(PhotoSorterMediaViewFailure(
                    path: reviewPaths[index],
                    message: notReviewedMessage
                ))
            }
        }
        return failures
    }

    private func recordMediaAskSheetDiagnostic(
        _ event: String,
        fields: [String: String] = [:]
    ) {
        guard prompt.purpose == .askUser else {
            return
        }
        Task {
            await PhotoSorterDiagnosticsLog.shared.record(event, fields: fields)
        }
    }
}

private struct PhotoSorterMediaViewAuthorizationSlot: Identifiable, Equatable {
    var id: Int
    var path: String
    var item: PhotoSorterMediaViewItem?
    var failure: PhotoSorterMediaViewFailure?
    var isLoading: Bool
    var reason: PhotoSorterMediaAskReason?
}

private struct PhotoSorterMediaViewAuthorizationCell: View {
    let slot: PhotoSorterMediaViewAuthorizationSlot
    let thumbnailWidth: CGFloat
    let isSelected: Bool
    var toggleSelection: () -> Void
    var preview: () -> Void
    let isReasonExpanded: Bool
    var toggleReasonExpansion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                thumbnail

                if slot.item != nil {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .photoSorterFont(size: 28, weight: .bold)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                            .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                            .frame(width: 46, height: 46)
                            .frame(width: 64, height: 64, alignment: .topTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "取消选择" : "选择")
                }
            }
            .frame(width: thumbnailWidth, height: thumbnailHeight, alignment: .top)

            footer
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: thumbnailWidth + 16, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let item = slot.item {
            Button(action: preview) {
                PhotoSorterMediaPreviewThumbnail(preview: item.preview)
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        } else if let failure = slot.failure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .photoSorterFont(size: 22, weight: .semibold)
                Text(failure.message)
                    .photoSorterFont(size: 12, weight: .medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .foregroundStyle(Color.secondary)
            .padding(10)
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text(slot.isLoading ? "加载预览中" : "等待预览")
                    .photoSorterFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let reason = slot.reason, reason.hasDisplayContent {
            Button(action: toggleReasonExpansion) {
                VStack(alignment: .leading, spacing: 4) {
                    if let titleLine = reason.titleLine {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(titleLine)
                                .photoSorterFont(size: 15, weight: .semibold)
                                .foregroundStyle(Color.primary)
                                .lineLimit(isReasonExpanded ? nil : 1)
                                .fixedSize(horizontal: false, vertical: isReasonExpanded)
                            Spacer(minLength: 0)
                            Image(systemName: isReasonExpanded ? "chevron.up" : "chevron.down")
                                .photoSorterFont(size: 11, weight: .bold)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    if !reason.basis.isEmpty {
                        reasonLine("依据：\(reason.basis.joined(separator: "、"))")
                    }
                    if !reason.matchedTerms.isEmpty {
                        reasonLine("命中：\(reason.matchedTerms.joined(separator: "、"))")
                    }
                    if let risk = reason.risk {
                        reasonLine("提醒：\(risk)")
                    }
                    if isReasonExpanded, let detail = reason.detail {
                        reasonLine("说明：\(detail)")
                    } else if reason.risk == nil, let detail = reason.detail {
                        reasonLine("说明：\(detail)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(isReasonExpanded ? "收起候选理由" : "展开候选理由")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(fileName)
                    .photoSorterFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(slot.path)
                    .photoSorterFont(size: 11, weight: .medium)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func reasonLine(_ text: String) -> some View {
        Text(text)
            .photoSorterFont(size: 13, weight: .medium)
            .foregroundStyle(Color.secondary)
            .lineLimit(isReasonExpanded ? nil : 1)
            .fixedSize(horizontal: false, vertical: isReasonExpanded)
    }

    private var fileName: String {
        if let item = slot.item {
            return item.fileName
        }
        return slot.path.split(separator: "/").last.map(String.init) ?? slot.path
    }

    private var thumbnailHeight: CGFloat {
        thumbnailWidth / max(thumbnailAspectRatio, 0.01)
    }

    private var thumbnailAspectRatio: CGFloat {
        guard let item = slot.item else {
            return 1
        }
        let width = CGFloat(max(item.pixelWidth, 1))
        let height = CGFloat(max(item.pixelHeight, 1))
        return width / height
    }
}

private struct PhotoSorterMediaViewAuthorizationPreview: View {
    @Environment(\.dismiss) private var dismiss
    let item: PhotoSorterMediaViewItem

    var body: some View {
        NavigationStack {
            PhotoSorterMediaPreviewContent(media: item.preview, resetID: item.id.uuidString)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
                .background(MSPDesignTokens.pageBackground.ignoresSafeArea())
                .navigationTitle(item.fileName)
                .photoSorterPreviewNavigationStyle()
                .toolbar {
#if os(iOS)
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotoSorterToolbarTextButton("完成") {
                            dismiss()
                        }
                    }
#else
                    ToolbarItem(placement: .automatic) {
                        PhotoSorterToolbarTextButton("完成") {
                            dismiss()
                        }
                    }
#endif
                }
        }
    }
}

private struct PhotoSorterMediaPreviewThumbnail: View {
    let preview: PhotoSorterMediaPreview

    var body: some View {
        ZStack {
            if let data = preview.thumbnailData {
                PhotoSorterMediaDataImage(data: data, fills: false)
            } else {
                ContentUnavailableView("无法预览", systemImage: placeholderSystemImage)
            }

            if preview.kind != .image {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label(kindText, systemImage: badgeSystemImage)
                            .labelStyle(.iconOnly)
                            .photoSorterFont(size: 16, weight: .semibold)
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.48), in: Circle())
                            .padding(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderSystemImage: String {
        switch preview.kind {
        case .image:
            return "photo"
        case .video:
            return "play.rectangle"
        case .livePhoto:
            return "livephoto"
        }
    }

    private var badgeSystemImage: String {
        switch preview.kind {
        case .image:
            return "photo"
        case .video:
            return "play.fill"
        case .livePhoto:
            return "livephoto"
        }
    }

    private var kindText: String {
        switch preview.kind {
        case .image:
            return "图片"
        case .video:
            return "视频"
        case .livePhoto:
            return "实况照片"
        }
    }
}

private struct PhotoSorterMediaPreviewContent: View {
    let media: PhotoSorterMediaPreview
    let resetID: String

    var body: some View {
        switch media.kind {
        case .image:
            if let data = media.thumbnailData {
                PhotoSorterZoomableMediaDataImage(data: data, resetID: resetID)
            } else {
                unavailable("这个图片暂时没有可用预览。", systemImage: "photo")
            }
        case .video:
            PhotoSorterNativeVideoPreview(media: media)
        case .livePhoto:
            PhotoSorterNativeLivePhotoPreview(media: media)
        }
    }

    private func unavailable(_ text: String, systemImage: String) -> some View {
        ContentUnavailableView("无法预览", systemImage: systemImage, description: Text(text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PhotoSorterNativeVideoPreview: View {
    let media: PhotoSorterMediaPreview

    var body: some View {
#if canImport(AVKit)
        PhotoSorterAVKitVideoPreview(media: media)
#else
        ContentUnavailableView("无法预览", systemImage: "play.rectangle", description: Text("这个平台暂时不能播放视频。"))
#endif
    }
}

#if canImport(AVKit)
private struct PhotoSorterAVKitVideoPreview: View {
    let media: PhotoSorterMediaPreview
    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let message {
                ContentUnavailableView("无法播放视频", systemImage: "play.slash", description: Text(message))
            } else {
                ProgressView("正在准备视频…")
            }
        }
        .task(id: media.path) {
            await loadPlayer()
        }
        .onDisappear {
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
            player?.pause()
            player = nil
        }
    }

    @MainActor
    private func loadPlayer() async {
        player?.pause()
        player = nil
        message = nil
        if let fileURL = media.fileURL {
            player = AVPlayer(url: fileURL)
            return
        }
        guard let localIdentifier = media.photoLibraryLocalIdentifier,
              let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier],
                options: nil
              ).firstObject
        else {
            message = "找不到这个视频。"
            return
        }

        let result = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            let id = PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { playerItem, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(returning: Result<AVPlayerItem, Error>.failure(error))
                } else if let playerItem {
                    continuation.resume(returning: .success(playerItem))
                } else {
                    continuation.resume(returning: .failure(PhotoSorterMediaImageError.unavailable("视频暂时不可用。")))
                }
            }
            requestID = id
        }

        requestID = nil
        switch result {
        case .success(let playerItem):
            player = AVPlayer(playerItem: playerItem)
        case .failure(let error):
            message = error.localizedDescription
        }
    }
}
#endif

private struct PhotoSorterNativeLivePhotoPreview: View {
    let media: PhotoSorterMediaPreview

    var body: some View {
#if os(iOS) && canImport(PhotosUI)
        PhotoSorterLivePhotoPreview(media: media)
#else
        if let data = media.thumbnailData {
            PhotoSorterZoomableMediaDataImage(data: data, resetID: media.path)
        } else {
            ContentUnavailableView("无法预览", systemImage: "livephoto", description: Text("这个平台暂时不能播放实况照片。"))
        }
#endif
    }
}

#if os(iOS) && canImport(PhotosUI)
private struct PhotoSorterLivePhotoPreview: View {
    let media: PhotoSorterMediaPreview
    @State private var livePhoto: PHLivePhoto?
    @State private var message: String?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            if let livePhoto {
                PhotoSorterLivePhotoView(livePhoto: livePhoto)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let message {
                ContentUnavailableView("无法播放实况照片", systemImage: "livephoto.slash", description: Text(message))
            } else if let data = media.thumbnailData {
                ZStack {
                    PhotoSorterMediaDataImage(data: data, fills: false)
                    ProgressView()
                        .controlSize(.large)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
            } else {
                ProgressView("正在准备实况照片…")
            }
        }
        .task(id: media.path) {
            await loadLivePhoto()
        }
        .onDisappear {
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    @MainActor
    private func loadLivePhoto() async {
        livePhoto = nil
        message = nil
        guard let localIdentifier = media.photoLibraryLocalIdentifier,
              let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier],
                options: nil
              ).firstObject
        else {
            message = "找不到这个实况照片。"
            return
        }

        let targetSize = CGSize(
            width: max(CGFloat(media.pixelWidth), 1),
            height: max(CGFloat(media.pixelHeight), 1)
        )
        let result = await withCheckedContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let id = PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded else {
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(returning: Result<PHLivePhoto, Error>.failure(error))
                } else if let livePhoto {
                    continuation.resume(returning: .success(livePhoto))
                } else {
                    continuation.resume(returning: .failure(PhotoSorterMediaImageError.unavailable("实况照片暂时不可用。")))
                }
            }
            requestID = id
        }

        requestID = nil
        switch result {
        case .success(let livePhoto):
            self.livePhoto = livePhoto
        case .failure(let error):
            message = error.localizedDescription
        }
    }
}

private struct PhotoSorterLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
    }
}
#endif

private struct PhotoSorterMediaDataImage: View {
    let data: Data
    var fills: Bool

    var body: some View {
#if canImport(UIKit)
        if let image = UIImage(data: data) {
            rendered(Image(uiImage: image))
        } else {
            unavailable
        }
#elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            rendered(Image(nsImage: image))
        } else {
            unavailable
        }
#else
        unavailable
#endif
    }

    @ViewBuilder
    private func rendered(_ image: Image) -> some View {
        if fills {
            image
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            image
                .resizable()
                .scaledToFit()
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("无法预览", systemImage: "photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PhotoSorterZoomableMediaDataImage: View {
    let data: Data
    let resetID: String

    var body: some View {
#if canImport(UIKit)
        if let image = UIImage(data: data) {
            PhotoSorterZoomableImageView(
                image: image,
                resetID: "\(resetID)#\(data.count)"
            )
        } else {
            unavailable
        }
#else
        PhotoSorterMediaDataImage(data: data, fills: false)
#endif
    }

    private var unavailable: some View {
        ContentUnavailableView("无法预览", systemImage: "photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if canImport(UIKit)
private struct PhotoSorterZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let resetID: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.scrollsToTop = false

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.updatePanGestureAvailability(in: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image

        guard context.coordinator.resetID != resetID else {
            return
        }

        context.coordinator.resetID = resetID
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.contentOffset = .zero
        context.coordinator.centerContent(in: scrollView)
        context.coordinator.updatePanGestureAvailability(in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var resetID: String?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            updatePanGestureAvailability(in: scrollView)
        }

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else {
                return
            }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let tapPoint = recognizer.location(in: imageView)
            let targetScale = min(max(2.5, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let zoomRect = CGRect(
                x: tapPoint.x - width / 2,
                y: tapPoint.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }

        func updatePanGestureAvailability(in scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        }

        func centerContent(in scrollView: UIScrollView) {
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func photoSorterPreviewCover(
        item: Binding<WorkspaceMediaPreview?>,
        restoreFromTrash: @escaping (WorkspaceMediaPreview) -> Void,
        showPrevious: @escaping () -> Void,
        showNext: @escaping () -> Void,
        selectItem: @escaping (String) -> Void,
        preparePage: @escaping (String) -> Void
    ) -> some View {
#if os(iOS)
        self.fullScreenCover(item: item) { preview in
            WorkspaceMediaPreviewSheet(
                preview: preview,
                restoreFromTrash: restoreFromTrash,
                showPrevious: showPrevious,
                showNext: showNext,
                selectItem: selectItem,
                preparePage: preparePage
            )
        }
#else
        self.sheet(item: item) { preview in
            WorkspaceMediaPreviewSheet(
                preview: preview,
                restoreFromTrash: restoreFromTrash,
                showPrevious: showPrevious,
                showNext: showNext,
                selectItem: selectItem,
                preparePage: preparePage
            )
        }
#endif
    }
}

private extension View {
    @ViewBuilder
    func photoSorterPreviewNavigationStyle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func photoSorterPreviewPagerStyle() -> some View {
#if os(iOS)
        self.tabViewStyle(.page(indexDisplayMode: .never))
#else
        self
#endif
    }
}

import Foundation
import CryptoKit
import MSPAgentBridge
import MSPAgentChatStore
import MSPCore
import Photos
import SwiftUI

final class WorkspaceMediaPreview: ObservableObject, Identifiable {
    let id = UUID()
    @Published var path: String
    @Published var canRestoreFromTrash: Bool
    @Published var title: String
    @Published var imageData: Data?
    @Published var media: PhotoSorterMediaPreview?
    @Published var message: String?
    @Published var isLoading: Bool
    @Published var isRestoringFromTrash: Bool
    let galleryDirectoryPath: String?
    @Published var galleryItems: [WorkspaceFileNode]
    @Published var galleryLoadedNodeCount: Int
    @Published var galleryHasMoreNodes: Bool
    @Published var isLoadingMoreGalleryItems: Bool
    @Published var galleryImageDataByPath: [String: Data]
    @Published var galleryMediaByPath: [String: PhotoSorterMediaPreview]
    @Published var galleryMessageByPath: [String: String]
    @Published var galleryLoadingPaths: Set<String>
    var workspaceCacheVersionToken: String

    init(
        title: String,
        path: String,
        canRestoreFromTrash: Bool = false,
        imageData: Data? = nil,
        media: PhotoSorterMediaPreview? = nil,
        message: String? = nil,
        isLoading: Bool = false,
        isRestoringFromTrash: Bool = false,
        galleryDirectoryPath: String? = nil,
        galleryItems: [WorkspaceFileNode] = [],
        galleryLoadedNodeCount: Int = 0,
        galleryHasMoreNodes: Bool = false,
        isLoadingMoreGalleryItems: Bool = false,
        galleryImageDataByPath: [String: Data] = [:],
        galleryMediaByPath: [String: PhotoSorterMediaPreview] = [:],
        galleryMessageByPath: [String: String] = [:],
        galleryLoadingPaths: Set<String> = [],
        workspaceCacheVersionToken: String = ""
    ) {
        self.title = title
        self.path = path
        self.canRestoreFromTrash = canRestoreFromTrash
        self.imageData = imageData
        self.media = media
        self.message = message
        self.isLoading = isLoading
        self.isRestoringFromTrash = isRestoringFromTrash
        self.galleryDirectoryPath = galleryDirectoryPath
        self.galleryItems = galleryItems
        self.galleryLoadedNodeCount = galleryLoadedNodeCount
        self.galleryHasMoreNodes = galleryHasMoreNodes
        self.isLoadingMoreGalleryItems = isLoadingMoreGalleryItems
        self.galleryImageDataByPath = galleryImageDataByPath
        self.galleryMediaByPath = galleryMediaByPath
        self.galleryMessageByPath = galleryMessageByPath
        self.galleryLoadingPaths = galleryLoadingPaths
        self.workspaceCacheVersionToken = workspaceCacheVersionToken
    }

    var currentGalleryIndex: Int? {
        galleryItems.firstIndex { $0.path == path }
    }

    var canNavigateToPreviousGalleryItem: Bool {
        guard let currentGalleryIndex else {
            return false
        }
        return currentGalleryIndex > 0
    }

    var canNavigateToNextGalleryItem: Bool {
        guard let currentGalleryIndex else {
            return false
        }
        return currentGalleryIndex + 1 < galleryItems.count || galleryHasMoreNodes
    }

    func imageData(for path: String) -> Data? {
        if let imageData = galleryImageDataByPath[path] {
            return imageData
        }
        return path == self.path ? self.imageData : nil
    }

    func media(for path: String) -> PhotoSorterMediaPreview? {
        if let media = galleryMediaByPath[path] {
            return media
        }
        return path == self.path ? self.media : nil
    }

    func message(for path: String) -> String? {
        if let message = galleryMessageByPath[path] {
            return message
        }
        return path == self.path ? self.message : nil
    }

    func isLoading(_ path: String) -> Bool {
        galleryLoadingPaths.contains(path)
    }

    @discardableResult
    func invalidateCachedContentIfWorkspaceChanged(to cacheVersionToken: String) -> Bool {
        guard workspaceCacheVersionToken != cacheVersionToken else {
            return false
        }
        workspaceCacheVersionToken = cacheVersionToken
        imageData = nil
        media = nil
        message = nil
        isLoading = false
        isLoadingMoreGalleryItems = false
        galleryItems = []
        galleryLoadedNodeCount = 0
        galleryHasMoreNodes = false
        galleryImageDataByPath.removeAll(keepingCapacity: false)
        galleryMediaByPath.removeAll(keepingCapacity: false)
        galleryMessageByPath.removeAll(keepingCapacity: false)
        galleryLoadingPaths.removeAll(keepingCapacity: false)
        return true
    }
}

extension MSPPlaygroundViewModel: PhotoSorterMediaViewAuthorizing {
    func authorizeMediaView(
        _ request: PhotoSorterMediaViewAuthorizationRequest
    ) async -> PhotoSorterMediaViewAuthorizationDecision {
        await withCheckedContinuation { continuation in
            if let existingContinuation = mediaViewAuthorizationContinuation {
                existingContinuation.resume(returning: .denyAll)
            }
            mediaViewAuthorizationContinuation = continuation
            mediaViewAuthorizationPrompt = PhotoSorterMediaViewAuthorizationPrompt(request: request)
            recordDiagnostic("media_view_authorization_prompt_set", fields: [
                "purpose": "\(request.purpose)",
                "items": "\(request.items.count)",
                "pending_paths": "\(request.pendingPaths.count)",
                "limit_skipped": "\(request.limitSkippedPaths.count)"
            ])
        }
    }
}

struct PhotoSorterMediaViewAuthorizationPrompt: Identifiable, Equatable {
    var id: UUID
    var purpose: PhotoSorterMediaViewAuthorizationPurpose
    var message: String?
    var items: [PhotoSorterMediaViewItem]
    var pendingPaths: [String]
    var reasonsByPath: [String: PhotoSorterMediaAskReason]
    var itemLoader: PhotoSorterMediaViewItemLoader?
    var limitSkippedPaths: [String]

    init(request: PhotoSorterMediaViewAuthorizationRequest) {
        self.id = request.id
        self.purpose = request.purpose
        self.message = request.message
        self.items = request.items
        self.pendingPaths = request.pendingPaths
        self.reasonsByPath = request.reasonsByPath
        self.itemLoader = request.itemLoader
        self.limitSkippedPaths = request.limitSkippedPaths
    }
}

extension PhotoSorterMediaViewAuthorizationPrompt {
    static func == (
        lhs: PhotoSorterMediaViewAuthorizationPrompt,
        rhs: PhotoSorterMediaViewAuthorizationPrompt
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.purpose == rhs.purpose
            && lhs.message == rhs.message
            && lhs.items == rhs.items
            && lhs.pendingPaths == rhs.pendingPaths
            && lhs.reasonsByPath == rhs.reasonsByPath
            && lhs.limitSkippedPaths == rhs.limitSkippedPaths
    }
}

struct PhotoLibraryWorkspaceSyncConfirmation: Identifiable, Equatable {
    var id = UUID()
    var summary: PhotoLibraryWorkspaceChangeSummary
    var changeSet: PhotoLibraryWorkspaceSyncChangeSet
}

private struct PendingToolOutputDelta {
    var callID: String
    var name: MSPAgentToolName
    var stream: MSPExecCommandOutputStreamName
    var text: String
}

private struct OpenedChatPackage: Sendable {
    var session: MSPAgentChatSession
    var virtualPath: String
    var packageURL: URL
    var modelHistory: [MSPAgentJSONValue]
    var transcript: [MSPAgentTimelineItem]
    var transcriptTotalItemCount: Int
    var transcriptStartIndex: Int
    var isUIProjectionOnly: Bool
}

private enum ActiveChatCreationResult: Sendable {
    case success(MSPAgentChatSession)
    case failure(String)
}

@MainActor
final class MSPPlaygroundViewModel: ObservableObject {
    private static let contextCompactionRunningText = "正在自动压缩上下文"
    private static let contextCompactionCompletedText = "上下文已自动压缩"
    private static let activeTurnModelHistoryStreamingSnapshotDelayNanoseconds: UInt64 = 300_000_000

    let transcriptRenderController = ExampleChatTranscriptRenderController()

    var transcript: [MSPAgentTimelineItem] = [] {
        didSet {
            rebuildTranscriptRenderStateUnlessSuppressed()
        }
    }
    @Published var composerText: String = ""
    @Published var composerTextSelections: [PhotoSorterTextSelectionSnapshot] = []
    @Published var fileTreeState: WorkspaceFileTreeState = .loading
    @Published var workspaceTrashTreeState: WorkspaceFileTreeState = .loaded([])
    @Published var workspaceTrashRevision = 0
    @Published var workspaceTrashErrorMessage: String?
    @Published var isEmptyingWorkspaceTrash = false
    @Published var isRestoringWorkspaceTrash = false
    @Published var isRunningAgent = false {
        didSet {
            guard oldValue != isRunningAgent else { return }
            rebuildTranscriptRenderStateUnlessSuppressed()
        }
    }
    @Published var isOpeningChatPackage = false
    @Published var isActiveChatReadyForInput = true
    @Published var modelConfiguration: MSPModelConfiguration
    @Published var modelConfigurationSaveError: String?
    @Published var codexOAuthConfiguration: MSPCodexOAuthConfiguration
    @Published var agentAccessMode: PhotoSorterAgentAccessMode
    @Published var sensitiveReadPolicy: PhotoSorterSensitiveReadPolicy
    @Published var codexOAuthQuota: MSPCodexOAuthQuotaResult?
    @Published var contextUsage: MSPAgentContextUsageRecord?
    @Published var activePlanProgressUpdate: ExampleChatCodexPlanUpdate?
    @Published var isStartingCodexOAuthLogin = false
    @Published var isRefreshingCodexOAuthQuota = false
    @Published var lastRequestBody: MSPAgentRequestBody?
    @Published var workspaceMediaPreview: WorkspaceMediaPreview?
    @Published var workspaceQuickLookURL: URL?
    @Published var mediaViewAuthorizationPrompt: PhotoSorterMediaViewAuthorizationPrompt?
    @Published var photoLibraryIndexStatus: PhotoLibraryIndexStatus = .idle
    @Published var workspaceTreeRevision = 0
    @Published var photoLibraryOCRCacheStatus: PhotoSorterMediaOCRCacheStatus = .idle
    @Published var photoLibraryVLMSummaryCacheStatus: PhotoSorterMediaVLMStatus = .unavailable
    @Published var photoLibraryPlaceCacheStatus: PhotoSorterMediaPlaceCacheStatus = .idle
    @Published var photoLibraryWorkspaceChangeSummary: PhotoLibraryWorkspaceChangeSummary = .idle
    @Published var photoLibraryWorkspaceSyncConfirmation: PhotoLibraryWorkspaceSyncConfirmation?
    @Published var isSyncingPhotoLibraryWorkspaceChanges = false
    @Published var photoLibraryWorkspaceSyncError: String?
    @Published var expandsTranscriptToolDetailsForTesting = MSPPlaygroundViewModel.transcriptToolDetailExpansionEnabled() {
        didSet {
            guard oldValue != expandsTranscriptToolDetailsForTesting else { return }
            rebuildTranscriptRenderStateUnlessSuppressed()
        }
    }
    @Published var transcriptExpansionState = ExampleChatTranscriptExpansionState.empty {
        didSet {
            guard oldValue != transcriptExpansionState else { return }
            rebuildTranscriptRenderStateUnlessSuppressed()
        }
    }

    var capturesTranscriptVisibleTextProbe: Bool {
        Self.transcriptVisibleTextProbeEnabled()
    }

    private let photoLibraryMount = PhotoLibraryMount()
    private var runtime: MSPPlaygroundShellRuntime?
    private var agentRuntime: MSPPlaygroundAgentRuntime?
    private let agentChatStore = MSPAgentChatStore()
    private var workspaceURL: URL?
    private var activeChatSession: MSPAgentChatSession?
    private var activeChatVirtualPath: String?
    private var activeChatPersistenceGeneration = UUID()
    private var activeChatCreationTask: Task<ActiveChatCreationResult, Never>?
    private var activeChatWriteTask: Task<Void, Never>?
    private var chatOpenTask: Task<Void, Never>?
    private var chatFullOpenTask: Task<Void, Never>?
    private var chatOpenRequestID: UUID?
    private var chatTranscriptSnapshotTask: Task<Void, Never>?
    private var activeChatModelHistorySnapshotTask: Task<Void, Never>?
    private var activeChatFullTranscriptItems: [MSPAgentTimelineItem]?
    private var activeChatDisplayedTranscriptStartIndex = 0
    private var activeChatDisplayedTranscriptBaselineCount = 0
    private var hasStarted = false
    private var streamingAssistantProgressItemID: UUID?
    private var streamingFinalItemID: UUID?
    private var suppressesTranscriptRenderRebuild = false
    private var transcriptRenderFontScale: Double = 1
    private var transcriptRenderInterfaceTheme: PhotoSorterInterfaceTheme = .light
    private var pendingFinalAnswerProvenanceFields: [String: String]?
    private var activeContextCompactionProgressItemIDByCompactionID: [String: UUID] = [:]
    private var activeTurnModelHistoryPrefixCountByStartedAtMilliseconds: [Int: Int] = [:]
    private var activeTurnModelHistoryPrefixItemsByStartedAtMilliseconds: [Int: [MSPAgentJSONValue]] = [:]
    private var activeTurnModelHistorySnapshotItemCountByStartedAtMilliseconds: [Int: Int] = [:]
    private var activeTurnCurrentItemsSnapshotItemCountByStartedAtMilliseconds: [Int: Int] = [:]
    private var activeTurnLatestCurrentItemsByStartedAtMilliseconds: [Int: [MSPAgentJSONValue]] = [:]
    private var activeTurnLatestModelHistoryByStartedAtMilliseconds: [Int: [MSPAgentJSONValue]] = [:]
    private var activeTurnUserModelItemsByStartedAtMilliseconds: [Int: [MSPAgentJSONValue]] = [:]
    private var modelInputPersistedTurnStartedAtMilliseconds: Set<Int> = []
    private var pendingToolPreparationItemIDs: [UUID] = []
    private var activeToolStartedAtMillisecondsByCallID: [String: Int] = [:]
    private var activeToolStdoutPreviewsByCallID: [String: MSPTerminalOutputPreview] = [:]
    private var activeToolStderrPreviewsByCallID: [String: MSPTerminalOutputPreview] = [:]
    private var activeExecCommandCallIDBySessionID: [Int: String] = [:]
    private var activeExecSessionIDByCallID: [String: Int] = [:]
    private var activeWriteStdinParentCallIDByCallID: [String: String] = [:]
    private var currentTurnStartedAtMilliseconds: Int?
    private var currentAgentTurnID: UUID?
    private var currentAgentTurnTask: Task<Void, Never>?
    private var isSubmittingAgentTurn = false
    private var stoppedTurnStartedAtMilliseconds: Set<Int> = []
    private var failedTurnStartedAtMilliseconds: Set<Int> = []
    private var pendingToolOutputDeltas: [String: PendingToolOutputDelta] = [:]
    private var toolOutputStreamingFlushTask: Task<Void, Never>?
    private var codexOAuthQuotaRefreshToken: UUID?
    private var photoLibraryIndexStatusTask: Task<Void, Never>?
    private var photoLibraryOCRCacheStatusTask: Task<Void, Never>?
    private var photoLibraryVLMSummaryCacheStatusTask: Task<Void, Never>?
    private var photoLibraryPlaceCacheStatusTask: Task<Void, Never>?
    private var photoLibraryWorkspaceChangeStatusTask: Task<Void, Never>?
    private var mediaViewAuthorizationContinuation: CheckedContinuation<PhotoSorterMediaViewAuthorizationDecision, Never>?
    private let agentAccessModeState: PhotoSorterAgentAccessModeState
    private let sensitiveReadPolicyState: PhotoSorterSensitiveReadPolicyState
    private let codexOAuthLoginService = MSPCodexOAuthWebLoginService()
    private let codexOAuthQuotaService = MSPCodexOAuthQuotaService()
    private let e2eEventLog = MSPPlaygroundE2EEventLog.configured()
    private let diagnosticsLog = PhotoSorterDiagnosticsLog.shared
    private var chatStreamTraceObserver: NSObjectProtocol?
    private let loadModelConfiguration: () -> MSPModelConfiguration
    private let saveModelConfigurationHandler: (MSPModelConfiguration) throws -> Void
    private let saveAgentAccessModeHandler: (PhotoSorterAgentAccessMode) -> Void
    private let saveSensitiveReadPolicyHandler: (PhotoSorterSensitiveReadPolicy) -> Void
    private let savePlaceCacheTaskModeHandler: (PhotoSorterPlaceCacheTaskMode) -> Void
    private var placeCacheTaskMode: PhotoSorterPlaceCacheTaskMode
    private static let workspaceTreeEntriesPerDirectoryLimit = 200
    private static let workspaceTreePageSize = 120
    private static let toolOutputStreamingFlushIntervalNanoseconds: UInt64 = 33_000_000

    init(
        loadModelConfiguration: @escaping () -> MSPModelConfiguration = {
            MSPModelConfigurationStore.load()
        },
        saveModelConfiguration: @escaping (MSPModelConfiguration) throws -> Void = {
            try MSPModelConfigurationStore.save($0)
        },
        loadCodexOAuthConfiguration: @escaping () -> MSPCodexOAuthConfiguration = {
            MSPCodexOAuthConfigurationStore.load()
        },
        loadAgentAccessMode: @escaping () -> PhotoSorterAgentAccessMode = {
            PhotoSorterAgentAccessModeStore.load()
        },
        saveAgentAccessMode: @escaping (PhotoSorterAgentAccessMode) -> Void = {
            PhotoSorterAgentAccessModeStore.save($0)
        },
        loadSensitiveReadPolicy: @escaping () -> PhotoSorterSensitiveReadPolicy = {
            PhotoSorterSensitiveReadPolicyStore.load()
        },
        saveSensitiveReadPolicy: @escaping (PhotoSorterSensitiveReadPolicy) -> Void = {
            PhotoSorterSensitiveReadPolicyStore.save($0)
        },
        loadPlaceCacheTaskMode: @escaping () -> PhotoSorterPlaceCacheTaskMode = {
            PhotoSorterPlaceCacheTaskStore.load()
        },
        savePlaceCacheTaskMode: @escaping (PhotoSorterPlaceCacheTaskMode) -> Void = {
            PhotoSorterPlaceCacheTaskStore.save($0)
        }
    ) {
        let loadedAgentAccessMode = loadAgentAccessMode()
        let loadedSensitiveReadPolicy = loadSensitiveReadPolicy()
        let loadedPlaceCacheTaskMode = loadPlaceCacheTaskMode()
        self.loadModelConfiguration = loadModelConfiguration
        self.saveModelConfigurationHandler = saveModelConfiguration
        self.saveAgentAccessModeHandler = saveAgentAccessMode
        self.saveSensitiveReadPolicyHandler = saveSensitiveReadPolicy
        self.savePlaceCacheTaskModeHandler = savePlaceCacheTaskMode
        self.modelConfiguration = loadModelConfiguration()
        self.codexOAuthConfiguration = loadCodexOAuthConfiguration()
        self.agentAccessMode = loadedAgentAccessMode
        self.sensitiveReadPolicy = loadedSensitiveReadPolicy
        self.placeCacheTaskMode = loadedPlaceCacheTaskMode
        self.agentAccessModeState = PhotoSorterAgentAccessModeState(loadedAgentAccessMode)
        self.sensitiveReadPolicyState = PhotoSorterSensitiveReadPolicyState(loadedSensitiveReadPolicy)
        self.chatStreamTraceObserver = NotificationCenter.default.addObserver(
            forName: .chatTranscriptStreamTraceDiagnostic,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? String else {
                return
            }
            let fields = notification.userInfo?["fields"] as? [String: String] ?? [:]
            Task { @MainActor [weak self] in
                self?.recordDiagnostic("pst_stream_trace_\(event)", fields: fields)
            }
        }
    }

    deinit {
        if let chatStreamTraceObserver {
            NotificationCenter.default.removeObserver(chatStreamTraceObserver)
        }
        currentAgentTurnTask?.cancel()
        activeChatCreationTask?.cancel()
        activeChatWriteTask?.cancel()
        chatOpenTask?.cancel()
        chatFullOpenTask?.cancel()
        activeChatModelHistorySnapshotTask?.cancel()
        toolOutputStreamingFlushTask?.cancel()
        chatTranscriptSnapshotTask?.cancel()
        photoLibraryIndexStatusTask?.cancel()
        photoLibraryOCRCacheStatusTask?.cancel()
        photoLibraryVLMSummaryCacheStatusTask?.cancel()
        photoLibraryPlaceCacheStatusTask?.cancel()
        photoLibraryWorkspaceChangeStatusTask?.cancel()
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        recordDiagnostic("app_start", fields: modelConfigurationDiagnosticFields())

        do {
            let arguments = ProcessInfo.processInfo.arguments
            let environment = ProcessInfo.processInfo.environment
            let workspaceURL = try MSPPlaygroundWorkspaceBootstrap.prepareWorkspace()
            self.workspaceURL = workspaceURL
            let skipPhotoAuthorizationRequest = Self.e2ePhotoLibraryAuthorizationRequestSkipEnabled(
                arguments: arguments,
                environment: environment
            )
            let photoAuthorizationStatus = skipPhotoAuthorizationRequest
                ? photoLibraryMount.authorizationStatus()
                : await photoLibraryMount.requestAuthorizationIfNeeded()
            e2eEventLog?.record("photo_authorization_checked", fields: [
                "status_raw_value": "\(photoAuthorizationStatus.rawValue)",
                "request_skipped": "\(skipPhotoAuthorizationRequest)"
            ])
            recordDiagnostic("photo_authorization_checked", fields: [
                "status_raw_value": "\(photoAuthorizationStatus.rawValue)",
                "request_skipped": "\(skipPhotoAuthorizationRequest)"
            ])
            observePhotoLibraryIndexStatus()
            observePhotoLibraryOCRCacheStatus()
            observePhotoLibraryVLMSummaryCacheStatus()
            observePhotoLibraryPlaceCacheStatus()
            observePhotoLibraryWorkspaceChanges()
            applyPersistedPlaceCachePauseStateIfNeeded()
            startPlaceCachePreheatIfAllowed()
            if Self.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: photoAuthorizationStatus) {
                photoLibraryMount.startPhotoLibraryIndexRefresh(reason: "启动同步照片库索引")
            } else {
                e2eEventLog?.record("photo_library_index_start_skipped", fields: [
                    "authorization_status_raw_value": "\(photoAuthorizationStatus.rawValue)"
                ])
                recordDiagnostic("photo_library_index_start_skipped", fields: [
                    "authorization_status_raw_value": "\(photoAuthorizationStatus.rawValue)"
                ])
            }
            let runtime = try MSPPlaygroundShellRuntime(
                workspaceURL: workspaceURL,
                photoLibraryMount: photoLibraryMount,
                agentAccessModeProvider: agentAccessModeState,
                sensitiveReadPolicyProvider: sensitiveReadPolicyState,
                mediaViewAuthorizer: self,
                diagnosticsLog: diagnosticsLog
            )
            self.runtime = runtime
            self.agentRuntime = MSPPlaygroundAgentRuntime(
                execCommandBridge: runtime.execCommandBridge(),
                photoLibraryMount: photoLibraryMount,
                diagnosticsLog: diagnosticsLog
            )
            e2eEventLog?.record("startup", fields: [
                "workspace_path": workspaceURL.path
            ])
            recordDiagnostic("startup_workspace_ready", fields: [
                "workspace_path": workspaceURL.path
            ])
            if let fixture = Self.launchTranscriptFixtureIfRequested() {
                transcript = fixture.items
                transcriptExpansionState = .empty
                contextUsage = nil
                isRunningAgent = fixture.isGenerating
                e2eEventLog?.record("fixture_loaded", fields: [
                    "variant": fixture.variant.rawValue,
                    "is_generating": "\(fixture.isGenerating)"
                ])
                recordDiagnostic("fixture_loaded", fields: [
                    "variant": fixture.variant.rawValue,
                    "is_generating": "\(fixture.isGenerating)"
                ])
                await refreshWorkspace()
                return
            }

            transcript = []
            transcriptExpansionState = .empty
            contextUsage = nil
            await refreshWorkspace()
            if let vlmPreheatLimit = Self.launchVLMSummaryPreheatDiagnosticLimitIfRequested() {
                recordDiagnostic("vlm_preheat_diagnostic_requested", fields: [
                    "limit": "\(vlmPreheatLimit)"
                ])
                photoLibraryMount.startVLMSummaryCachePreheatBatch(limit: vlmPreheatLimit)
                schedulePhotoLibraryVLMSummaryCacheStatusRefresh()
            }
            if let diagnosticCommand = Self.launchShellDiagnosticCommandIfRequested() {
                await runShellDiagnosticCommand(diagnosticCommand)
                refreshCodexOAuthQuota(isAutomatic: true)
                return
            }
            if let prompts = Self.launchAutoSubmitPromptSequenceIfRequested() {
                e2eEventLog?.record("auto_submit_sequence_loaded", fields: [
                    "prompt_count": "\(prompts.count)",
                    "prompt_hash_algorithm": "sha256-utf8",
                    "prompt_sha256s": prompts.map(Self.sha256Hex).joined(separator: ",")
                ])
                recordDiagnostic("auto_submit_sequence_loaded", fields: [
                    "prompt_count": "\(prompts.count)",
                    "prompt_hash_algorithm": "sha256-utf8",
                    "prompt_sha256s": prompts.map(Self.sha256Hex).joined(separator: ",")
                ])
                for (index, prompt) in prompts.enumerated() {
                    await runAutoSubmittedPrompt(
                        prompt,
                        index: index + 1,
                        count: prompts.count
                    )
                }
            } else if let prompt = Self.launchAutoSubmitPromptIfRequested() {
                await runAutoSubmittedPrompt(prompt, index: 1, count: 1)
            }
            refreshCodexOAuthQuota(isAutomatic: true)
        } catch {
            fileTreeState = .failed(error.localizedDescription)
            transcriptExpansionState = .empty
            transcript = [
                MSPAgentTimelineItem(
                    kind: .error,
                    title: "Startup",
                    body: error.localizedDescription
                )
            ]
            e2eEventLog?.record("startup_error", fields: [
                "message": error.localizedDescription
            ])
            recordDiagnostic("startup_error", fields: [
                "message": error.localizedDescription
            ])
        }
    }

    func updateScenePhase(_ scenePhase: ScenePhase) {
        updateVLMSummaryInferenceForegroundAllowed(
            scenePhase == .active,
            source: "scenePhase:\(scenePhase)"
        )
    }

    func updateApplicationForegroundState(isActive: Bool, source: String) {
        updateVLMSummaryInferenceForegroundAllowed(isActive, source: source)
    }

    private func updateVLMSummaryInferenceForegroundAllowed(_ allowed: Bool, source: String) {
        let changed = photoLibraryMount.setVLMSummaryInferenceForegroundAllowed(allowed)
        if changed {
            recordDiagnostic("app_foreground_state_changed", fields: [
                "source": source,
                "vlm_foreground_inference_allowed": "\(allowed)"
            ])
            schedulePhotoLibraryVLMSummaryCacheStatusRefresh()
        }
    }

    private func runAutoSubmittedPrompt(
        _ prompt: String,
        index: Int,
        count: Int
    ) async {
        ensureActiveChatSession(firstUserMessage: prompt)
        let turnStartedAtMilliseconds = Self.currentMillisecondsSince1970()
        transcript.append(
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: prompt,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        )
        scheduleActiveChatTranscriptSnapshot(reason: "auto_submit_user_message")
        e2eEventLog?.record("auto_submit", fields: [
            "prompt_length": "\(prompt.count)",
            "prompt_index": "\(index)",
            "prompt_count": "\(count)",
            "prompt_hash_algorithm": "sha256-utf8",
            "prompt_sha256": Self.sha256Hex(prompt)
        ])
        recordDiagnostic("auto_submit", fields: [
            "prompt_length": "\(prompt.count)",
            "prompt_index": "\(index)",
            "prompt_count": "\(count)",
            "prompt_hash_algorithm": "sha256-utf8",
            "prompt_sha256": Self.sha256Hex(prompt),
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)"
        ])
        let task = startAgentTurnTask(prompt, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
        await task.value
    }

    func addSelectedTextToComposer(_ selection: PhotoSorterTextSelectionSnapshot) {
        guard let normalizedSelection = selection.normalized else {
            return
        }
        composerTextSelections.append(normalizedSelection)
    }

    func removeComposerTextSelection(_ id: UUID) {
        composerTextSelections.removeAll { $0.id == id }
    }

    func startNewChat() {
        guard !isRunningAgent else {
            recordDiagnostic("agent_chat_new_skipped", fields: [
                "reason": "agent_running"
            ])
            return
        }

        chatOpenTask?.cancel()
        chatFullOpenTask?.cancel()
        chatOpenTask = nil
        chatFullOpenTask = nil
        chatOpenRequestID = nil
        isOpeningChatPackage = false
        activeChatPersistenceGeneration = UUID()
        chatTranscriptSnapshotTask?.cancel()
        chatTranscriptSnapshotTask = nil
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask = nil
        activeChatCreationTask?.cancel()
        activeChatWriteTask?.cancel()
        activeChatCreationTask = nil
        activeChatWriteTask = nil
        activeChatSession = nil
        activeChatVirtualPath = nil
        activeChatFullTranscriptItems = nil
        activeChatDisplayedTranscriptStartIndex = 0
        activeChatDisplayedTranscriptBaselineCount = 0
        isActiveChatReadyForInput = true
        transcript = []
        composerText = ""
        composerTextSelections = []
        transcriptExpansionState = .empty
        contextUsage = nil
        workspaceMediaPreview = nil
        workspaceQuickLookURL = nil
        clearCurrentTurnStreamingState()
        clearCurrentTurnPersistenceState()
        Task {
            await agentRuntime?.replaceTranscriptItems([])
        }
        recordDiagnostic("agent_chat_new_blank", fields: [
            "persisted": "false"
        ])
    }

    func submitMessage() {
        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textSelections = composerTextSelections.compactMap(\.normalized)
        let resolvedMessage = Self.resolvedPrompt(
            text: message,
            textSelections: textSelections
        )
        guard !resolvedMessage.isEmpty,
              !isRunningAgent,
              !isOpeningChatPackage,
              isActiveChatReadyForInput,
              !isSubmittingAgentTurn else {
            return
        }

        composerText = ""
        composerTextSelections = []
        let turnStartedAtMilliseconds = Self.currentMillisecondsSince1970()
        transcript.append(
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: resolvedMessage,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                sourceTextSelections: textSelections
            )
        )
        isSubmittingAgentTurn = true
        Task { [weak self] in
            await self?.continueSubmittedMessageAfterFirstPaint(
                resolvedMessage,
                textSelections: textSelections,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        }
    }

    private func continueSubmittedMessageAfterFirstPaint(
        _ resolvedMessage: String,
        textSelections: [PhotoSorterTextSelectionSnapshot],
        turnStartedAtMilliseconds: Int
    ) async {
        await Task.yield()
        guard !Task.isCancelled else {
            isSubmittingAgentTurn = false
            return
        }
        ensureActiveChatSession(firstUserMessage: resolvedMessage)
        scheduleActiveChatTranscriptSnapshot(
            reason: "user_submit",
            delayNanoseconds: 0
        )
        e2eEventLog?.record("user_submit", fields: [
            "prompt_length": "\(resolvedMessage.count)",
            "text_selection_count": "\(textSelections.count)"
        ])
        recordDiagnostic("user_submit", fields: [
            "prompt_length": "\(resolvedMessage.count)",
            "text_selection_count": "\(textSelections.count)",
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)"
        ])

        startAgentTurnTask(
            resolvedMessage,
            textSelections: textSelections,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds
        )
        isSubmittingAgentTurn = false
    }

    @discardableResult
    private func startAgentTurnTask(
        _ message: String,
        textSelections: [PhotoSorterTextSelectionSnapshot] = [],
        turnStartedAtMilliseconds: Int
    ) -> Task<Void, Never> {
        if let activeTurnStartedAtMilliseconds = currentTurnStartedAtMilliseconds,
           !isTurnStopped(activeTurnStartedAtMilliseconds) {
            currentAgentTurnTask?.cancel()
        }
        let turnID = UUID()
        let turnStartedWriteTask = appendActiveChatTurnStarted(turnID)
        currentAgentTurnID = turnID
        stoppedTurnStartedAtMilliseconds.remove(turnStartedAtMilliseconds)
        failedTurnStartedAtMilliseconds.remove(turnStartedAtMilliseconds)
        activeTurnModelHistoryPrefixCountByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnModelHistoryPrefixItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnModelHistorySnapshotItemCountByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnCurrentItemsSnapshotItemCountByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnLatestCurrentItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnLatestModelHistoryByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        activeTurnUserModelItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] = nil
        modelInputPersistedTurnStartedAtMilliseconds.remove(turnStartedAtMilliseconds)
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask = nil
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runAgentTurn(
                message,
                textSelections: textSelections,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                turnID: turnID,
                turnStartedWriteTask: turnStartedWriteTask
            )
        }
        currentAgentTurnTask = task
        return task
    }

    func stopCurrentAgentTurn() {
        guard isRunningAgent,
              let currentTurnStartedAtMilliseconds else {
            return
        }
        let stoppedAtMilliseconds = Self.currentMillisecondsSince1970()
        stoppedTurnStartedAtMilliseconds.insert(currentTurnStartedAtMilliseconds)
        flushTranscriptStreamingDeltas()
        transcript = MSPAgentTimelineStopSupport.stoppingRunningTurnItems(
            transcript,
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds,
            stoppedAtMilliseconds: stoppedAtMilliseconds
        )
        let abortedWriteTask = currentAgentTurnID.flatMap(markActiveChatTurnAborted)
        Task { [weak self] in
            await abortedWriteTask?.value
            await self?.persistActiveChatTranscriptSnapshot(reason: "agent_turn_stop_requested")
        }
        recordDiagnostic("agent_turn_stop_requested", fields: [
            "turn_started_at_ms": "\(currentTurnStartedAtMilliseconds)",
            "stopped_at_ms": "\(stoppedAtMilliseconds)",
            "transcript_count": "\(transcript.count)"
        ])
        e2eEventLog?.record("agent_turn_stop_requested", fields: [
            "turn_started_at_ms": "\(currentTurnStartedAtMilliseconds)"
        ])
        if let agentRuntime {
            Task { [weak self] in
                do {
                    guard let handle = try await agentRuntime.interruptActiveTurn() else {
                        self?.recordAgentTurnStopNotAccepted(
                            reason: "no_active_turn"
                        )
                        return
                    }
                    let response = try await handle.terminalResponse()
                    self?.recordAgentTurnStopTerminal(
                        handle: handle,
                        response: response
                    )
                    await self?.persistActiveChatModelHistory(reason: "agent_turn_stop_terminal")
                    await self?.persistActiveChatTranscriptSnapshot(reason: "agent_turn_stop_terminal")
                } catch {
                    self?.recordAgentTurnStopNotAccepted(
                        reason: error.localizedDescription
                    )
                }
            }
        }
        isRunningAgent = false
        clearCurrentTurnStreamingState()
        refreshWorkspace()
    }

    private func recordAgentTurnStopTerminal(
        handle: MSPTurnInterruptHandle,
        response: MSPTurnInterruptResponse
    ) {
        var fields: [String: String] = [
            "thread_id": handle.target.threadID,
            "turn_id": handle.target.turnID,
            "target_status": handle.target.status.rawValue,
            "target_started_at_ms": "\(Self.millisecondsSince1970(handle.target.startedAt))",
            "requested_at_ms": "\(Self.millisecondsSince1970(handle.requestedAt))",
            "response_turn_id": response.turnID ?? "",
            "reason": response.reason.rawValue
        ]
        if let event = response.terminalEvent {
            fields["completed_at_ms"] = "\(Self.millisecondsSince1970(event.completedAt))"
            fields["duration_ms"] = event.durationMilliseconds.map(String.init) ?? ""
        }
        recordDiagnostic("agent_turn_stop_terminal", fields: fields)
        e2eEventLog?.record("agent_turn_stop_terminal", fields: fields)
    }

    private func recordAgentTurnStopNotAccepted(reason: String) {
        let fields = [
            "reason": reason
        ]
        recordDiagnostic("agent_turn_stop_not_accepted", fields: fields)
        e2eEventLog?.record("agent_turn_stop_not_accepted", fields: fields)
    }

    func recordTranscriptExpansionStateChange(_ change: ExampleChatTranscriptExpansionStateChange) {
        var nextState = transcriptExpansionState
        nextState.apply(change)
        guard nextState != transcriptExpansionState else {
            return
        }
        transcriptExpansionState = nextState
    }

    func updateTranscriptRenderEnvironment(fontScale: CGFloat, colorScheme: ColorScheme) {
        let nextFontScale = Double(fontScale)
        let nextTheme = PhotoSorterInterfaceTheme(colorScheme: colorScheme)
        guard nextFontScale != transcriptRenderFontScale
                || nextTheme != transcriptRenderInterfaceTheme else {
            return
        }
        transcriptRenderFontScale = nextFontScale
        transcriptRenderInterfaceTheme = nextTheme
        rebuildTranscriptRenderStateUnlessSuppressed()
    }

    private func rebuildTranscriptRenderStateUnlessSuppressed(reason: String = #function) {
        guard !suppressesTranscriptRenderRebuild else {
            recordStreamTrace("vm.rebuild_transcript_render_state_skipped", fields: [
                "reason": reason
            ])
            return
        }
        rebuildTranscriptRenderState(reason: reason)
    }

    private func rebuildTranscriptRenderState(reason: String = #function) {
        recordStreamTrace("vm.rebuild_transcript_render_state", fields: [
            "reason": reason
        ])
        transcriptRenderController.replaceState(
            ExampleChatTranscriptPayloadFactory.renderState(
                from: transcript,
                isGenerating: isRunningAgent,
                expandToolActivityBlocks: expandsTranscriptToolDetailsForTesting,
                expansionState: transcriptExpansionState,
                fontScale: transcriptRenderFontScale,
                interfaceTheme: transcriptRenderInterfaceTheme
            )
        )
    }

    private func withoutAutomaticTranscriptRenderRebuild(_ body: () -> Void) {
        let wasSuppressed = suppressesTranscriptRenderRebuild
        suppressesTranscriptRenderRebuild = true
        defer {
            suppressesTranscriptRenderRebuild = wasSuppressed
        }
        body()
    }

    func refreshWorkspace() {
        Task {
            await refreshWorkspace()
        }
    }

    private func schedulePhotoLibraryOCRCacheStatusRefresh() {
        Task { [weak self] in
            guard let self else {
                return
            }
            let freshStatus = await self.loadPhotoLibraryOCRCacheStatus()
            self.applyPhotoLibraryOCRCacheStatus(freshStatus)
        }
    }

    private func schedulePhotoLibraryVLMSummaryCacheStatusRefresh() {
        Task { [weak self] in
            guard let self else {
                return
            }
            let freshStatus = await self.loadPhotoLibraryVLMSummaryCacheStatus()
            self.applyPhotoLibraryVLMSummaryCacheStatus(freshStatus)
        }
    }

    private func schedulePhotoLibraryPlaceCacheStatusRefresh() {
        Task { [weak self] in
            guard let self else {
                return
            }
            let freshStatus = await self.loadPhotoLibraryPlaceCacheStatus()
            self.applyPhotoLibraryPlaceCacheStatus(freshStatus)
        }
    }

    private func loadPhotoLibraryOCRCacheStatus() async -> PhotoSorterMediaOCRCacheStatus {
        let mount = photoLibraryMount
        return await Task.detached(priority: .utility) {
            mount.photoLibraryOCRCacheStatus
        }.value
    }

    private func loadPhotoLibraryVLMSummaryCacheStatus() async -> PhotoSorterMediaVLMStatus {
        let mount = photoLibraryMount
        return await Task.detached(priority: .utility) {
            mount.photoLibraryVLMSummaryCacheStatus
        }.value
    }

    private func loadPhotoLibraryPlaceCacheStatus() async -> PhotoSorterMediaPlaceCacheStatus {
        let mount = photoLibraryMount
        return await Task.detached(priority: .utility) {
            mount.photoLibraryPlaceCacheStatus
        }.value
    }

    private func applyPhotoLibraryOCRCacheStatus(_ freshStatus: PhotoSorterMediaOCRCacheStatus) {
        if photoLibraryOCRCacheStatus != freshStatus {
            photoLibraryOCRCacheStatus = freshStatus
        }
    }

    private func applyPhotoLibraryVLMSummaryCacheStatus(_ freshStatus: PhotoSorterMediaVLMStatus) {
        if photoLibraryVLMSummaryCacheStatus != freshStatus {
            photoLibraryVLMSummaryCacheStatus = freshStatus
        }
    }

    private func applyPhotoLibraryPlaceCacheStatus(_ freshStatus: PhotoSorterMediaPlaceCacheStatus) {
        if photoLibraryPlaceCacheStatus != freshStatus {
            photoLibraryPlaceCacheStatus = freshStatus
        }
    }

    func startOCRCachePreheatBatch() {
        photoLibraryMount.startOCRCachePreheatBatch()
        schedulePhotoLibraryOCRCacheStatusRefresh()
    }

    func pauseOCRCachePreheat() {
        photoLibraryMount.pauseOCRCachePreheat()
        schedulePhotoLibraryOCRCacheStatusRefresh()
    }

    func resumeOCRCachePreheat() {
        photoLibraryMount.resumeOCRCachePreheat()
        schedulePhotoLibraryOCRCacheStatusRefresh()
    }

    func startVLMSummaryCachePreheatBatch() {
        photoLibraryMount.startVLMSummaryCachePreheatBatch()
        schedulePhotoLibraryVLMSummaryCacheStatusRefresh()
    }

    func pauseVLMSummaryCachePreheat() {
        photoLibraryMount.pauseVLMSummaryCachePreheat()
        schedulePhotoLibraryVLMSummaryCacheStatusRefresh()
    }

    func resumeVLMSummaryCachePreheat() {
        photoLibraryMount.resumeVLMSummaryCachePreheat()
        schedulePhotoLibraryVLMSummaryCacheStatusRefresh()
    }

    func startPlaceCachePreheatBatch() {
        guard agentAccessMode == .full else {
            photoLibraryPlaceCacheStatus = PhotoSorterMediaPlaceCacheStatus(
                cachedCount: photoLibraryPlaceCacheStatus.cachedCount,
                totalCount: photoLibraryPlaceCacheStatus.totalCount,
                isPreheating: false,
                isPaused: false,
                processedInCurrentBatch: 0,
                batchLimit: photoLibraryPlaceCacheStatus.batchLimit,
                message: "完全访问模式后可缓存地点"
            )
            return
        }
        updatePlaceCacheTaskMode(.running)
        if !photoLibraryMount.resumePlaceCachePreheat() {
            photoLibraryMount.startPlaceCachePreheatBatch()
        }
        schedulePhotoLibraryPlaceCacheStatusRefresh()
    }

    func pausePlaceCachePreheat() {
        updatePlaceCacheTaskMode(.paused)
        photoLibraryMount.pausePlaceCachePreheat()
        schedulePhotoLibraryPlaceCacheStatusRefresh()
    }

    func resumePlaceCachePreheat() {
        guard agentAccessMode == .full else {
            return
        }
        updatePlaceCacheTaskMode(.running)
        if !photoLibraryMount.resumePlaceCachePreheat() {
            photoLibraryMount.startPlaceCachePreheatBatch()
        }
        schedulePhotoLibraryPlaceCacheStatusRefresh()
    }

    func openWorkspaceFile(
        _ node: WorkspaceFileNode,
        context: WorkspaceFileOpenContext? = nil
    ) {
        guard !node.isDirectory || node.isChatPackage else {
            return
        }
        e2eEventLog?.record("workspace_file_open_requested", fields: [
            "path": node.path,
            "name": node.name
        ])
        recordDiagnostic("workspace_file_open_requested", fields: [
            "path": node.path,
            "name": node.name
        ])

        Task {
            guard let runtime else {
                let preview = WorkspaceMediaPreview(
                    title: node.name,
                    path: node.path,
                    imageData: nil,
                    message: "Workspace 还没有准备好。",
                isLoading: false
            )
            workspaceMediaPreview = preview
                recordDiagnostic("workspace_file_preview_failed", fields: [
                    "path": node.path,
                    "reason": "runtime_unavailable"
                ])
                return
            }

            if node.isChatPackage {
                await openChatPackage(node, runtime: runtime)
                return
            }

            if let quickLookURL = runtime.quickLookURL(for: node.path) {
                workspaceQuickLookURL = quickLookURL
                recordDiagnostic("workspace_file_quicklook_opened", fields: [
                    "path": node.path,
                    "file_url": quickLookURL.path
                ])
                return
            }

            let gallerySeed = Self.mediaPreviewGallerySeed(
                opening: node,
                context: context
            )
            let preview = WorkspaceMediaPreview(
                title: node.name,
                path: node.path,
                canRestoreFromTrash: photoLibraryMount.isPhotoLibraryTrashDisplayPath(node.path),
                imageData: nil,
                message: nil,
                isLoading: true,
                galleryDirectoryPath: gallerySeed?.directoryPath,
                galleryItems: gallerySeed?.items ?? [],
                galleryLoadedNodeCount: gallerySeed?.loadedNodeCount ?? 0,
                galleryHasMoreNodes: gallerySeed?.hasMoreNodes ?? false,
                workspaceCacheVersionToken: workspaceCacheVersionToken
            )
            workspaceMediaPreview = preview
            await loadWorkspacePreviewNode(node, into: preview, runtime: runtime)
        }
    }

    func showPreviousWorkspacePreviewItem() {
        Task {
            await navigateWorkspacePreview(by: -1)
        }
    }

    func showNextWorkspacePreviewItem() {
        Task {
            await navigateWorkspacePreview(by: 1)
        }
    }

    func selectWorkspacePreviewItem(path: String) {
        Task {
            await selectWorkspacePreviewItem(at: path)
        }
    }

    func prepareWorkspacePreviewPage(path: String) {
        Task {
            await loadMoreWorkspacePreviewItemsIfNeeded(nearPath: path)
        }
    }

    private func navigateWorkspacePreview(by offset: Int) async {
        guard offset != 0,
              let preview = workspaceMediaPreview,
              let currentIndex = preview.currentGalleryIndex
        else {
            return
        }

        var targetIndex = currentIndex + offset
        if targetIndex >= preview.galleryItems.count {
            await loadMoreWorkspacePreviewItemsIfNeeded(for: preview)
            guard workspaceMediaPreview === preview,
                  let refreshedIndex = preview.currentGalleryIndex
            else {
                return
            }
            targetIndex = refreshedIndex + offset
        }

        guard targetIndex >= 0,
              targetIndex < preview.galleryItems.count,
              let runtime
        else {
            return
        }

        await loadWorkspacePreviewNode(
            preview.galleryItems[targetIndex],
            into: preview,
            runtime: runtime
        )
    }

    private func selectWorkspacePreviewItem(at path: String) async {
        guard let preview = workspaceMediaPreview,
              let item = preview.galleryItems.first(where: { $0.path == path }),
              let runtime
        else {
            return
        }

        await loadWorkspacePreviewNode(item, into: preview, runtime: runtime)
        await loadMoreWorkspacePreviewItemsIfNeeded(nearPath: path)
    }

    private func loadMoreWorkspacePreviewItemsIfNeeded(nearPath path: String) async {
        guard let preview = workspaceMediaPreview,
              let index = preview.galleryItems.firstIndex(where: { $0.path == path }),
              index >= max(preview.galleryItems.count - 4, 0)
        else {
            return
        }

        await loadMoreWorkspacePreviewItemsIfNeeded(for: preview)
    }

    private func loadMoreWorkspacePreviewItemsIfNeeded(
        for preview: WorkspaceMediaPreview
    ) async {
        guard workspaceMediaPreview === preview,
              let directoryPath = preview.galleryDirectoryPath,
              preview.galleryHasMoreNodes,
              !preview.isLoadingMoreGalleryItems
        else {
            return
        }

        let offset = preview.galleryLoadedNodeCount
        preview.isLoadingMoreGalleryItems = true
        defer {
            if workspaceMediaPreview === preview {
                preview.isLoadingMoreGalleryItems = false
            }
        }

        do {
            let page = try await loadWorkspaceDirectoryPage(
                for: directoryPath,
                offset: offset
            )
            guard workspaceMediaPreview === preview else {
                return
            }

            let existingPaths = Set(preview.galleryItems.map(\.path))
            let freshItems = Self.mediaPreviewGalleryItems(in: page.nodes)
                .filter { !existingPaths.contains($0.path) }
            preview.galleryItems.append(contentsOf: freshItems)
            preview.galleryLoadedNodeCount = offset + page.nodes.count
            preview.galleryHasMoreNodes = page.hasMore && !page.nodes.isEmpty
            recordDiagnostic("workspace_file_preview_gallery_page_loaded", fields: [
                "directory_path": directoryPath,
                "offset": "\(offset)",
                "node_count": "\(page.nodes.count)",
                "image_count": "\(freshItems.count)",
                "has_more": "\(preview.galleryHasMoreNodes)"
            ])
        } catch {
            guard workspaceMediaPreview === preview else {
                return
            }
            preview.galleryHasMoreNodes = false
            if preview.imageData == nil {
                preview.message = error.localizedDescription
            }
            recordDiagnostic("workspace_file_preview_gallery_page_failed", fields: [
                "directory_path": directoryPath,
                "offset": "\(offset)",
                "message": error.localizedDescription
            ])
        }
    }

    private func loadWorkspacePreviewNode(
        _ node: WorkspaceFileNode,
        into preview: WorkspaceMediaPreview,
        runtime: MSPPlaygroundShellRuntime
    ) async {
        preview.path = node.path
        preview.title = node.name
        preview.canRestoreFromTrash = photoLibraryMount.isPhotoLibraryTrashDisplayPath(node.path)
        if let cachedImageData = preview.galleryImageDataByPath[node.path] {
            preview.imageData = cachedImageData
            preview.media = preview.galleryMediaByPath[node.path]
            preview.message = nil
            preview.isLoading = false
            return
        }
        if let cachedMedia = preview.galleryMediaByPath[node.path] {
            preview.imageData = cachedMedia.kind == .image ? cachedMedia.thumbnailData : nil
            preview.media = cachedMedia
            preview.message = nil
            preview.isLoading = false
            return
        }
        preview.imageData = nil
        preview.media = nil
        preview.message = preview.galleryMessageByPath[node.path]
        preview.isLoading = true
        preview.galleryLoadingPaths.insert(node.path)

        let requestedPath = node.path
        switch await runtime.preview(for: requestedPath) {
        case .image(let data, let fileName):
            guard workspaceMediaPreview === preview else {
                return
            }
            preview.galleryLoadingPaths.remove(requestedPath)
            let media = PhotoSorterMediaPreview(
                path: requestedPath,
                fileName: fileName,
                kind: .image,
                pixelWidth: 0,
                pixelHeight: 0,
                thumbnailData: data,
                photoLibraryLocalIdentifier: nil,
                fileURL: nil
            )
            preview.galleryImageDataByPath[requestedPath] = data
            preview.galleryMediaByPath[requestedPath] = media
            preview.galleryMessageByPath.removeValue(forKey: requestedPath)
            guard preview.path == requestedPath else {
                return
            }
            preview.title = fileName
            preview.imageData = data
            preview.media = media
            preview.message = nil
            preview.isLoading = false
            recordDiagnostic("workspace_file_preview_loaded", fields: [
                "path": requestedPath,
                "file_name": fileName,
                "bytes": "\(data.count)"
            ])
        case .media(let media):
            guard workspaceMediaPreview === preview else {
                return
            }
            preview.galleryLoadingPaths.remove(requestedPath)
            preview.galleryImageDataByPath.removeValue(forKey: requestedPath)
            preview.galleryMediaByPath[requestedPath] = media
            preview.galleryMessageByPath.removeValue(forKey: requestedPath)
            guard preview.path == requestedPath else {
                return
            }
            preview.title = media.fileName
            preview.imageData = nil
            preview.media = media
            preview.message = nil
            preview.isLoading = false
            recordDiagnostic("workspace_file_preview_loaded", fields: [
                "path": requestedPath,
                "file_name": media.fileName,
                "media_kind": media.kind.rawValue
            ])
        case .unsupported(let message), .unavailable(let message):
            guard workspaceMediaPreview === preview else {
                return
            }
            preview.galleryLoadingPaths.remove(requestedPath)
            preview.galleryImageDataByPath.removeValue(forKey: requestedPath)
            preview.galleryMediaByPath.removeValue(forKey: requestedPath)
            preview.galleryMessageByPath[requestedPath] = message
            guard preview.path == requestedPath else {
                return
            }
            preview.imageData = nil
            preview.media = nil
            preview.message = message
            preview.isLoading = false
            recordDiagnostic("workspace_file_preview_failed", fields: [
                "path": requestedPath,
                "message": message
            ])
        }
    }

    private struct WorkspaceMediaPreviewGallerySeed {
        var directoryPath: String?
        var items: [WorkspaceFileNode]
        var loadedNodeCount: Int
        var hasMoreNodes: Bool
    }

    private static func mediaPreviewGallerySeed(
        opening node: WorkspaceFileNode,
        context: WorkspaceFileOpenContext?
    ) -> WorkspaceMediaPreviewGallerySeed? {
        guard isMediaPreviewGalleryItem(node) else {
            return nil
        }

        guard let context else {
            return WorkspaceMediaPreviewGallerySeed(
                directoryPath: nil,
                items: [node],
                loadedNodeCount: 1,
                hasMoreNodes: false
            )
        }

        var items = mediaPreviewGalleryItems(in: context.loadedNodes)
        if !items.contains(where: { $0.path == node.path }) {
            items.append(node)
        }

        return WorkspaceMediaPreviewGallerySeed(
            directoryPath: context.directoryPath,
            items: items,
            loadedNodeCount: max(context.loadedNodeCount, context.loadedNodes.count),
            hasMoreNodes: context.hasMoreNodes
        )
    }

    private static func mediaPreviewGalleryItems(
        in nodes: [WorkspaceFileNode]
    ) -> [WorkspaceFileNode] {
        nodes.filter(isMediaPreviewGalleryItem)
    }

    private static func isMediaPreviewGalleryItem(
        _ node: WorkspaceFileNode
    ) -> Bool {
        !node.isDirectory && (node.mediaKind == .image || node.mediaKind == .video)
    }

    private func ensureActiveChatSession(firstUserMessage: String) {
        guard activeChatSession == nil,
              activeChatCreationTask == nil else {
            return
        }
        guard let workspaceURL else {
            recordDiagnostic("agent_chat_create_skipped", fields: [
                "reason": "workspace_unavailable"
            ])
            return
        }

        let location = PhotoSorterChatPersistence.defaultPackageLocation(
            in: workspaceURL,
            firstUserMessage: firstUserMessage
        )
        let store = agentChatStore
        let diagnosticsLog = diagnosticsLog
        activeChatPersistenceGeneration = UUID()
        let generation = activeChatPersistenceGeneration
        activeChatVirtualPath = location.virtualPath
        recordDiagnostic("agent_chat_create_queued", fields: [
            "virtual_path": location.virtualPath,
            "package_url": location.packageURL.path
        ])

        let creationTask = Task.detached(priority: .utility) { () -> ActiveChatCreationResult in
            do {
                try PhotoSorterChatPersistence.ensureConversationsDirectory(in: workspaceURL)
                let session = try store.createPackage(
                    at: location.packageURL,
                    packageID: UUID().uuidString
                )
                await diagnosticsLog.record("agent_chat_created", fields: [
                    "virtual_path": location.virtualPath,
                    "package_url": location.packageURL.path
                ])
                return .success(session)
            } catch {
                let message = error.localizedDescription
                await diagnosticsLog.record("agent_chat_create_failed", fields: [
                    "virtual_path": location.virtualPath,
                    "package_url": location.packageURL.path,
                    "message": message
                ])
                return .failure(message)
            }
        }
        activeChatCreationTask = creationTask

        Task { [weak self] in
            let result = await creationTask.value
            guard let self,
                  self.activeChatPersistenceGeneration == generation,
                  self.activeChatVirtualPath == location.virtualPath else {
                return
            }
            self.activeChatCreationTask = nil
            switch result {
            case .success(let session):
                self.activeChatSession = session
                self.workspaceTreeRevision += 1
                await self.refreshWorkspace()
            case .failure(let message):
                self.appendRuntimeError("创建对话失败：\(message)")
            }
        }
    }

    private func openChatPackage(
        _ node: WorkspaceFileNode,
        runtime: MSPPlaygroundShellRuntime
    ) async {
        guard !isRunningAgent else {
            recordDiagnostic("agent_chat_open_skipped", fields: [
                "path": node.path,
                "reason": "agent_running"
            ])
            return
        }
        guard let packageURL = runtime.localWorkspaceURL(for: node.path) else {
            recordDiagnostic("agent_chat_open_failed", fields: [
                "path": node.path,
                "reason": "local_url_unavailable"
            ])
            return
        }

        chatOpenTask?.cancel()
        chatFullOpenTask?.cancel()
        let requestID = UUID()
        chatOpenRequestID = requestID
        isOpeningChatPackage = true
        workspaceMediaPreview = nil
        workspaceQuickLookURL = nil
        recordDiagnostic("agent_chat_open_started", fields: [
            "path": node.path,
            "package_url": packageURL.path
        ])

        let store = agentChatStore
        let virtualPath = node.path
        let snapshotType = PhotoSorterChatPersistence.transcriptSnapshotType
        chatOpenTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Self.openChatPackageOffMain(
                        store: store,
                        packageURL: packageURL,
                        virtualPath: virtualPath,
                        snapshotType: snapshotType
                    )
                }
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.chatOpenRequestID == requestID
            else {
                return
            }
            self.chatOpenTask = nil
            switch result {
            case .success(let opened):
                await self.applyOpenedChatPackage(opened)
                if opened.isUIProjectionOnly {
                    self.startFullChatPackageLoad(
                        store: store,
                        packageURL: packageURL,
                        virtualPath: virtualPath,
                        snapshotType: snapshotType,
                        requestID: requestID
                    )
                } else {
                    self.isOpeningChatPackage = false
                    self.chatOpenRequestID = nil
                }
            case .failure(let error):
                self.isOpeningChatPackage = false
                self.isActiveChatReadyForInput = true
                self.chatOpenRequestID = nil
                self.recordDiagnostic("agent_chat_open_failed", fields: [
                    "path": virtualPath,
                    "message": error.localizedDescription
                ])
                self.appendRuntimeError("打开对话失败：\(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func openChatPackageOffMain(
        store: MSPAgentChatStore,
        packageURL: URL,
        virtualPath: String,
        snapshotType: String
    ) throws -> OpenedChatPackage {
        try PhotoSorterChatPersistence.validateChatPackageEnvelopeForProjectionOpen(at: packageURL)
        if let projection = PhotoSorterChatPersistence.readCurrentUIProjection(from: packageURL),
           uiProjectionItemsAreUsableForOpen(projection.items) {
            return OpenedChatPackage(
                session: MSPAgentChatSession(packageURL: packageURL),
                virtualPath: virtualPath,
                packageURL: packageURL,
                modelHistory: [],
                transcript: projection.items,
                transcriptTotalItemCount: projection.totalItemCount,
                transcriptStartIndex: 0,
                isUIProjectionOnly: true
            )
        }

        let opened = try openFullChatPackageOffMain(
            store: store,
            packageURL: packageURL,
            virtualPath: virtualPath,
            snapshotType: snapshotType
        )
        return opened
    }

    nonisolated private static func openFullChatPackageOffMain(
        store: MSPAgentChatStore,
        packageURL: URL,
        virtualPath: String,
        snapshotType: String
    ) throws -> OpenedChatPackage {
        let opened = try store.openPackage(
            at: packageURL,
            latestApplicationStateSnapshotType: snapshotType
        )
        let latestTranscript = transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: opened.latestApplicationStateSnapshot
        )
        let restoredTranscript: [MSPAgentTimelineItem]
        if uiProjectionItemsAreUsableForOpen(latestTranscript) {
            restoredTranscript = latestTranscript
        } else {
            let applicationSnapshots = (try? opened.session.applicationStateSnapshots(type: snapshotType)) ?? []
            restoredTranscript = transcriptItemsForOpeningChatPackage(
                applicationStateSnapshots: applicationSnapshots,
                latestApplicationStateSnapshot: opened.latestApplicationStateSnapshot
            )
        }
        let restoredSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: restoredTranscript,
            activeChatVirtualPath: virtualPath
        )
        if opened.latestApplicationStateSnapshot != restoredSnapshot {
            _ = try opened.session.appendApplicationStateSnapshot(
                type: PhotoSorterChatPersistence.transcriptSnapshotType,
                snapshot: restoredSnapshot
            )
        }
        try? PhotoSorterChatPersistence.writeUIProjection(
            items: restoredTranscript,
            activeChatVirtualPath: virtualPath,
            to: packageURL
        )
        return OpenedChatPackage(
            session: opened.session,
            virtualPath: virtualPath,
            packageURL: packageURL,
            modelHistory: opened.modelVisibleHistory,
            transcript: restoredTranscript,
            transcriptTotalItemCount: restoredTranscript.count,
            transcriptStartIndex: 0,
            isUIProjectionOnly: false
        )
    }

    private func applyOpenedChatPackage(_ opened: OpenedChatPackage) async {
        activeChatPersistenceGeneration = UUID()
        chatTranscriptSnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatCreationTask?.cancel()
        activeChatWriteTask?.cancel()
        activeChatModelHistorySnapshotTask = nil
        activeChatCreationTask = nil
        activeChatWriteTask = nil
        activeChatSession = opened.session
        activeChatVirtualPath = opened.virtualPath
        activeChatFullTranscriptItems = opened.isUIProjectionOnly ? nil : opened.transcript
        activeChatDisplayedTranscriptStartIndex = opened.transcriptStartIndex
        activeChatDisplayedTranscriptBaselineCount = opened.transcript.count
        isActiveChatReadyForInput = !opened.isUIProjectionOnly
        transcript = opened.transcript
        transcriptExpansionState = .empty
        contextUsage = nil
        workspaceMediaPreview = nil
        workspaceQuickLookURL = nil
        clearCurrentTurnStreamingState()
        if !opened.isUIProjectionOnly {
            await agentRuntime?.replaceTranscriptItems(opened.modelHistory)
        }
        recordDiagnostic("agent_chat_opened", fields: [
            "path": opened.virtualPath,
            "package_url": opened.packageURL.path,
            "transcript_count": "\(opened.transcript.count)",
            "transcript_total_count": "\(opened.transcriptTotalItemCount)",
            "transcript_start_index": "\(opened.transcriptStartIndex)",
            "model_history_count": "\(opened.modelHistory.count)",
            "ui_projection_only": "\(opened.isUIProjectionOnly)"
        ])
    }

    private func startFullChatPackageLoad(
        store: MSPAgentChatStore,
        packageURL: URL,
        virtualPath: String,
        snapshotType: String,
        requestID: UUID
    ) {
        chatFullOpenTask?.cancel()
        chatFullOpenTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try Self.openFullChatPackageOffMain(
                        store: store,
                        packageURL: packageURL,
                        virtualPath: virtualPath,
                        snapshotType: snapshotType
                    )
                }
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.chatOpenRequestID == requestID,
                  self.activeChatVirtualPath == virtualPath else {
                return
            }
            self.chatFullOpenTask = nil
            self.chatOpenRequestID = nil
            switch result {
            case .success(let opened):
                await self.applyFullyOpenedChatPackageAfterPreview(opened)
            case .failure(let error):
                self.isOpeningChatPackage = false
                self.isActiveChatReadyForInput = false
                self.recordDiagnostic("agent_chat_full_open_failed", fields: [
                    "path": virtualPath,
                    "message": error.localizedDescription
                ])
                self.appendRuntimeError("恢复完整对话失败：\(error.localizedDescription)")
            }
        }
    }

    private func applyFullyOpenedChatPackageAfterPreview(_ opened: OpenedChatPackage) async {
        activeChatSession = opened.session
        activeChatVirtualPath = opened.virtualPath
        activeChatFullTranscriptItems = opened.transcript
        if let suffixStartIndex = Self.suffixStartIndex(
            fullTranscript: opened.transcript,
            projectedTranscript: transcript
        ) {
            activeChatDisplayedTranscriptStartIndex = suffixStartIndex
            activeChatDisplayedTranscriptBaselineCount = transcript.count
        } else {
            activeChatDisplayedTranscriptStartIndex = 0
            activeChatDisplayedTranscriptBaselineCount = opened.transcript.count
            transcript = opened.transcript
        }
        await agentRuntime?.replaceTranscriptItems(opened.modelHistory)
        isOpeningChatPackage = false
        isActiveChatReadyForInput = true
        recordDiagnostic("agent_chat_full_opened", fields: [
            "path": opened.virtualPath,
            "package_url": opened.packageURL.path,
            "visible_transcript_count": "\(transcript.count)",
            "full_transcript_count": "\(opened.transcript.count)",
            "model_history_count": "\(opened.modelHistory.count)"
        ])
    }

    nonisolated private static func suffixStartIndex(
        fullTranscript: [MSPAgentTimelineItem],
        projectedTranscript: [MSPAgentTimelineItem]
    ) -> Int? {
        guard projectedTranscript.count <= fullTranscript.count else {
            return nil
        }
        let startIndex = fullTranscript.count - projectedTranscript.count
        for index in projectedTranscript.indices {
            guard fullTranscript[startIndex + index] == projectedTranscript[index] else {
                return nil
            }
        }
        return startIndex
    }

    private func scheduleActiveChatTranscriptSnapshot(
        reason: String,
        delayNanoseconds: UInt64 = 700_000_000,
        reschedulesExisting: Bool = true
    ) {
        guard activeChatSession != nil || activeChatCreationTask != nil else {
            return
        }
        if !reschedulesExisting, chatTranscriptSnapshotTask != nil {
            return
        }
        chatTranscriptSnapshotTask?.cancel()
        chatTranscriptSnapshotTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
            }
            guard let self else {
                return
            }
            await self.persistActiveChatTranscriptSnapshot(reason: reason)
        }
    }

    private func persistActiveChatTranscriptSnapshot(reason: String) async {
        let generation = activeChatPersistenceGeneration
        let activeChatVirtualPath = activeChatVirtualPath
        let writeTask = queueActiveChatTranscriptSnapshot(reason: reason)
        await writeTask?.value
        guard activeChatPersistenceGeneration == generation,
              self.activeChatVirtualPath == activeChatVirtualPath else {
            recordDiagnostic("agent_chat_write_skipped", fields: [
                "reason": "transcript_snapshot:\(reason)",
                "cause": "stale_active_chat_after_write"
            ])
            return
        }
    }

    @discardableResult
    private func queueActiveChatTranscriptSnapshot(
        reason: String
    ) -> Task<Void, Never>? {
        guard activeChatSession != nil || activeChatCreationTask != nil else {
            return nil
        }
        let visibleTranscript = transcript
        let fullTranscript = activeChatFullTranscriptItems
        let displayedStartIndex = activeChatDisplayedTranscriptStartIndex
        let displayedBaselineCount = activeChatDisplayedTranscriptBaselineCount
        let activeChatVirtualPath = activeChatVirtualPath
        return queueActiveChatWrite(reason: "transcript_snapshot:\(reason)") { session in
            let visibleItems = Self.transcriptItemsForPersistence(
                visibleTranscript: visibleTranscript,
                fullTranscript: fullTranscript,
                displayedStartIndex: displayedStartIndex,
                displayedBaselineCount: displayedBaselineCount
            )
            let existingSnapshot = try? session.latestApplicationStateSnapshot(
                type: PhotoSorterChatPersistence.transcriptSnapshotType
            )
            let items = Self.durableTranscriptItemsForPersistence(
                visibleTranscript: visibleItems,
                existingSnapshot: existingSnapshot
            )
            let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
                items: items,
                activeChatVirtualPath: activeChatVirtualPath
            )
            try await session.appendApplicationStateSnapshotAsync(
                type: PhotoSorterChatPersistence.transcriptSnapshotType,
                snapshot: snapshot
            )
            try PhotoSorterChatPersistence.writeUIProjection(
                items: items,
                activeChatVirtualPath: activeChatVirtualPath,
                to: session.packageURL
            )
        }
    }

    nonisolated static func durableTranscriptItemsForPersistence(
        visibleTranscript: [MSPAgentTimelineItem],
        fullTranscript: [MSPAgentTimelineItem]? = nil,
        displayedStartIndex: Int = 0,
        displayedBaselineCount: Int = 0,
        existingSnapshot: MSPAgentJSONValue? = nil
    ) -> [MSPAgentTimelineItem] {
        let visibleItems = uiTranscriptItems(transcriptItemsForPersistence(
            visibleTranscript: visibleTranscript,
            fullTranscript: fullTranscript,
            displayedStartIndex: displayedStartIndex,
            displayedBaselineCount: displayedBaselineCount
        ))
        let existingItems = existingSnapshot
            .map { uiTranscriptItems(PhotoSorterChatPersistence.transcriptItems(from: $0)) }
            ?? []
        let mergedItems = mergingTranscriptItems(anchor: existingItems, visible: visibleItems)
        return repairingPersistedTranscriptProjection(mergedItems)
    }

    nonisolated static func transcriptItemsForOpeningChatPackage(
        latestApplicationStateSnapshot: MSPAgentJSONValue?
    ) -> [MSPAgentTimelineItem] {
        transcriptItemsForOpeningChatPackage(
            applicationStateSnapshots: latestApplicationStateSnapshot.map { [$0] } ?? [],
            latestApplicationStateSnapshot: latestApplicationStateSnapshot
        )
    }

    nonisolated static func transcriptItemsForOpeningChatPackage(
        applicationStateSnapshots: [MSPAgentJSONValue],
        latestApplicationStateSnapshot: MSPAgentJSONValue?
    ) -> [MSPAgentTimelineItem] {
        let candidates = applicationStateSnapshots.isEmpty
            ? latestApplicationStateSnapshot.map { [$0] } ?? []
            : applicationStateSnapshots
        for snapshot in candidates.reversed() {
            let items = transcriptItemsFromApplicationStateSnapshot(snapshot)
            guard applicationTranscriptItemsAreUsableForOpen(items) else {
                continue
            }
            return items
        }

        let snapshotItems = latestApplicationStateSnapshot
            .map(transcriptItemsFromApplicationStateSnapshot)
            ?? []
        return snapshotItems.filter { !transcriptItemContainsModelContextSummary($0) }
    }

    nonisolated private static func transcriptItemsFromApplicationStateSnapshot(
        _ snapshot: MSPAgentJSONValue
    ) -> [MSPAgentTimelineItem] {
        repairingPersistedTranscriptProjection(
            uiTranscriptItems(PhotoSorterChatPersistence.transcriptItems(from: snapshot))
        )
    }

    nonisolated private static func applicationTranscriptItemsAreUsableForOpen(
        _ items: [MSPAgentTimelineItem]
    ) -> Bool {
        uiProjectionItemsAreUsableForOpen(items)
    }

    nonisolated private static func uiTranscriptItems(
        _ items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        items.map(repairVisibleUserMessageIfNeeded)
    }

    nonisolated private static func repairVisibleUserMessageIfNeeded(
        _ item: MSPAgentTimelineItem
    ) -> MSPAgentTimelineItem {
        guard item.kind == .user,
              let components = selectedTextPromptComponents(from: item.body) else {
            return item
        }

        var repaired = item
        repaired.body = components.userPrompt
        if repaired.sourceTextSelections.compactMap(\.normalized).isEmpty {
            repaired.sourceTextSelections = components.selections
        }
        return repaired
    }

    private struct SelectedTextPromptComponents {
        var userPrompt: String
        var selections: [PhotoSorterTextSelectionSnapshot]
    }

    nonisolated private static func selectedTextPromptComponents(
        from text: String
    ) -> SelectedTextPromptComponents? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("# Selected text:"),
              let requestMarkerRange = normalized.range(of: "## My request for Codex:") else {
            return nil
        }

        let context = String(normalized[..<requestMarkerRange.lowerBound])
        var request = String(normalized[requestMarkerRange.upperBound...])
        if request.first == "\n" {
            request.removeFirst()
        }
        let userPrompt = request.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let selectedTextHeaderRange = context.range(of: "# Selected text:") else {
            return nil
        }
        let selectionContext = String(context[selectedTextHeaderRange.upperBound...])
        let selectionTexts = selectedTextPromptSelectionTexts(from: selectionContext)
        guard !selectionTexts.isEmpty else {
            return nil
        }

        let selections = selectionTexts.enumerated().map { index, selectedText in
            PhotoSorterTextSelectionSnapshot(
                id: recoveredTextSelectionID(
                    selectedText: selectedText,
                    userPrompt: userPrompt,
                    index: index
                ),
                selectedText: selectedText
            )
        }
        return SelectedTextPromptComponents(userPrompt: userPrompt, selections: selections)
    }

    nonisolated private static func selectedTextPromptSelectionTexts(
        from context: String
    ) -> [String] {
        var selections: [String] = []
        var currentLines: [String] = []
        var isCollectingSelection = false

        func finishCurrentSelection() {
            let selectedText = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedText.isEmpty {
                selections.append(selectedText)
            }
            currentLines.removeAll()
        }

        let lines = context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for line in lines {
            if line.hasPrefix("## Selection ") {
                if isCollectingSelection {
                    finishCurrentSelection()
                }
                isCollectingSelection = true
                continue
            }
            guard isCollectingSelection else {
                continue
            }
            currentLines.append(line)
        }
        if isCollectingSelection {
            finishCurrentSelection()
        }
        return selections
    }

    nonisolated private static func recoveredTextSelectionID(
        selectedText: String,
        userPrompt: String,
        index: Int
    ) -> UUID {
        let digest = sha256Hex("selected-text-prompt|\(index)|\(selectedText)|\(userPrompt)")
        let tail = String(digest.prefix(12))
        return UUID(uuidString: "00000000-0000-4000-8000-\(tail)") ?? UUID()
    }

    nonisolated private static func repairingPersistedTranscriptProjection(
        _ items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        guard !items.isEmpty else {
            return items
        }

        var repaired = orderingTranscriptItemsByTurnIfPossible(items)
        repaired = removingDuplicateSelectedTextUsers(from: repaired)
        repaired = promotingAssistantProgressItemsCoveredByLaterFinals(from: repaired)
        repaired = removingAssistantProgressItemsCoveredBySameTurnFinals(from: repaired)
        repaired = removingAssistantProgressPrefixesCoveredByFinals(from: repaired)
        repaired = removingNonTranscriptToolItems(from: repaired)
        repaired = mergingToolResultsIntoToolCalls(from: repaired)
        return repaired
    }

    nonisolated private static func uiProjectionItemsAreUsableForOpen(
        _ items: [MSPAgentTimelineItem]
    ) -> Bool {
        !items.isEmpty && !items.contains(where: transcriptItemContainsModelContextSummary)
    }

    nonisolated private static func orderingTranscriptItemsByTurnIfPossible(
        _ items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        guard items.contains(where: { $0.turnStartedAtMilliseconds != nil }) else {
            return items
        }
        return items.enumerated().sorted { lhs, rhs in
            let lhsTurn = lhs.element.turnStartedAtMilliseconds
            let rhsTurn = rhs.element.turnStartedAtMilliseconds
            switch (lhsTurn, rhsTurn) {
            case let (lhsTurn?, rhsTurn?) where lhsTurn != rhsTurn:
                return lhsTurn < rhsTurn
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    nonisolated private static func mergingToolResultsIntoToolCalls(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        var output: [MSPAgentTimelineItem] = []
        var toolCallIndexByCallID: [String: Int] = [:]

        for item in items {
            if item.kind == .toolCall {
                output.append(item)
                if let callID = nonEmptyString(item.callID) {
                    toolCallIndexByCallID[callID] = output.count - 1
                }
                continue
            }

            if item.kind == .toolResult,
               let callID = nonEmptyString(item.parentCallID) ?? nonEmptyString(item.callID),
               let callIndex = toolCallIndexByCallID[callID] {
                output[callIndex] = mergingToolTranscriptItem(
                    output[callIndex],
                    withSupplement: item
                )
                continue
            }

            output.append(item)
        }

        return output
    }

    nonisolated private static func mergingToolTranscriptItem(
        _ base: MSPAgentTimelineItem,
        withSupplement supplement: MSPAgentTimelineItem
    ) -> MSPAgentTimelineItem {
        guard base.kind == .toolCall else {
            return base
        }

        var merged = base
        merged.callID = merged.callID ?? supplement.callID ?? supplement.parentCallID
        merged.toolName = merged.toolName ?? supplement.toolName
        merged.command = merged.command ?? supplement.command
        merged.cwd = merged.cwd ?? supplement.cwd
        merged.execSessionID = merged.execSessionID ?? supplement.execSessionID
        merged.startedAtMilliseconds = merged.startedAtMilliseconds ?? supplement.startedAtMilliseconds
        merged.completedAtMilliseconds = merged.completedAtMilliseconds ?? supplement.completedAtMilliseconds
        merged.turnStartedAtMilliseconds = merged.turnStartedAtMilliseconds ?? supplement.turnStartedAtMilliseconds
        merged.turnDurationMilliseconds = merged.turnDurationMilliseconds ?? supplement.turnDurationMilliseconds

        if let envelope = PhotoSorterShellOutputEnvelope.parse(supplement.body) {
            merged.durationMilliseconds = merged.durationMilliseconds ?? envelope.durationMilliseconds
            if !envelope.isRunning {
                merged.exitCode = merged.exitCode ?? envelope.exitCode
            }
            let succeeded = envelope.exitCode.map { $0 == 0 } ?? true
            if envelope.isRunning {
                merged.status = "inProgress"
                merged.body = "正在执行工作区命令"
            } else if succeeded {
                merged.status = "completed"
                merged.body = "已执行工作区命令"
                merged.stdout = merged.stdout ?? envelope.output
            } else {
                merged.status = "failed"
                merged.body = "工作区命令执行失败"
                merged.stderr = merged.stderr ?? envelope.output
            }
        }

        merged.stdout = merged.stdout ?? supplement.stdout
        merged.stderr = merged.stderr ?? supplement.stderr
        merged.exitCode = merged.exitCode ?? supplement.exitCode
        merged.durationMilliseconds = merged.durationMilliseconds ?? supplement.durationMilliseconds
        if let status = nonEmptyString(supplement.status) {
            merged.status = status
        } else if merged.status == nil {
            merged.status = merged.exitCode.map { $0 == 0 ? "completed" : "failed" } ?? "completed"
        }
        if merged.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || merged.body == "正在执行工作区命令" {
            merged.body = merged.status == "failed" ? "工作区命令执行失败" : "已执行工作区命令"
        }
        return merged
    }

    nonisolated private static func removingDuplicateSelectedTextUsers(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        var seenSelectionSignatures = Set<String>()
        var output: [MSPAgentTimelineItem] = []
        for item in items {
            guard item.kind == .user else {
                output.append(item)
                continue
            }
            let selectionSignature = item.sourceTextSelections
                .map(textSelectionSignature)
                .joined(separator: "\u{1E}")
            guard !selectionSignature.isEmpty else {
                output.append(item)
                continue
            }
            let signature = [
                normalizedTranscriptBody(item.body),
                selectionSignature
            ].joined(separator: "\u{1F}")
            guard seenSelectionSignatures.insert(signature).inserted else {
                continue
            }
            output.append(item)
        }
        return output
    }

    nonisolated private static func removingNonTranscriptToolItems(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        var hiddenCallIDs = Set<String>()
        for item in items where item.kind == .toolCall && !toolItemShouldAppearInTranscript(item) {
            if let callID = nonEmptyString(item.callID) {
                hiddenCallIDs.insert(callID)
            }
        }

        return items.filter { item in
            if item.kind == .toolCall {
                return toolItemShouldAppearInTranscript(item)
            }
            if item.kind == .toolResult,
               let callID = nonEmptyString(item.parentCallID) ?? nonEmptyString(item.callID),
               hiddenCallIDs.contains(callID) {
                return false
            }
            return true
        }
    }

    nonisolated private static func toolItemShouldAppearInTranscript(
        _ item: MSPAgentTimelineItem
    ) -> Bool {
        let toolName = item.toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return toolName != MSPUpdatePlanToolSchema.name
    }

    nonisolated private static func promotingAssistantProgressItemsCoveredByLaterFinals(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        guard items.contains(where: { $0.kind == .assistantFinal }) else {
            return items
        }

        var promotedBodyCounts: [String: Int] = [:]
        let promoted = items.enumerated().map { index, item -> MSPAgentTimelineItem in
            guard item.kind == .assistantProgress else {
                return item
            }
            let body = normalizedTranscriptBody(item.body)
            guard !body.isEmpty,
                  items.dropFirst(index + 1).contains(where: { candidate in
                      candidate.kind == .assistantFinal
                          && normalizedTranscriptBody(candidate.body) == body
                  }) else {
                return item
            }
            promotedBodyCounts[body, default: 0] += 1
            var copy = item
            copy.kind = .assistantFinal
            copy.title = ""
            copy.status = nil
            return copy
        }
        guard !promotedBodyCounts.isEmpty else {
            return items
        }

        var keptPromotedFinalCounts: [String: Int] = [:]
        return promoted.filter { item in
            guard item.kind == .assistantFinal else {
                return true
            }
            let body = normalizedTranscriptBody(item.body)
            guard let promotedCount = promotedBodyCounts[body] else {
                return true
            }
            let nextCount = keptPromotedFinalCounts[body, default: 0] + 1
            keptPromotedFinalCounts[body] = nextCount
            return nextCount <= promotedCount
        }
    }

    nonisolated private static func removingAssistantProgressItemsCoveredBySameTurnFinals(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        let finalKeys = Set(items.compactMap { item -> String? in
            guard item.kind == .assistantFinal,
                  let turnStartedAtMilliseconds = item.turnStartedAtMilliseconds else {
                return nil
            }
            let body = normalizedTranscriptBody(item.body)
            guard !body.isEmpty else {
                return nil
            }
            return "\(turnStartedAtMilliseconds)\u{1F}\(body)"
        })
        guard !finalKeys.isEmpty else {
            return items
        }
        var output: [MSPAgentTimelineItem] = []
        for item in items {
            guard item.kind == .assistantProgress,
                  let turnStartedAtMilliseconds = item.turnStartedAtMilliseconds else {
                output.append(item)
                continue
            }
            let body = normalizedTranscriptBody(item.body)
            guard !body.isEmpty,
                  finalKeys.contains("\(turnStartedAtMilliseconds)\u{1F}\(body)") else {
                output.append(item)
                continue
            }
        }
        return output
    }

    nonisolated private static func removingAssistantProgressPrefixesCoveredByFinals(
        from items: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        var output: [MSPAgentTimelineItem] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            if item.kind == .assistantProgress,
               assistantProgressItemIsCoveredByFollowingFinal(item, in: items, after: index) {
                index += 1
                continue
            }
            output.append(item)
            index += 1
        }
        return output
    }

    nonisolated private static func assistantProgressItemIsCoveredByFollowingFinal(
        _ item: MSPAgentTimelineItem,
        in items: [MSPAgentTimelineItem],
        after index: Int
    ) -> Bool {
        let body = normalizedTranscriptBody(item.body)
        guard !body.isEmpty,
              body.count <= 12 else {
            return false
        }
        var candidateIndex = index + 1
        while candidateIndex < items.count {
            let candidate = items[candidateIndex]
            if candidate.kind == .user {
                return false
            }
            if candidate.kind == .assistantFinal {
                let finalBody = normalizedTranscriptBody(candidate.body)
                if finalBody != body && (finalBody.hasPrefix(body) || body.count <= 2) {
                    return true
                }
            }
            candidateIndex += 1
        }
        return false
    }

    nonisolated private static func normalizedTranscriptBody(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static let modelContextSummaryPrefix = "Another language model started to solve this problem and produced a summary"

    nonisolated private static func transcriptItemContainsModelContextSummary(
        _ item: MSPAgentTimelineItem
    ) -> Bool {
        normalizedTranscriptBody(item.body).hasPrefix(modelContextSummaryPrefix)
    }

    nonisolated private static func transcriptItemsForPersistence(
        visibleTranscript: [MSPAgentTimelineItem],
        fullTranscript: [MSPAgentTimelineItem]?,
        displayedStartIndex: Int,
        displayedBaselineCount: Int
    ) -> [MSPAgentTimelineItem] {
        guard let fullTranscript,
              displayedBaselineCount > 0,
              visibleTranscript.count >= displayedBaselineCount else {
            return visibleTranscript
        }
        let baselineCount = displayedBaselineCount
        let startIndex = displayedStartIndex
        guard startIndex >= 0,
              startIndex + baselineCount <= fullTranscript.count else {
            return visibleTranscript
        }
        for index in 0..<baselineCount {
            guard fullTranscript[startIndex + index] == visibleTranscript[index] else {
                return visibleTranscript
            }
        }
        return fullTranscript + visibleTranscript.dropFirst(baselineCount)
    }

    nonisolated private static func mergingTranscriptItems(
        anchor: [MSPAgentTimelineItem],
        visible: [MSPAgentTimelineItem]
    ) -> [MSPAgentTimelineItem] {
        guard !anchor.isEmpty else {
            return visible
        }
        guard !visible.isEmpty else {
            return anchor
        }

        let anchorSignatures = anchor.map(transcriptItemSignature)
        let visibleSignatures = visible.map(transcriptItemSignature)
        if containsContiguousSubsequence(visibleSignatures, in: anchorSignatures) {
            return anchor
        }
        if containsContiguousSubsequence(anchorSignatures, in: visibleSignatures) {
            return visible
        }

        let overlapCount = longestSuffixPrefixOverlap(
            anchorSignatures,
            visibleSignatures
        )
        if overlapCount > 0 {
            return anchor + visible.dropFirst(overlapCount)
        }

        var seen = Set(anchorSignatures)
        var merged = anchor
        for item in visible {
            let signature = transcriptItemSignature(item)
            if seen.insert(signature).inserted {
                merged.append(item)
            }
        }
        return merged
    }

    nonisolated private static func containsContiguousSubsequence(
        _ needle: [TranscriptItemSignature],
        in haystack: [TranscriptItemSignature]
    ) -> Bool {
        guard !needle.isEmpty else {
            return true
        }
        guard needle.count <= haystack.count else {
            return false
        }
        for startIndex in 0...(haystack.count - needle.count) {
            if Array(haystack[startIndex..<(startIndex + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    nonisolated private static func longestSuffixPrefixOverlap(
        _ lhs: [TranscriptItemSignature],
        _ rhs: [TranscriptItemSignature]
    ) -> Int {
        let maximumOverlap = min(lhs.count, rhs.count)
        guard maximumOverlap > 0 else {
            return 0
        }
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            if Array(lhs.suffix(count)) == Array(rhs.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private struct TranscriptItemSignature: Hashable {
        var kind: String
        var key: String
    }

    nonisolated private static func transcriptItemSignature(
        _ item: MSPAgentTimelineItem
    ) -> TranscriptItemSignature {
        let kind: String
        switch item.kind {
        case .system:
            kind = "system"
        case .user:
            kind = "user"
        case .assistantProgress:
            kind = "assistantProgress"
        case .toolCall:
            kind = "toolCall"
        case .toolResult:
            kind = "toolResult"
        case .assistantFinal:
            kind = "assistantFinal"
        case .stoppedMarker:
            kind = "stoppedMarker"
        case .error:
            kind = "error"
        }

        if item.kind == .toolCall,
           let callID = item.callID,
           !callID.isEmpty {
            return TranscriptItemSignature(kind: kind, key: "call:\(callID)")
        }
        if item.kind == .toolResult,
           let callID = item.callID,
           !callID.isEmpty {
            return TranscriptItemSignature(kind: kind, key: "call:\(callID):\(item.body)")
        }

        let key = [
            item.title,
            item.body,
            item.detail ?? "",
            item.sourceTextSelections.map(textSelectionSignature).joined(separator: "\u{1E}"),
            item.toolName ?? "",
            item.command ?? "",
            item.stdout ?? "",
            item.stderr ?? ""
        ].joined(separator: "\u{1F}")
        return TranscriptItemSignature(kind: kind, key: key)
    }

    nonisolated private static func textSelectionSignature(
        _ selection: PhotoSorterTextSelectionSnapshot
    ) -> String {
        [
            selection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines),
            selection.sourceKind.trimmingCharacters(in: .whitespacesAndNewlines),
            selection.sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            selection.sourceMessageID ?? "",
            selection.sourceMessageRole ?? "",
            selection.selectedTextOccurrenceIndexInMessage.map(String.init) ?? "",
            selection.renderedTextSegments.joined(separator: "\u{1D}")
        ].joined(separator: "\u{1E}")
    }

    private func persistActiveChatModelHistory(reason: String) async {
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask = nil
        guard activeChatSession != nil || activeChatCreationTask != nil,
              let agentRuntime else {
            return
        }
        let generation = activeChatPersistenceGeneration
        let activeChatVirtualPath = activeChatVirtualPath
        let modelHistory = modelHistoryByKeepingCurrentTurnUserInput(
            await agentRuntime.snapshotTranscriptItems()
        )
        guard activeChatPersistenceGeneration == generation,
              self.activeChatVirtualPath == activeChatVirtualPath
        else {
            recordDiagnostic("agent_chat_write_skipped", fields: [
                "reason": "model_history:\(reason)",
                "cause": "stale_active_chat"
            ])
            return
        }
        let writeTask = queueActiveChatWrite(reason: "model_history:\(reason)") { session in
            try await session.replaceModelVisibleHistoryAsync(modelHistory, reason: .replaced)
        }
        await writeTask?.value
    }

    private func persistActiveTurnModelHistoryIncrementally(
        _ currentTurnItems: [MSPAgentJSONValue],
        turnStartedAtMilliseconds: Int
    ) async {
        guard currentTurnStartedAtMilliseconds == turnStartedAtMilliseconds,
              !isTurnStopped(turnStartedAtMilliseconds),
              activeChatSession != nil || activeChatCreationTask != nil else {
            return
        }
        activeTurnLatestCurrentItemsByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] = currentTurnItems

        let previousCurrentItemCount = activeTurnCurrentItemsSnapshotItemCountByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ]
        if previousCurrentItemCount != currentTurnItems.count {
            activeChatModelHistorySnapshotTask?.cancel()
            activeChatModelHistorySnapshotTask = nil
            await persistLatestActiveTurnModelHistorySnapshot(
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                reason: "active_turn_incremental"
            )
            return
        }

        scheduleActiveTurnModelHistorySnapshot(
            turnStartedAtMilliseconds: turnStartedAtMilliseconds,
            reason: "active_turn_streaming"
        )
    }

    private func scheduleActiveTurnModelHistorySnapshot(
        turnStartedAtMilliseconds: Int,
        reason: String
    ) {
        guard activeChatSession != nil || activeChatCreationTask != nil else {
            return
        }
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.activeTurnModelHistoryStreamingSnapshotDelayNanoseconds
            )
            guard !Task.isCancelled else {
                return
            }
            await self?.persistLatestActiveTurnModelHistorySnapshot(
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                reason: reason
            )
        }
    }

    private func persistLatestActiveTurnModelHistorySnapshot(
        turnStartedAtMilliseconds: Int,
        reason: String
    ) async {
        guard let currentTurnItems = activeTurnLatestCurrentItemsByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] else {
            return
        }
        let modelHistory = fullModelHistoryForActiveTurnSnapshot(
            currentTurnItems,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds
        )
        guard !modelHistory.isEmpty else {
            return
        }
        activeTurnLatestModelHistoryByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] = modelHistory
        await persistActiveTurnModelHistorySnapshot(
            modelHistory,
            currentTurnItemCount: currentTurnItems.count,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds,
            reason: reason
        )
    }

    private func persistActiveTurnModelHistorySnapshot(
        _ modelHistory: [MSPAgentJSONValue],
        currentTurnItemCount: Int?,
        turnStartedAtMilliseconds: Int,
        reason: String
    ) async {
        guard currentTurnStartedAtMilliseconds == turnStartedAtMilliseconds,
              !isTurnStopped(turnStartedAtMilliseconds),
              activeChatSession != nil || activeChatCreationTask != nil else {
            return
        }
        let generation = activeChatPersistenceGeneration
        let activeChatVirtualPath = activeChatVirtualPath
        let writeTask = queueActiveChatModelHistory(
            reason: reason,
            modelHistory: modelHistory
        )
        await writeTask?.value
        guard currentTurnStartedAtMilliseconds == turnStartedAtMilliseconds,
              activeChatPersistenceGeneration == generation,
              self.activeChatVirtualPath == activeChatVirtualPath else {
            recordDiagnostic("agent_chat_write_skipped", fields: [
                "reason": "model_history:\(reason)",
                "cause": "stale_active_turn_after_write"
            ])
            return
        }
        activeTurnModelHistorySnapshotItemCountByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] = modelHistory.count
        if let currentTurnItemCount {
            activeTurnCurrentItemsSnapshotItemCountByStartedAtMilliseconds[
                turnStartedAtMilliseconds
            ] = currentTurnItemCount
        }
        recordDiagnostic("agent_chat_model_history_incremental_saved", fields: [
            "reason": reason,
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
            "item_count": "\(modelHistory.count)"
        ])
    }

    private func fullModelHistoryForActiveTurnSnapshot(
        _ currentTurnItems: [MSPAgentJSONValue],
        turnStartedAtMilliseconds: Int
    ) -> [MSPAgentJSONValue] {
        let prefix = activeTurnModelHistoryPrefixItemsByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] ?? []
        if !prefix.isEmpty,
           currentTurnItems.count >= prefix.count,
           Array(currentTurnItems.prefix(prefix.count)) == prefix {
            return currentTurnItems
        }
        if currentTurnItems.isEmpty,
           let currentUserItems = activeTurnUserModelItemsByStartedAtMilliseconds[
            turnStartedAtMilliseconds
           ] {
            return prefix + currentUserItems
        }
        return prefix + currentTurnItems
    }

    private func latestActiveTurnModelHistory(
        turnStartedAtMilliseconds: Int
    ) -> [MSPAgentJSONValue]? {
        if let currentTurnItems = activeTurnLatestCurrentItemsByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ] {
            return fullModelHistoryForActiveTurnSnapshot(
                currentTurnItems,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        }
        return activeTurnLatestModelHistoryByStartedAtMilliseconds[
            turnStartedAtMilliseconds
        ]
    }

    @discardableResult
    private func queueActiveChatModelHistory(
        reason: String,
        modelHistory: [MSPAgentJSONValue]
    ) -> Task<Void, Never>? {
        guard activeChatSession != nil || activeChatCreationTask != nil else {
            return nil
        }
        return queueActiveChatWrite(reason: "model_history:\(reason)") { session in
            try await session.replaceModelVisibleHistoryAsync(modelHistory, reason: .replaced)
        }
    }

    private func modelHistoryByKeepingCurrentTurnUserInput(
        _ modelHistory: [MSPAgentJSONValue]
    ) -> [MSPAgentJSONValue] {
        guard let turnStartedAt = currentTurnStartedAtMilliseconds,
              let prefixCount = activeTurnModelHistoryPrefixCountByStartedAtMilliseconds[turnStartedAt],
              modelHistory.count <= prefixCount,
              let currentUserItems = activeTurnUserModelItemsByStartedAtMilliseconds[turnStartedAt],
              !currentUserItems.isEmpty else {
            return modelHistory
        }
        return modelHistory + currentUserItems
    }

    nonisolated static func modelHistoryByPreservingActiveTurnHistoryForFailedTurn(
        finalModelHistory: [MSPAgentJSONValue],
        latestActiveTurnModelHistory: [MSPAgentJSONValue]?,
        status: String
    ) -> [MSPAgentJSONValue] {
        guard status != "completed",
              let latestActiveTurnModelHistory,
              latestActiveTurnModelHistory.count > finalModelHistory.count else {
            return finalModelHistory
        }
        return latestActiveTurnModelHistory
    }

    @discardableResult
    private func queueActiveChatWrite(
        reason: String,
        operation: @escaping @Sendable (MSPAgentChatSession) async throws -> Void
    ) -> Task<Void, Never>? {
        let existingSession = activeChatSession
        let creationTask = activeChatCreationTask
        let generation = activeChatPersistenceGeneration
        let expectedVirtualPath = activeChatVirtualPath
        guard existingSession != nil || creationTask != nil else {
            recordDiagnostic("agent_chat_write_skipped", fields: [
                "reason": reason,
                "cause": "no_active_session"
            ])
            return nil
        }

        let previousTask = activeChatWriteTask
        let diagnosticsLog = diagnosticsLog
        let task = Task.detached(priority: .utility) { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else {
                await diagnosticsLog.record("agent_chat_write_skipped", fields: [
                    "reason": reason,
                    "cause": "cancelled"
                ])
                return
            }
            let isCurrentBeforeSession = await MainActor.run { [weak self] in
                guard let self else {
                    return false
                }
                return self.activeChatPersistenceGeneration == generation
                    && self.activeChatVirtualPath == expectedVirtualPath
            }
            guard isCurrentBeforeSession else {
                await diagnosticsLog.record("agent_chat_write_skipped", fields: [
                    "reason": reason,
                    "cause": "stale_active_chat"
                ])
                return
            }

            let session: MSPAgentChatSession
            if let existingSession {
                session = existingSession
            } else if let creationTask {
                switch await creationTask.value {
                case .success(let createdSession):
                    session = createdSession
                case .failure(let message):
                    await diagnosticsLog.record("agent_chat_write_failed", fields: [
                        "reason": reason,
                        "cause": "session_create_failed",
                        "message": message
                    ])
                    return
                }
            } else {
                await diagnosticsLog.record("agent_chat_write_skipped", fields: [
                    "reason": reason,
                    "cause": "no_active_session"
                ])
                return
            }
            let isCurrentBeforeWrite = await MainActor.run { [weak self] in
                guard let self else {
                    return false
                }
                return self.activeChatPersistenceGeneration == generation
                    && self.activeChatVirtualPath == expectedVirtualPath
            }
            guard isCurrentBeforeWrite else {
                await diagnosticsLog.record("agent_chat_write_skipped", fields: [
                    "reason": reason,
                    "cause": "stale_active_chat"
                ])
                return
            }

            do {
                try await operation(session)
                await diagnosticsLog.record("agent_chat_write_saved", fields: [
                    "reason": reason
                ])
            } catch {
                await diagnosticsLog.record("agent_chat_write_failed", fields: [
                    "reason": reason,
                    "message": error.localizedDescription
                ])
            }
        }
        activeChatWriteTask = task
        return task
    }

    private func appendActiveChatTurnStarted(_ turnID: UUID) -> Task<Void, Never>? {
        queueActiveChatWrite(reason: "turn_started") { session in
            try await session.appendTurnStartedAsync(turnID: turnID.uuidString)
        }
    }

    private func observeActiveChatWrite(
        _ writeTask: Task<Void, Never>?,
        reason: String
    ) {
        guard let writeTask else {
            return
        }
        Task { [weak self] in
            await writeTask.value
            self?.recordDiagnostic("agent_chat_write_observed", fields: [
                "reason": reason
            ])
        }
    }

    private func appendActiveChatTurnCompleted(_ turnID: UUID, status: String) -> Task<Void, Never>? {
        queueActiveChatWrite(reason: "turn_completed:\(status)") { session in
            try await session.appendTurnCompletedAsync(
                turnID: turnID.uuidString,
                status: status
            )
        }
    }

    private func markActiveChatTurnAborted(_ turnID: UUID) -> Task<Void, Never>? {
        queueActiveChatWrite(reason: "turn_aborted") { session in
            _ = try await session.markOpenTurnsAbortedAsync(reason: "interrupted")
        }
    }

    nonisolated private static func nonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func requestSyncPhotoLibraryWorkspaceChanges() {
        let summary = photoLibraryMount.photoLibraryWorkspaceChangeSummary
        photoLibraryWorkspaceChangeSummary = summary
        photoLibraryWorkspaceSyncError = nil
        guard summary.hasChanges, !isSyncingPhotoLibraryWorkspaceChanges else {
            return
        }
        photoLibraryWorkspaceSyncConfirmation = nil
        isSyncingPhotoLibraryWorkspaceChanges = true
        let photoLibraryMount = photoLibraryMount

        Task {
            do {
                let changeSet = try await Task.detached(priority: .userInitiated) {
                    try await photoLibraryMount.preparePhotoLibraryWorkspaceSyncChangeSet()
                }.value
                photoLibraryWorkspaceSyncConfirmation = PhotoLibraryWorkspaceSyncConfirmation(
                    summary: summary,
                    changeSet: changeSet
                )
            } catch {
                photoLibraryWorkspaceSyncError = error.localizedDescription
            }
            isSyncingPhotoLibraryWorkspaceChanges = false
        }
    }

    func confirmSyncPhotoLibraryWorkspaceChanges() {
        photoLibraryWorkspaceSyncConfirmation = nil
        guard !isSyncingPhotoLibraryWorkspaceChanges else {
            return
        }
        isSyncingPhotoLibraryWorkspaceChanges = true
        photoLibraryWorkspaceSyncError = nil
        let photoLibraryMount = photoLibraryMount

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await photoLibraryMount.applyPendingWorkspaceChangesToPhotoLibrary()
                }.value
                photoLibraryWorkspaceChangeSummary = photoLibraryMount.photoLibraryWorkspaceChangeSummary
                Task {
                    await refreshWorkspace()
                }
            } catch {
                photoLibraryWorkspaceSyncError = error.localizedDescription
            }
            isSyncingPhotoLibraryWorkspaceChanges = false
        }
    }

    func restoreWorkspaceTrashFromPreview(_ preview: WorkspaceMediaPreview) {
        guard preview.canRestoreFromTrash, !preview.isRestoringFromTrash else {
            return
        }
        preview.isRestoringFromTrash = true
        Task {
            do {
                try photoLibraryMount.restoreWorkspaceTrash(displayPath: preview.path)
                photoLibraryWorkspaceChangeSummary = photoLibraryMount.photoLibraryWorkspaceChangeSummary
                workspaceMediaPreview = nil
                await refreshWorkspace()
            } catch {
                preview.message = error.localizedDescription
                preview.isRestoringFromTrash = false
            }
        }
    }

    func deleteWorkspaceChatPackage(_ node: WorkspaceFileNode) {
        guard node.isChatPackage else {
            return
        }
        guard !isRunningAgent else {
            recordDiagnostic("agent_chat_delete_skipped", fields: [
                "path": node.path,
                "reason": "agent_running"
            ])
            return
        }
        guard let runtime else {
            appendRuntimeError("删除对话失败：Workspace 还没有准备好。")
            return
        }

        let deletesActiveChat = activeChatVirtualPath == node.path
        if deletesActiveChat {
            activeChatPersistenceGeneration = UUID()
            chatTranscriptSnapshotTask?.cancel()
            chatTranscriptSnapshotTask = nil
            activeChatModelHistorySnapshotTask?.cancel()
            activeChatModelHistorySnapshotTask = nil
            activeChatCreationTask?.cancel()
            activeChatWriteTask?.cancel()
            activeChatCreationTask = nil
            activeChatWriteTask = nil
        }

        Task {
            do {
                try runtime.removeWorkspaceItem(node.path, recursive: true)
                if deletesActiveChat {
                    startNewChat()
                }
                workspaceTreeRevision += 1
                workspaceTrashRevision += 1
                recordDiagnostic("agent_chat_deleted_to_trash", fields: [
                    "path": node.path,
                    "active_chat": "\(deletesActiveChat)"
                ])
                await refreshWorkspace()
                await refreshWorkspaceTrashNow()
            } catch {
                appendRuntimeError("删除对话失败：\(error.localizedDescription)")
            }
        }
    }

    func refreshWorkspaceTrash() {
        Task {
            await refreshWorkspaceTrashNow()
        }
    }

    func emptyWorkspaceTrash() {
        guard !isEmptyingWorkspaceTrash, !isRestoringWorkspaceTrash else {
            return
        }
        guard let runtime else {
            workspaceTrashErrorMessage = "Workspace 还没有准备好。"
            return
        }

        isEmptyingWorkspaceTrash = true
        workspaceTrashErrorMessage = nil
        Task {
            do {
                let removedCount = try runtime.emptyWorkspaceTrash(
                    authorization: .userConfirmed()
                )
                workspaceTrashRevision += 1
                recordDiagnostic("workspace_trash_emptied", fields: [
                    "removed_count": "\(removedCount)"
                ])
                await refreshWorkspaceTrashNow()
            } catch {
                workspaceTrashErrorMessage = error.localizedDescription
                recordDiagnostic("workspace_trash_empty_failed", fields: [
                    "message": error.localizedDescription
                ])
            }
            isEmptyingWorkspaceTrash = false
        }
    }

    func restoreWorkspaceTrashItem(_ node: WorkspaceFileNode) {
        guard !isRestoringWorkspaceTrash, !isEmptyingWorkspaceTrash else {
            return
        }
        guard let runtime else {
            workspaceTrashErrorMessage = "Workspace 还没有准备好。"
            return
        }

        isRestoringWorkspaceTrash = true
        workspaceTrashErrorMessage = nil
        Task {
            do {
                let summaries = try runtime.restoreWorkspaceTrash(at: node.path)
                workspaceTreeRevision += 1
                workspaceTrashRevision += 1
                recordDiagnostic("workspace_trash_item_restored", fields: [
                    "path": node.path,
                    "restored_count": "\(summaries.count)"
                ])
                await refreshWorkspace()
                await refreshWorkspaceTrashNow()
            } catch {
                workspaceTrashErrorMessage = error.localizedDescription
                recordDiagnostic("workspace_trash_item_restore_failed", fields: [
                    "path": node.path,
                    "message": error.localizedDescription
                ])
            }
            isRestoringWorkspaceTrash = false
        }
    }

    func restoreAllWorkspaceTrash() {
        guard !isRestoringWorkspaceTrash, !isEmptyingWorkspaceTrash else {
            return
        }
        guard let runtime else {
            workspaceTrashErrorMessage = "Workspace 还没有准备好。"
            return
        }

        isRestoringWorkspaceTrash = true
        workspaceTrashErrorMessage = nil
        Task {
            do {
                let summaries = try runtime.restoreAllWorkspaceTrash()
                workspaceTreeRevision += 1
                workspaceTrashRevision += 1
                recordDiagnostic("workspace_trash_all_restored", fields: [
                    "restored_count": "\(summaries.count)"
                ])
                await refreshWorkspace()
                await refreshWorkspaceTrashNow()
            } catch {
                workspaceTrashErrorMessage = error.localizedDescription
                recordDiagnostic("workspace_trash_all_restore_failed", fields: [
                    "message": error.localizedDescription
                ])
            }
            isRestoringWorkspaceTrash = false
        }
    }

    func loadWorkspaceChildren(for path: String) async throws -> [WorkspaceFileNode] {
        guard let runtime else {
            return []
        }
        return try runtime.snapshotWorkspace(
            path: path,
            maxDepth: 1,
            maxEntriesPerDirectory: Self.workspaceTreeEntriesPerDirectoryLimit
        )
    }

    func loadWorkspaceDirectoryPage(for path: String, offset: Int) async throws -> WorkspaceDirectoryPage {
        guard let runtime else {
            return WorkspaceDirectoryPage(nodes: [], hasMore: false)
        }
        return try await runtime.snapshotWorkspacePage(
            path: path,
            offset: offset,
            limit: Self.workspaceTreePageSize
        )
    }

    func loadWorkspaceThumbnail(
        for node: WorkspaceFileNode,
        targetSize: CGSize
    ) async -> WorkspaceFileThumbnail? {
        guard let runtime else {
            return nil
        }
        return await runtime.thumbnail(
            for: node,
            targetSize: targetSize,
            cacheVersion: workspaceCacheVersionToken
        )
    }

    @discardableResult
    func reloadModelConfiguration() -> MSPModelConfiguration {
        let loadedConfiguration = loadModelConfiguration()
        modelConfiguration = loadedConfiguration
        clearContextUsageIfModelChanged(to: loadedConfiguration)
        return loadedConfiguration
    }

    @discardableResult
    func saveModelConfiguration() -> Bool {
        let normalized = modelConfiguration.normalized()
        do {
            try saveModelConfigurationHandler(normalized)
            modelConfiguration = loadModelConfiguration()
            clearContextUsageIfModelChanged(to: modelConfiguration)
            modelConfigurationSaveError = nil
            return true
        } catch {
            modelConfiguration = normalized
            clearContextUsageIfModelChanged(to: normalized)
            modelConfigurationSaveError = error.localizedDescription
            return false
        }
    }

    func saveCodexOAuthConfiguration() {
        codexOAuthConfiguration = codexOAuthConfiguration.applyingTokenMetadata()
        MSPCodexOAuthConfigurationStore.save(codexOAuthConfiguration)
        if !codexOAuthConfiguration.hasStoredCredential {
            codexOAuthQuota = nil
        }
    }

    func selectAgentAccessMode(_ mode: PhotoSorterAgentAccessMode) {
        guard mode != agentAccessMode else {
            return
        }
        agentAccessMode = mode
        agentAccessModeState.update(mode)
        saveAgentAccessModeHandler(mode)
        startPlaceCachePreheatIfAllowed()
        recordDiagnostic("agent_access_mode_changed", fields: [
            "agent_access_mode": mode.rawValue
        ])
    }

    func selectSensitiveReadPolicy(_ policy: PhotoSorterSensitiveReadPolicy) {
        guard policy != sensitiveReadPolicy else {
            return
        }
        sensitiveReadPolicy = policy
        sensitiveReadPolicyState.update(policy)
        saveSensitiveReadPolicyHandler(policy)
        recordDiagnostic("sensitive_read_policy_changed", fields: [
            "sensitive_read_policy": policy.rawValue
        ])
    }

    func allowMediaViewAuthorization(
        selectedItemIDs: Set<UUID>,
        note: String = "",
        reviewedItems: [PhotoSorterMediaViewItem] = [],
        skippedFailures: [PhotoSorterMediaViewFailure] = []
    ) {
        guard let continuation = mediaViewAuthorizationContinuation else {
            mediaViewAuthorizationPrompt = nil
            return
        }
        let prompt = mediaViewAuthorizationPrompt
        let effectiveReviewedItems = reviewedItems.isEmpty && !(prompt?.items.isEmpty ?? true)
            ? prompt?.items ?? []
            : reviewedItems
        mediaViewAuthorizationContinuation = nil
        mediaViewAuthorizationPrompt = nil
        recordDiagnostic("media_view_authorization_allowed", fields: [
            "selected": "\(selectedItemIDs.count)",
            "reviewed": "\(effectiveReviewedItems.count)",
            "skipped_failures": "\(skippedFailures.count)"
        ])
        continuation.resume(returning: PhotoSorterMediaViewAuthorizationDecision(
            allowedItemIDs: selectedItemIDs,
            note: note,
            reviewedItems: effectiveReviewedItems,
            skippedFailures: skippedFailures
        ))
    }

    func denyMediaViewAuthorization() {
        guard let continuation = mediaViewAuthorizationContinuation else {
            mediaViewAuthorizationPrompt = nil
            return
        }
        mediaViewAuthorizationContinuation = nil
        mediaViewAuthorizationPrompt = nil
        continuation.resume(returning: .denyAll)
    }

    func cancelMediaViewAuthorization(
        reviewedItems: [PhotoSorterMediaViewItem] = [],
        skippedFailures: [PhotoSorterMediaViewFailure] = []
    ) {
        guard let continuation = mediaViewAuthorizationContinuation else {
            mediaViewAuthorizationPrompt = nil
            return
        }
        let prompt = mediaViewAuthorizationPrompt
        let effectiveReviewedItems = reviewedItems.isEmpty && !(prompt?.items.isEmpty ?? true)
            ? prompt?.items ?? []
            : reviewedItems
        mediaViewAuthorizationContinuation = nil
        mediaViewAuthorizationPrompt = nil
        recordDiagnostic("media_view_authorization_cancelled", fields: [
            "reviewed": "\(effectiveReviewedItems.count)",
            "skipped_failures": "\(skippedFailures.count)"
        ])
        continuation.resume(returning: PhotoSorterMediaViewAuthorizationDecision(
            allowedItemIDs: [],
            cancelled: true,
            reviewedItems: effectiveReviewedItems,
            skippedFailures: skippedFailures
        ))
    }

    func recordTranscriptRenderedProbe(_ probe: ExampleChatTranscriptVisibleTextProbe) {
        guard Self.transcriptVisibleTextProbeEnabled() else {
            return
        }
        let normalizedText = probe.normalizedVisibleText
        let fullTextContainsShellJSONKeys = Self.containsStructuredShellJSONLeak(in: normalizedText)
        let containsToolStdoutSentinel = normalizedText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let containsToolStderrSentinel = normalizedText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let mainFlowText = probe.mainFlowNormalizedText
        let mainFlowContainsToolStdoutSentinel = mainFlowText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let mainFlowContainsToolStderrSentinel = mainFlowText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let mainFlowContainsCommandNotFound = mainFlowText.contains("command not found")
        let shellOutputText = probe.shellExecutionOutputNormalizedText
        let shellOutputContainsToolStdoutSentinel = shellOutputText.contains("MSP_HIDDEN_TOOL_STDOUT_SENTINEL")
        let shellOutputContainsToolStderrSentinel = shellOutputText.contains("MSP_HIDDEN_TOOL_STDERR_SENTINEL")
        let shellOutputContainsCommandNotFound = shellOutputText.contains("command not found")
        let shellOutputContainsShellJSONKeys = Self.containsStructuredShellJSONLeak(in: shellOutputText)
        let normalizedTextExcludingUserMessages = normalizedProbeTextExcludingUserMessages(normalizedText)
        let containsExecCommandOutsideUserMessages = normalizedTextExcludingUserMessages.contains("exec_command")
        let internalToolTitleText = Self.normalizedProbeText([
            probe.chatSupportLineTitles.joined(separator: " "),
            probe.chatTerminalSupportLineTitles.joined(separator: " "),
            probe.chatToolActivityItemTitles.joined(separator: " "),
            probe.chatProcessingTitles.joined(separator: " "),
            probe.chatToolActivityTitles.joined(separator: " ")
        ].joined(separator: " "))
        let containsInternalShellToolName = internalToolTitleText.contains("workspace.shell")
            || internalToolTitleText.contains("readex.shell")
            || internalToolTitleText.contains("exec_command")
            || normalizedTextExcludingUserMessages.contains("workspace.shell")
            || normalizedTextExcludingUserMessages.contains("readex.shell")
        let snippetLimit = 700
        let snippet = normalizedText.count > snippetLimit
            ? String(normalizedText.prefix(snippetLimit))
            : normalizedText
        e2eEventLog?.record("transcript_visible_text_probe", fields: [
            "text_length": "\(probe.visibleText.count)",
            "normalized_text_length": "\(normalizedText.count)",
            "normalized_text_excluding_user_messages_length": "\(normalizedTextExcludingUserMessages.count)",
            "contains_exec_command": "\(normalizedText.contains("exec_command"))",
            "contains_exec_command_outside_user_messages": "\(containsExecCommandOutsideUserMessages)",
            "contains_command_not_found": "\(normalizedText.contains("command not found"))",
            "contains_shell_json_keys": "\(shellOutputContainsShellJSONKeys)",
            "full_text_contains_shell_json_keys": "\(fullTextContainsShellJSONKeys)",
            "contains_tool_stdout_sentinel": "\(containsToolStdoutSentinel)",
            "contains_tool_stderr_sentinel": "\(containsToolStderrSentinel)",
            "main_flow_contains_tool_stdout_sentinel": "\(mainFlowContainsToolStdoutSentinel)",
            "main_flow_contains_tool_stderr_sentinel": "\(mainFlowContainsToolStderrSentinel)",
            "main_flow_contains_command_not_found": "\(mainFlowContainsCommandNotFound)",
            "shell_output_contains_tool_stdout_sentinel": "\(shellOutputContainsToolStdoutSentinel)",
            "shell_output_contains_tool_stderr_sentinel": "\(shellOutputContainsToolStderrSentinel)",
            "shell_output_contains_command_not_found": "\(shellOutputContainsCommandNotFound)",
            "contains_internal_shell_tool_name": "\(containsInternalShellToolName)",
            "chat_transcript_theme": probe.chatTranscriptTheme,
            "message_roles": probe.messageLayouts
                .map(\.role)
                .joined(separator: ","),
            "message_layouts": Self.messageLayoutProbeText(probe.messageLayouts),
            "visible_message_role_texts": probe.visibleMessageRoleTexts.joined(separator: " | "),
            "chat_support_line_titles": probe.chatSupportLineTitles.joined(separator: " | "),
            "chat_terminal_support_line_titles": probe.chatTerminalSupportLineTitles.joined(separator: " | "),
            "chat_tool_activity_item_titles": probe.chatToolActivityItemTitles.joined(separator: " | "),
            "chat_processing_titles": probe.chatProcessingTitles.joined(separator: " | "),
            "internal_tool_title_text": internalToolTitleText,
            "chat_processing_class_names": probe.chatProcessingClassNames.joined(separator: " | "),
            "chat_processing_duration_texts": probe.chatProcessingDurationTexts.joined(separator: " | "),
            "chat_processing_duration_seconds": probe.chatProcessingDurationSeconds
                .map(String.init)
                .joined(separator: ","),
            "chat_tool_activity_titles": probe.chatToolActivityTitles.joined(separator: " | "),
            "live_chat_processing_block_count": "\(probe.liveExampleChatProcessingBlockCount)",
            "terminal_command_icon_count": "\(probe.terminalCommandIconCount)",
            "tool_activity_details_count": "\(probe.toolActivityDetailsCount)",
            "tool_activity_disclosure_count": "\(probe.toolActivityDisclosureCount)",
            "shell_execution_disclosure_count": "\(probe.shellExecutionDisclosureCount)",
            "shell_execution_output_block_count": "\(probe.shellExecutionOutputBlockCount)",
            "katex_element_count": "\(probe.katexElementCount)",
            "highlighted_code_element_count": "\(probe.highlightedCodeElementCount)",
            "markdown_code_block_count": "\(probe.markdownCodeBlockCount)",
            "captured_at_milliseconds": probe.capturedAtMilliseconds.map(String.init) ?? "",
            "snippet": snippet
        ])
    }

    private func normalizedProbeTextExcludingUserMessages(_ text: String) -> String {
        var remainingText = text
        for item in transcript where item.kind == .user {
            let userText = Self.normalizedProbeText(item.body)
            guard !userText.isEmpty else {
                continue
            }
            remainingText = remainingText.replacingOccurrences(of: userText, with: " ")
        }
        return Self.normalizedProbeText(remainingText)
    }

    nonisolated static func containsStructuredShellJSONLeak(in text: String) -> Bool {
        let normalizedText = normalizedProbeText(text)
        guard normalizedText.contains("\"stdout\""),
              normalizedText.contains("\"stderr\"") else {
            return false
        }
        return normalizedText.contains("\"exit_code\"")
            || normalizedText.contains("\"exitCode\"")
            || normalizedText.contains("\"internal_exit_code\"")
    }

    private nonisolated static func normalizedProbeText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func messageLayoutProbeText(
        _ layouts: [ExampleChatTranscriptVisibleTextProbe.MessageLayout]
    ) -> String {
        layouts
            .map { layout in
                [
                    layout.role,
                    layout.dataRole,
                    Self.roundedProbeNumber(layout.left),
                    Self.roundedProbeNumber(layout.right),
                    Self.roundedProbeNumber(layout.width),
                    Self.roundedProbeNumber(layout.centerX)
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    private static func roundedProbeNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    func startCodexOAuthLogin() {
        guard !isStartingCodexOAuthLogin else {
            return
        }
        codexOAuthQuotaRefreshToken = nil
        isRefreshingCodexOAuthQuota = false
        isStartingCodexOAuthLogin = true
        codexOAuthQuota = nil
        codexOAuthConfiguration.lastLoginStatus = .signingIn
        codexOAuthConfiguration.lastStatusMessage = "正在打开 Codex OAuth 登录页面…"
        codexOAuthConfiguration.lastCheckedAt = .now

        Task {
            let result = await codexOAuthLoginService.startLogin(preserving: codexOAuthConfiguration)
            applyCodexOAuthLoginResult(result)
            isStartingCodexOAuthLogin = false
            if result.configuration.lastLoginStatus == .signedIn {
                refreshCodexOAuthQuota(isAutomatic: true)
            }
        }
    }

    func clearCodexOAuthSession() {
        codexOAuthLoginService.cancelLogin()
        codexOAuthQuotaRefreshToken = nil
        isStartingCodexOAuthLogin = false
        isRefreshingCodexOAuthQuota = false
        codexOAuthConfiguration = .empty
        codexOAuthQuota = nil
        MSPCodexOAuthConfigurationStore.clear()
    }

    func refreshCodexOAuthQuota(isAutomatic: Bool = false) {
        saveCodexOAuthConfiguration()
        let configuration = codexOAuthConfiguration.normalized()
        guard configuration.hasStoredCredential else {
            if !isAutomatic {
                codexOAuthQuota = MSPCodexOAuthQuotaResult(
                    status: .signedOut,
                    message: "请先登录 Codex，再刷新额度。",
                    email: nil,
                    planType: nil,
                    windows: [],
                    checkedAt: .now
                )
            }
            return
        }

        codexOAuthQuotaRefreshToken = UUID()
        let refreshToken = codexOAuthQuotaRefreshToken
        isRefreshingCodexOAuthQuota = true

        Task {
            let freshConfiguration = await codexOAuthLoginService.refreshAccessToken(using: configuration)
            if freshConfiguration != codexOAuthConfiguration.normalized() {
                codexOAuthConfiguration = freshConfiguration
                MSPCodexOAuthConfigurationStore.save(freshConfiguration)
            }
            guard freshConfiguration.lastLoginStatus != .failed else {
                guard codexOAuthQuotaRefreshToken == refreshToken else { return }
                codexOAuthQuota = MSPCodexOAuthQuotaResult(
                    status: .failed,
                    message: freshConfiguration.lastStatusMessage,
                    email: Self.nilIfEmpty(freshConfiguration.email),
                    planType: Self.nilIfEmpty(freshConfiguration.planType),
                    windows: [],
                    checkedAt: .now
                )
                isRefreshingCodexOAuthQuota = false
                codexOAuthQuotaRefreshToken = nil
                return
            }

            let result = await codexOAuthQuotaService.refreshQuota(using: freshConfiguration)
            guard codexOAuthQuotaRefreshToken == refreshToken else { return }
            applyCodexOAuthQuotaResult(result)
            isRefreshingCodexOAuthQuota = false
            codexOAuthQuotaRefreshToken = nil
        }
    }

    private func runAgentTurn(
        _ message: String,
        textSelections: [PhotoSorterTextSelectionSnapshot] = [],
        turnStartedAtMilliseconds: Int,
        turnID: UUID,
        turnStartedWriteTask: Task<Void, Never>?
    ) async {
        guard let agentRuntime else {
            recordDiagnostic("agent_turn_not_started", fields: [
                "reason": "agent_runtime_unavailable",
                "turn_started_at_ms": "\(turnStartedAtMilliseconds)"
            ])
            if currentAgentTurnID == turnID {
                currentAgentTurnID = nil
                currentAgentTurnTask = nil
            }
            return
        }

        let accessMode = agentAccessMode
        let sensitivePolicy = sensitiveReadPolicy
        isRunningAgent = true
        activePlanProgressUpdate = nil
        streamingAssistantProgressItemID = nil
        streamingFinalItemID = nil
        pendingFinalAnswerProvenanceFields = nil
        activeContextCompactionProgressItemIDByCompactionID.removeAll(keepingCapacity: true)
        resetTranscriptStreamingDeltas()
        pendingToolPreparationItemIDs.removeAll(keepingCapacity: true)
        activeToolStartedAtMillisecondsByCallID.removeAll(keepingCapacity: true)
        activeExecCommandCallIDBySessionID.removeAll(keepingCapacity: true)
        activeExecSessionIDByCallID.removeAll(keepingCapacity: true)
        activeWriteStdinParentCallIDByCallID.removeAll(keepingCapacity: true)
        currentTurnStartedAtMilliseconds = turnStartedAtMilliseconds
        let modelHistoryPrefixItems = await agentRuntime.snapshotTranscriptItems()
        activeTurnModelHistoryPrefixItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] =
            modelHistoryPrefixItems
        activeTurnModelHistoryPrefixCountByStartedAtMilliseconds[turnStartedAtMilliseconds] =
            modelHistoryPrefixItems.count
        recordDiagnostic("agent_turn_start", fields: [
            "prompt_length": "\(message.count)",
            "text_selection_count": "\(textSelections.count)",
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
            "agent_access_mode": accessMode.rawValue,
            "sensitive_read_policy": sensitivePolicy.rawValue
        ])
        observeActiveChatWrite(
            turnStartedWriteTask,
            reason: "turn_started_nonblocking"
        )
        persistCurrentUserModelInputIfNeeded(
            userMessage: message,
            textSelections: textSelections,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds
        )
        await refreshCodexOAuthCredentialForAgentTurnIfNeeded()
        recordDiagnostic("agent_turn_credential_ready", fields: modelConfigurationDiagnosticFields())
        guard !Task.isCancelled,
              !isTurnStopped(turnStartedAtMilliseconds) else {
            cleanupFinishedAgentTurnIfCurrent(turnID: turnID)
            return
        }
        await agentRuntime.runTurn(
            userMessage: message,
            textSelections: textSelections,
            configuration: modelConfiguration,
            codexOAuthConfiguration: codexOAuthConfiguration,
            agentAccessMode: accessMode,
            sensitiveReadPolicy: sensitivePolicy,
            onRequestBuilt: { [weak self] requestBody in
                self?.handleModelRequestBuilt(
                    requestBody,
                    turnStartedAtMilliseconds: turnStartedAtMilliseconds
                )
            },
            onTranscriptSnapshotUpdated: { [weak self] items in
                await self?.persistActiveTurnModelHistoryIncrementally(
                    items,
                    turnStartedAtMilliseconds: turnStartedAtMilliseconds
                )
            },
            onEvent: { [weak self] event in
                self?.handle(event, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
            },
            onRuntimeError: { [weak self] text in
                self?.handleRuntimeError(text, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
            }
        )
        recordDiagnostic("agent_turn_runtime_returned", fields: [
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
            "was_stopped": "\(isTurnStopped(turnStartedAtMilliseconds))"
        ])
        guard !isTurnStopped(turnStartedAtMilliseconds) else {
            await persistActiveChatModelHistory(reason: "agent_turn_stopped_returned")
            await persistActiveChatTranscriptSnapshot(reason: "agent_turn_stopped_returned")
            cleanupFinishedAgentTurnIfCurrent(turnID: turnID)
            await refreshWorkspace()
            return
        }
        guard currentAgentTurnID == turnID else {
            return
        }
        let didRuntimeError = failedTurnStartedAtMilliseconds.remove(turnStartedAtMilliseconds) != nil
        if didRuntimeError {
            await finishCurrentAgentTurn(
                turnID: turnID,
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                status: "failed",
                diagnosticName: "agent_turn_failed",
                transcriptSnapshotReason: "agent_turn_failed",
                modelHistoryReason: "agent_turn_failed"
            )
            return
        }
        await finishCurrentAgentTurn(
            turnID: turnID,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds,
            status: "completed",
            diagnosticName: "agent_turn_finished",
            transcriptSnapshotReason: "agent_turn_finished",
            modelHistoryReason: "agent_turn_finished"
        )
    }

    private func finishCurrentAgentTurn(
        turnID: UUID,
        turnStartedAtMilliseconds: Int,
        status: String,
        diagnosticName: String,
        transcriptSnapshotReason: String,
        modelHistoryReason: String
    ) async {
        recordStreamTrace("vm.finish_turn_begin", fields: [
            "status": status,
            "pending_tool_output_count": "\(pendingToolOutputDeltas.count)"
        ])
        flushTranscriptStreamingDeltas()
        recordStreamTrace("vm.finish_turn_after_streaming", fields: [
            "status": status
        ])
        finishCurrentTurn()
        let capturedModelHistory: [MSPAgentJSONValue]?
        if let agentRuntime {
            let finalModelHistory = modelHistoryByKeepingCurrentTurnUserInput(
                await agentRuntime.snapshotTranscriptItems()
            )
            let latestActiveTurnModelHistory = latestActiveTurnModelHistory(
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
            capturedModelHistory = Self.modelHistoryByPreservingActiveTurnHistoryForFailedTurn(
                finalModelHistory: finalModelHistory,
                latestActiveTurnModelHistory: latestActiveTurnModelHistory,
                status: status
            )
            if let capturedModelHistory,
               capturedModelHistory != finalModelHistory {
                recordDiagnostic("agent_chat_model_history_preserved_after_failure", fields: [
                    "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
                    "final_item_count": "\(finalModelHistory.count)",
                    "preserved_item_count": "\(capturedModelHistory.count)"
                ])
            }
        } else {
            capturedModelHistory = nil
        }
        let modelHistoryWriteTask = capturedModelHistory.flatMap { modelHistory in
            queueActiveChatModelHistory(reason: modelHistoryReason, modelHistory: modelHistory)
        }
        let transcriptWriteTask = queueActiveChatTranscriptSnapshot(reason: transcriptSnapshotReason)
        let turnCompletedWriteTask = appendActiveChatTurnCompleted(turnID, status: status)
        isRunningAgent = false
        let turnDuration = max(0, Self.currentMillisecondsSince1970() - turnStartedAtMilliseconds)
        recordDiagnostic(diagnosticName, fields: [
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
            "turn_duration_ms": "\(turnDuration)",
            "status": status,
            "transcript_count": "\(transcript.count)"
        ])
        clearCurrentTurnStreamingState()
        clearCurrentTurnPersistenceState()
        failedTurnStartedAtMilliseconds.remove(turnStartedAtMilliseconds)
        currentTurnStartedAtMilliseconds = nil
        currentAgentTurnID = nil
        currentAgentTurnTask = nil
        observeActiveChatWrite(
            transcriptWriteTask,
            reason: "transcript_snapshot:\(transcriptSnapshotReason)_nonblocking"
        )
        observeActiveChatWrite(
            modelHistoryWriteTask,
            reason: "model_history:\(modelHistoryReason)_nonblocking"
        )
        observeActiveChatWrite(
            turnCompletedWriteTask,
            reason: "turn_completed:\(status)_nonblocking"
        )
        await refreshWorkspace()
    }

    private func runShellDiagnosticCommand(_ command: String) async {
        guard let runtime else {
            handleRuntimeError("Shell diagnostic failed: runtime unavailable.")
            return
        }

        let turnStartedAtMilliseconds = Self.currentMillisecondsSince1970()
        let callID = "diagnostic-shell-\(turnStartedAtMilliseconds)"
        let batchID = UUID()
        isRunningAgent = true
        currentTurnStartedAtMilliseconds = turnStartedAtMilliseconds
        transcript.append(
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "测试命令流式输出",
                turnStartedAtMilliseconds: turnStartedAtMilliseconds
            )
        )
        recordDiagnostic("shell_diagnostic_start", fields: [
            "call_id": callID,
            "cmd": command,
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)"
        ])
        e2eEventLog?.record("shell_diagnostic_start", fields: [
            "call_id": callID,
            "cmd": command,
            "turn_started_at_ms": "\(turnStartedAtMilliseconds)"
        ])

        let call = MSPAgentToolCall(
            id: callID,
            name: .execCommand,
            arguments: [
                MSPExecCommandToolSchema.commandArgumentName: .string(command)
            ]
        )
        handle(.toolStarted(call, statusText: "正在执行工作区命令", batchID: batchID))

        let bridge = runtime.execCommandBridge()
        let startedAt = Date()
        let result = await bridge.run(MSPExecCommandCall(cmd: command)) { [weak self] outputEvent in
            guard let viewModel = self else {
                return
            }
            await MainActor.run {
                viewModel.handle(.toolOutputDelta(
                    callID: callID,
                    name: .execCommand,
                    stream: outputEvent.stream,
                    text: outputEvent.text
                ))
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let renderedText = MSPExecCommandRenderer.renderAgentText(
            from: result,
            options: MSPExecCommandRenderOptions(wallTimeSeconds: elapsed)
        )
        let toolResult = MSPAgentToolResult(
            callID: callID,
            name: .execCommand,
            ok: result.exitCode == 0,
            content: .string(renderedText),
            internalContent: .object([
                "cmd": .string(command),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr),
                "exit_code": .number(Double(result.exitCode))
            ]),
            errorMessage: result.exitCode == 0 ? nil : renderedText
        )
        flushTranscriptStreamingDeltas()
        handle(.toolCompleted(toolResult, batchID: batchID))
        finishCurrentTurn()
        isRunningAgent = false
        let duration = max(0, Self.currentMillisecondsSince1970() - turnStartedAtMilliseconds)
        recordDiagnostic("shell_diagnostic_finished", fields: [
            "call_id": callID,
            "cmd": command,
            "stdout_text_length": "\(result.stdout.count)",
            "stderr_text_length": "\(result.stderr.count)",
            "exit_code": "\(result.exitCode)",
            "turn_duration_ms": "\(duration)"
        ])
        e2eEventLog?.record("shell_diagnostic_finished", fields: [
            "call_id": callID,
            "cmd": command,
            "stdout_text_length": "\(result.stdout.count)",
            "stderr_text_length": "\(result.stderr.count)",
            "exit_code": "\(result.exitCode)",
            "turn_duration_ms": "\(duration)"
        ])
        streamingAssistantProgressItemID = nil
        streamingFinalItemID = nil
        pendingFinalAnswerProvenanceFields = nil
        resetTranscriptStreamingDeltas()
        pendingToolPreparationItemIDs.removeAll(keepingCapacity: true)
        activeToolStartedAtMillisecondsByCallID.removeAll(keepingCapacity: true)
        activeToolStdoutPreviewsByCallID.removeAll(keepingCapacity: true)
        activeToolStderrPreviewsByCallID.removeAll(keepingCapacity: true)
        currentTurnStartedAtMilliseconds = nil
    }

    private func refreshCodexOAuthCredentialForAgentTurnIfNeeded() async {
        let normalized = codexOAuthConfiguration.normalized()
        guard normalized.hasRefreshToken else {
            return
        }

        let metadata = MSPCodexOAuthJWTMetadata(
            idToken: Self.nilIfEmpty(normalized.idToken),
            accessToken: Self.nilIfEmpty(normalized.accessToken)
        )
        if let expiresAt = metadata.accessTokenExpiresAt,
           expiresAt > Date().addingTimeInterval(120) {
            return
        }

        let refreshed = await codexOAuthLoginService.refreshAccessToken(using: normalized)
        guard refreshed != normalized else {
            return
        }
        codexOAuthConfiguration = refreshed
        MSPCodexOAuthConfigurationStore.save(refreshed)
    }

    private func handleModelRequestBuilt(
        _ requestBody: MSPAgentRequestBody,
        turnStartedAtMilliseconds: Int
    ) {
        guard !isTurnStopped(turnStartedAtMilliseconds) else {
            return
        }
        lastRequestBody = requestBody
        let userInputTexts = Self.requestUserInputTexts(requestBody)
        e2eEventLog?.record("model_request_built", fields: [
            "request_layer": "app_turn_submission",
            "model": requestBody.model,
            "input_count": "\(requestBody.input.count)",
            "request_user_input_count": "\(userInputTexts.count)",
            "request_user_input_hash_algorithm": "sha256-utf8",
            "request_user_input_sha256s": userInputTexts.map(Self.sha256Hex).joined(separator: ","),
            "request_last_user_input_sha256": userInputTexts.last.map(Self.sha256Hex) ?? "",
            "tool_count": "\(requestBody.tools.count)",
            "stream": "\(requestBody.stream)"
        ])
        recordDiagnostic("model_request_built", fields: [
            "request_layer": "app_turn_submission",
            "model": requestBody.model,
            "input_count": "\(requestBody.input.count)",
            "request_user_input_count": "\(userInputTexts.count)",
            "request_user_input_hash_algorithm": "sha256-utf8",
            "request_user_input_sha256s": userInputTexts.map(Self.sha256Hex).joined(separator: ","),
            "request_last_user_input_sha256": userInputTexts.last.map(Self.sha256Hex) ?? "",
            "tool_count": "\(requestBody.tools.count)",
            "stream": "\(requestBody.stream)"
        ])
        persistCurrentUserModelInputIfNeeded(
            requestBody: requestBody,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds
        )
    }

    private static func requestUserInputTexts(_ requestBody: MSPAgentRequestBody) -> [String] {
        requestBody.input
            .filter { $0.role == "user" }
            .map { message in
                message.content
                    .filter { $0.type == "input_text" }
                    .map(\.text)
                    .joined(separator: "\n")
            }
    }

    private func persistCurrentUserModelInputIfNeeded(
        userMessage: String,
        textSelections: [PhotoSorterTextSelectionSnapshot],
        turnStartedAtMilliseconds: Int
    ) {
        guard !modelInputPersistedTurnStartedAtMilliseconds.contains(turnStartedAtMilliseconds) else {
            return
        }
        let currentUserItems = Self.durableCurrentUserModelItems(
            userMessage: userMessage,
            textSelections: textSelections
        )
        guard !currentUserItems.isEmpty else {
            return
        }
        modelInputPersistedTurnStartedAtMilliseconds.insert(turnStartedAtMilliseconds)
        activeTurnUserModelItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] = currentUserItems
        let writeTask = queueActiveChatWrite(reason: "model_history:user_input_preflight") { session in
            try await session.appendModelVisibleItemsAsync(currentUserItems)
        }
        Task { [weak self] in
            await writeTask?.value
            self?.recordDiagnostic("agent_chat_user_model_input_persisted", fields: [
                "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
                "item_count": "\(currentUserItems.count)",
                "source": "preflight"
            ])
        }
    }

    private func persistCurrentUserModelInputIfNeeded(
        requestBody: MSPAgentRequestBody,
        turnStartedAtMilliseconds: Int
    ) {
        guard !modelInputPersistedTurnStartedAtMilliseconds.contains(turnStartedAtMilliseconds) else {
            return
        }
        let currentUserItems = Self.currentUserModelItems(from: requestBody)
        guard !currentUserItems.isEmpty else {
            return
        }
        modelInputPersistedTurnStartedAtMilliseconds.insert(turnStartedAtMilliseconds)
        activeTurnUserModelItemsByStartedAtMilliseconds[turnStartedAtMilliseconds] = currentUserItems
        let writeTask = queueActiveChatWrite(reason: "model_history:user_input") { session in
            try await session.appendModelVisibleItemsAsync(currentUserItems)
        }
        Task { [weak self] in
            await writeTask?.value
            self?.recordDiagnostic("agent_chat_user_model_input_persisted", fields: [
                "turn_started_at_ms": "\(turnStartedAtMilliseconds)",
                "item_count": "\(currentUserItems.count)"
            ])
        }
    }

    nonisolated static func durableCurrentUserModelItems(
        userMessage: String,
        textSelections: [PhotoSorterTextSelectionSnapshot]
    ) -> [MSPAgentJSONValue] {
        let prompt = PhotoSorterSelectedTextPromptFormatter.prompt(
            userPrompt: userMessage,
            textSelections: textSelections
        )
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string(prompt)
                    ])
                ])
            ])
        ]
    }

    private static func currentUserModelItems(from requestBody: MSPAgentRequestBody) -> [MSPAgentJSONValue] {
        requestBody.input
            .suffix(1)
            .filter { $0.role == "user" }
            .compactMap { try? MSPAgentJSONValue(encoding: $0) }
    }

    nonisolated private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func handleRuntimeError(_ text: String) {
        guard let currentTurnStartedAtMilliseconds else {
            appendRuntimeError(text)
            return
        }
        handleRuntimeError(text, turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds)
    }

    private func handleRuntimeError(
        _ text: String,
        turnStartedAtMilliseconds: Int
    ) {
        guard !isTurnStopped(turnStartedAtMilliseconds) else {
            return
        }
        failedTurnStartedAtMilliseconds.insert(turnStartedAtMilliseconds)
        flushTranscriptStreamingDeltas()
        appendRuntimeError(text)
    }

    private func appendRuntimeError(_ text: String) {
        e2eEventLog?.record("runtime_error", fields: [
            "message": text
        ])
        recordDiagnostic("runtime_error", fields: [
            "message": text
        ])
        appendTimeline(kind: .error, title: "Error", body: text)
        scheduleActiveChatTranscriptSnapshot(reason: "runtime_error", delayNanoseconds: 0)
    }

    private func handle(_ event: MSPAgentEvent) {
        guard let currentTurnStartedAtMilliseconds else {
            handle(event, turnStartedAtMilliseconds: Int.min)
            return
        }
        handle(event, turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds)
    }

#if DEBUG
    func applyAgentEventForTesting(
        _ event: MSPAgentEvent,
        turnStartedAtMilliseconds: Int
    ) {
        currentTurnStartedAtMilliseconds = turnStartedAtMilliseconds
        handle(event, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
    }

    func applyRuntimeErrorForTesting(
        _ text: String,
        turnStartedAtMilliseconds: Int
    ) {
        currentTurnStartedAtMilliseconds = turnStartedAtMilliseconds
        handleRuntimeError(text, turnStartedAtMilliseconds: turnStartedAtMilliseconds)
    }

    func failedTurnRecordedForTesting(
        turnStartedAtMilliseconds: Int
    ) -> Bool {
        failedTurnStartedAtMilliseconds.contains(turnStartedAtMilliseconds)
    }

    func flushTranscriptStreamingDeltasForTesting() {
        flushTranscriptStreamingDeltas()
    }
#endif

    private func handle(
        _ event: MSPAgentEvent,
        turnStartedAtMilliseconds: Int
    ) {
        guard !isTurnStopped(turnStartedAtMilliseconds) else {
            return
        }
        switch event {
        case .turnStarted(let event):
            e2eEventLog?.record("turn_started", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID
            ])
            recordDiagnostic("turn_started", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID
            ])

        case .turnAborted(let event):
            e2eEventLog?.record("turn_aborted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "reason": event.reason.rawValue
            ])
            recordDiagnostic("turn_aborted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "reason": event.reason.rawValue
            ])

        case .turnSteerAccepted(let event):
            e2eEventLog?.record("turn_steer_accepted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? ""
            ])
            recordDiagnostic("turn_steer_accepted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? ""
            ])

        case .turnSteerApplied(let event):
            e2eEventLog?.record("turn_steer_applied", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? "",
                "boundary": event.boundary.rawValue,
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])
            recordDiagnostic("turn_steer_applied", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "sequence_number": "\(event.sequenceNumber)",
                "content_length": "\(event.contentText.count)",
                "client_user_message_id": event.clientUserMessageID ?? "",
                "boundary": event.boundary.rawValue,
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])

        case .threadGoalUpdated(let event):
            e2eEventLog?.record("thread_goal_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "reason": event.reason.rawValue,
                "goal_id": event.goal.goalID,
                "status": event.goal.status.rawValue
            ])
            recordDiagnostic("thread_goal_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "reason": event.reason.rawValue,
                "goal_id": event.goal.goalID,
                "status": event.goal.status.rawValue
            ])

        case .threadGoalCleared(let event):
            e2eEventLog?.record("thread_goal_cleared", fields: [
                "thread_id": event.threadID,
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "goal_id": event.clearedGoal?.goalID ?? "",
                "status": event.clearedGoal?.status.rawValue ?? ""
            ])
            recordDiagnostic("thread_goal_cleared", fields: [
                "thread_id": event.threadID,
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "goal_id": event.clearedGoal?.goalID ?? "",
                "status": event.clearedGoal?.status.rawValue ?? ""
            ])

        case .threadGoalAccounted(let event):
            e2eEventLog?.record("thread_goal_accounted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "goal_id": event.goalID,
                "token_delta": "\(event.tokenDelta)",
                "time_delta_seconds": "\(event.timeDeltaSeconds)",
                "tokens_used": "\(event.tokensUsed)",
                "time_used_seconds": "\(event.timeUsedSeconds)",
                "status": event.status.rawValue
            ])
            recordDiagnostic("thread_goal_accounted", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID ?? "",
                "event_id": event.eventID,
                "goal_id": event.goalID,
                "token_delta": "\(event.tokenDelta)",
                "time_delta_seconds": "\(event.timeDeltaSeconds)",
                "tokens_used": "\(event.tokensUsed)",
                "time_used_seconds": "\(event.timeUsedSeconds)",
                "status": event.status.rawValue
            ])

        case .planProgressUpdated(let event):
            applyPlanProgressUpdate(event)
            e2eEventLog?.record("plan_progress_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "event_id": event.eventID,
                "plan_count": "\(event.plan.count)",
                "explanation": event.explanation ?? ""
            ])
            recordDiagnostic("plan_progress_updated", fields: [
                "thread_id": event.threadID,
                "turn_id": event.turnID,
                "event_id": event.eventID,
                "plan_count": "\(event.plan.count)",
                "explanation": event.explanation ?? ""
            ])

        case .planModeProposalDelta(let event):
            e2eEventLog?.record("plan_mode_proposal_delta", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "item_id": event.itemID,
                "delta_length": "\(event.delta.count)"
            ])
            recordDiagnostic("plan_mode_proposal_delta", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "item_id": event.itemID,
                "delta_length": "\(event.delta.count)"
            ])

        case .planModeProposed(let event):
            e2eEventLog?.record("plan_mode_proposed", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "content_length": "\(event.proposedPlanContent.count)"
            ])
            recordDiagnostic("plan_mode_proposed", fields: [
                "thread_id": event.threadID,
                "planning_turn_id": event.planningTurnID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "content_length": "\(event.proposedPlanContent.count)"
            ])

        case .planModeApproved(let event):
            e2eEventLog?.record("plan_mode_approved", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])
            recordDiagnostic("plan_mode_approved", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeRejected(let event):
            e2eEventLog?.record("plan_mode_rejected", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])
            recordDiagnostic("plan_mode_rejected", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeModified(let event):
            e2eEventLog?.record("plan_mode_modified", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])
            recordDiagnostic("plan_mode_modified", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "source": event.source.rawValue,
                "decision": event.decision.rawValue,
                "reason": event.reason ?? ""
            ])

        case .planModeHandoff(let event):
            e2eEventLog?.record("plan_mode_handoff", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "implementation_prompt_length": "\(event.implementationPrompt.count)",
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])
            recordDiagnostic("plan_mode_handoff", fields: [
                "thread_id": event.threadID,
                "proposal_id": event.proposalID,
                "proposal_version": "\(event.proposalVersion)",
                "event_id": event.eventID,
                "implementation_prompt_length": "\(event.implementationPrompt.count)",
                "model_input_item_count": "\(event.modelInputItemCount)"
            ])

        case .compactTurnStarted(let id):
            e2eEventLog?.record("compact_turn_started", fields: [
                "turn_id": id.uuidString
            ])
            recordDiagnostic("compact_turn_started", fields: [
                "turn_id": id.uuidString
            ])

        case .contextCompactionStarted(let id):
            flushTranscriptStreamingDeltas()
            beginContextCompactionProgressBlock(compactionID: id)
            e2eEventLog?.record("context_compaction_started", fields: [
                "item_id": id
            ])
            recordDiagnostic("context_compaction_started", fields: [
                "item_id": id
            ])

        case .contextCompactionCompleted(let id):
            flushTranscriptStreamingDeltas()
            completeContextCompactionProgressBlock(compactionID: id)
            e2eEventLog?.record("context_compaction_completed", fields: [
                "item_id": id
            ])
            recordDiagnostic("context_compaction_completed", fields: [
                "item_id": id
            ])

        case .contextCompactionFailed(let id, message: let message):
            removeContextCompactionProgressBlock(compactionID: id)
            e2eEventLog?.record("context_compaction_failed", fields: [
                "item_id": id,
                "message": message
            ])
            recordDiagnostic("context_compaction_failed", fields: [
                "item_id": id,
                "message": message
            ])

        case .compactionWarning(let message):
            e2eEventLog?.record("compaction_warning", fields: [
                "message": message
            ])
            recordDiagnostic("compaction_warning", fields: [
                "message": message
            ])

        case .modelRequestPreparing(let statusText):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("model_request_preparing", fields: [
                "status_text": statusText
            ])
            recordDiagnostic("model_request_preparing", fields: [
                "status_text": statusText
            ])

        case .probe(let probe):
            e2eEventLog?.record(probe.name, fields: probe.fields)
            recordDiagnostic(probe.name, fields: probe.fields)
            if probe.name == "model_final_answer_provenance" {
                pendingFinalAnswerProvenanceFields = probe.fields
            }

        case .assistantProgressSegmentStarted(let id):
            flushTranscriptStreamingDeltas()
            streamingAssistantProgressItemID = nil
            e2eEventLog?.record("assistant_progress_segment_started", fields: [
                "segment_id": id.uuidString
            ])
            recordDiagnostic("assistant_progress_segment_started", fields: [
                "segment_id": id.uuidString
            ])

        case .assistantProgress(let text):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("assistant_progress", fields: [
                "text_length": "\(text.count)"
            ])
            recordDiagnostic("assistant_progress", fields: [
                "text_length": "\(text.count)"
            ])
            replaceOrAppendAssistantProgress(text)

        case .assistantProgressDelta(let text):
            e2eEventLog?.record("assistant_progress_delta", fields: [
                "text_length": "\(text.count)"
            ])
            recordDiagnostic("assistant_progress_delta", fields: [
                "text_length": "\(text.count)"
            ])
            queueAssistantProgressDelta(text)

        case .toolPreparing(let name, let statusText):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("tool_preparing", fields: [
                "name": name.rawValue,
                "status_text": statusText
            ])
            recordDiagnostic("tool_preparing", fields: [
                "name": name.rawValue,
                "status_text": statusText
            ])
            guard name != .writeStdin,
                  !Self.isUpdatePlanTool(name) else {
                break
            }
            streamingAssistantProgressItemID = nil
            beginToolPreparation(name: name, statusText: statusText)

        case .toolStarted(let call, let statusText, let batchID):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("tool_started", fields: [
                "name": call.name.rawValue,
                "cmd": call.arguments["cmd"]?.stringValue ?? "",
                "status_text": statusText
            ])
            recordDiagnostic("tool_started", fields: [
                "name": call.name.rawValue,
                "call_id": call.id,
                "batch_id": batchID.uuidString,
                "cmd": call.arguments["cmd"]?.stringValue ?? "",
                "status_text": statusText
            ])
            guard !Self.isUpdatePlanTool(call.name) else {
                break
            }
            streamingAssistantProgressItemID = nil
            beginOrUpdateToolCall(call, statusText: statusText, batchID: batchID)

        case .toolOutputDelta(let callID, let name, let stream, let text):
            guard !Self.isUpdatePlanTool(name) else {
                break
            }
            e2eEventLog?.record("tool_output_delta", fields: [
                "call_id": callID,
                "name": name.rawValue,
                "stream": stream.rawValue,
                "text_length": "\(text.count)",
                "text": text,
                "text_preview": Self.diagnosticPreview(text)
            ])
            recordDiagnostic("tool_output_delta", fields: [
                "call_id": callID,
                "name": name.rawValue,
                "stream": stream.rawValue,
                "text_length": "\(text.count)",
                "text_preview": Self.diagnosticPreview(text)
            ])
            queueToolOutputDelta(
                callID: callID,
                name: name,
                stream: stream,
                text: text
            )

        case .toolCompleted(let result, _):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("tool_completed", fields: toolCompletedLogFields(result))
            recordDiagnostic("tool_completed_event", fields: toolCompletedLogFields(result).merging([
                "call_id": result.callID
            ]) { _, new in new })
            guard !Self.isUpdatePlanTool(result.name) else {
                break
            }
            let completedItem = completeToolCall(result)
            recordDiagnostic(
                "transcript_after_tool_completed",
                fields: transcriptToolLogFields(result: result, item: completedItem)
            )
            recordDiagnostic(
                "payload_after_tool_completed",
                fields: payloadToolLogFields(callID: result.callID)
            )

        case .finalAnswerStarted:
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("final_answer_started")
            recordDiagnostic("final_answer_started")
            streamingAssistantProgressItemID = nil
            ensureStreamingFinalItem()

        case .finalAnswerDelta(let text):
            recordStreamTrace("vm.final_answer_delta", fields: [
                "text_length": "\(text.count)"
            ])
            e2eEventLog?.record("final_answer_delta", fields: [
                "text_length": "\(text.count)"
            ])
            appendFinalDelta(text)

        case .finalAnswer(let text):
            flushTranscriptStreamingDeltas()
            recordStreamTrace("vm.final_answer", fields: [
                "text_length": "\(text.count)"
            ])
            e2eEventLog?.record("final_answer", fields: finalAnswerLogFields(text))
            pendingFinalAnswerProvenanceFields = nil
            recordDiagnostic("final_answer", fields: [
                "text_length": "\(text.count)"
            ])
            replaceOrAppendFinalAnswer(text)

        case .contextUsageUpdated(let usage):
            contextUsage = usage
            e2eEventLog?.record("context_usage_updated", fields: [
                "model": usage.modelID,
                "current_tokens": "\(usage.currentTokens)",
                "context_window_tokens": "\(usage.contextWindowTokens)",
                "server_total_tokens": usage.serverTotalTokens.map { "\($0)" } ?? ""
            ])
            recordDiagnostic("context_usage_updated", fields: [
                "model": usage.modelID,
                "current_tokens": "\(usage.currentTokens)",
                "context_window_tokens": "\(usage.contextWindowTokens)",
                "server_input_tokens": usage.serverInputTokens.map { "\($0)" } ?? "",
                "server_output_tokens": usage.serverOutputTokens.map { "\($0)" } ?? "",
                "server_total_tokens": usage.serverTotalTokens.map { "\($0)" } ?? ""
            ])

        case .modelStreamRetrying(let statusText):
            flushTranscriptStreamingDeltas()
            e2eEventLog?.record("model_stream_retrying", fields: [
                "status_text": statusText
            ])
            recordDiagnostic("model_stream_retrying", fields: [
                "status_text": statusText
            ])
            replaceOrAppendAssistantProgress(statusText)
        }
    }

    private func finalAnswerLogFields(_ text: String) -> [String: String] {
        var fields = [
            "text_length": "\(text.count)",
            "text_hash_algorithm": "sha256-utf8",
            "text_sha256": Self.sha256Hex(text),
            "text": text,
            "response_id": "",
            "response_completed": "false",
            "source": ""
        ]
        if let provenance = pendingFinalAnswerProvenanceFields {
            fields["response_id"] = provenance["response_id"] ?? ""
            fields["response_completed"] = provenance["response_completed"] ?? "false"
            fields["source"] = provenance["source"] ?? ""
            fields["provenance_event"] = "model_final_answer_provenance"
            fields["provenance_text_length"] = provenance["text_length"] ?? ""
            fields["provenance_text_hash_algorithm"] = provenance["text_hash_algorithm"] ?? ""
            fields["provenance_text_sha256"] = provenance["text_sha256"] ?? ""
            fields["model_request_layer"] = provenance["model_request_layer"] ?? ""
            fields["model_request_run_id"] = provenance["model_request_run_id"] ?? ""
            fields["model_request_sequence"] = provenance["model_request_sequence"] ?? ""
            fields["model_request_model"] = provenance["model_request_model"] ?? ""
            fields["request_user_input_hash_algorithm"] = provenance["request_user_input_hash_algorithm"] ?? ""
            fields["request_user_input_sha256s"] = provenance["request_user_input_sha256s"] ?? ""
            fields["request_last_user_input_sha256"] = provenance["request_last_user_input_sha256"] ?? ""
        }
        return fields
    }

    private func clearContextUsageIfModelChanged(to configuration: MSPModelConfiguration) {
        let nextModelID = configuration.normalized().modelID
        guard contextUsage?.modelID != nextModelID else {
            return
        }
        contextUsage = nil
    }

    private func applyPlanProgressUpdate(_ event: MSPPlanProgressUpdatedEvent) {
        let steps = event.plan.map { item in
            ExampleChatCodexPlanStep(
                step: item.step,
                status: Self.planProgressStatus(from: item.status)
            )
        }
        guard !steps.isEmpty else {
            activePlanProgressUpdate = nil
            return
        }
        activePlanProgressUpdate = ExampleChatCodexPlanUpdate(
            threadID: event.threadID,
            turnID: event.turnID,
            explanation: event.explanation,
            steps: steps
        )
    }

    private static func planProgressStatus(
        from status: MSPUpdatePlanStepStatus
    ) -> ExampleChatCodexPlanStepStatus {
        switch status {
        case .pending:
            return .pending
        case .inProgress:
            return .inProgress
        case .completed:
            return .completed
        }
    }

    private static func isUpdatePlanTool(_ name: MSPAgentToolName) -> Bool {
        name.rawValue == MSPUpdatePlanToolSchema.name
    }

    private func beginContextCompactionProgressBlock(compactionID: String) {
        let now = Self.currentMillisecondsSince1970()
        if let existingID = activeContextCompactionProgressItemIDByCompactionID[compactionID],
           let index = transcript.firstIndex(where: { $0.id == existingID }) {
            transcript[index].body = Self.contextCompactionRunningText
            transcript[index].status = "processing"
            transcript[index].startedAtMilliseconds = transcript[index].startedAtMilliseconds ?? now
            transcript[index].completedAtMilliseconds = nil
            transcript[index].durationMilliseconds = nil
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            return
        }

        let item = MSPAgentTimelineItem(
            kind: .assistantProgress,
            title: "",
            body: Self.contextCompactionRunningText,
            status: "processing",
            startedAtMilliseconds: now,
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        activeContextCompactionProgressItemIDByCompactionID[compactionID] = item.id
        transcript.append(item)
    }

    private func completeContextCompactionProgressBlock(compactionID: String) {
        let now = Self.currentMillisecondsSince1970()
        if let existingID = activeContextCompactionProgressItemIDByCompactionID[compactionID],
           let index = transcript.firstIndex(where: { $0.id == existingID }) {
            transcript[index].body = Self.contextCompactionCompletedText
            transcript[index].status = "success"
            transcript[index].completedAtMilliseconds = now
            if let startedAt = transcript[index].startedAtMilliseconds {
                transcript[index].durationMilliseconds = max(0, now - startedAt)
            }
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            activeContextCompactionProgressItemIDByCompactionID[compactionID] = nil
            return
        }

        let item = MSPAgentTimelineItem(
            kind: .assistantProgress,
            title: "",
            body: Self.contextCompactionCompletedText,
            status: "success",
            startedAtMilliseconds: now,
            completedAtMilliseconds: now,
            durationMilliseconds: 0,
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        transcript.append(item)
    }

    private func removeContextCompactionProgressBlock(compactionID: String) {
        guard let existingID = activeContextCompactionProgressItemIDByCompactionID[compactionID] else {
            return
        }
        transcript.removeAll { $0.id == existingID }
        activeContextCompactionProgressItemIDByCompactionID[compactionID] = nil
    }

    private func appendTimeline(
        kind: MSPAgentTimelineItem.Kind,
        title: String,
        body: String,
        detail: String? = nil,
        callID: String? = nil,
        batchID: UUID? = nil,
        toolName: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int? = nil,
        execSessionID: Int? = nil,
        parentCallID: String? = nil,
        status: String? = nil,
        startedAtMilliseconds: Int? = nil,
        completedAtMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil,
        images: [MSPAgentTimelineImage] = []
    ) {
        transcript.append(
            MSPAgentTimelineItem(
                kind: kind,
                title: title,
                body: body,
                detail: detail,
                callID: callID,
                batchID: batchID,
                toolName: toolName,
                command: command,
                cwd: cwd,
                stdout: stdout,
                stderr: stderr,
                exitCode: exitCode,
                execSessionID: execSessionID,
                parentCallID: parentCallID,
                status: status,
                startedAtMilliseconds: startedAtMilliseconds,
                completedAtMilliseconds: completedAtMilliseconds,
                durationMilliseconds: durationMilliseconds,
                turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds,
                images: images
            )
        )
    }

    private static func timelineImages(from modelOutputContent: MSPAgentJSONValue?) -> [MSPAgentTimelineImage] {
        guard let modelOutputContent else {
            return []
        }
        let items = modelOutputContent.arrayValue ?? [modelOutputContent]
        return items.compactMap { item in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "input_image",
                  let imageURL = object["image_url"]?.stringValue else {
                return nil
            }
            return timelineImage(fromDataURL: imageURL)
        }
    }

    private static func timelineImage(fromDataURL imageURL: String) -> MSPAgentTimelineImage? {
        guard imageURL.hasPrefix("data:"),
              let commaIndex = imageURL.firstIndex(of: ",") else {
            return nil
        }
        let headerStart = imageURL.index(imageURL.startIndex, offsetBy: 5)
        let header = String(imageURL[headerStart..<commaIndex])
        let base64Start = imageURL.index(after: commaIndex)
        let base64 = String(imageURL[base64Start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base64.isEmpty,
              header.localizedCaseInsensitiveContains(";base64") else {
            return nil
        }
        let mimeType = header.split(separator: ";", maxSplits: 1).first.map(String.init)
        return MSPAgentTimelineImage(
            base64: base64,
            mimeType: mimeType?.isEmpty == false ? mimeType : nil
        )
    }

    private func queueAssistantProgressDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        appendAssistantProgressDelta(text)
    }

    private func queueToolOutputDelta(
        callID: String,
        name: MSPAgentToolName,
        stream: MSPExecCommandOutputStreamName,
        text: String
    ) {
        guard !text.isEmpty else {
            return
        }
        let key = "\(callID)\u{1f}\(name.rawValue)\u{1f}\(stream.rawValue)"
        var delta = pendingToolOutputDeltas[key] ?? PendingToolOutputDelta(
            callID: callID,
            name: name,
            stream: stream,
            text: ""
        )
        delta.text += text
        pendingToolOutputDeltas[key] = delta
        scheduleToolOutputStreamingFlush()
    }

    private func scheduleToolOutputStreamingFlush() {
        guard toolOutputStreamingFlushTask == nil else {
            return
        }
        toolOutputStreamingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.toolOutputStreamingFlushIntervalNanoseconds)
            await MainActor.run {
                self?.flushToolOutputStreamingDeltas()
            }
        }
    }

    private func flushTranscriptStreamingDeltas() {
        flushToolOutputStreamingDeltas()
    }

    private func flushToolOutputStreamingDeltas() {
        toolOutputStreamingFlushTask?.cancel()
        toolOutputStreamingFlushTask = nil

        let toolOutputDeltas = pendingToolOutputDeltas.values.sorted {
            $0.callID == $1.callID
                ? $0.stream.rawValue < $1.stream.rawValue
                : $0.callID < $1.callID
        }
        if !toolOutputDeltas.isEmpty {
            recordStreamTrace("vm.flush_tool_output", fields: [
                "delta_count": "\(toolOutputDeltas.count)"
            ])
        }
        pendingToolOutputDeltas.removeAll(keepingCapacity: true)

        for delta in toolOutputDeltas {
            appendToolOutputDelta(
                callID: delta.callID,
                name: delta.name,
                stream: delta.stream,
                text: delta.text
            )
        }
    }

    private func resetTranscriptStreamingDeltas() {
        toolOutputStreamingFlushTask?.cancel()
        toolOutputStreamingFlushTask = nil
        pendingToolOutputDeltas.removeAll(keepingCapacity: true)
    }

    private func clearCurrentTurnStreamingState() {
        activePlanProgressUpdate = nil
        streamingAssistantProgressItemID = nil
        streamingFinalItemID = nil
        pendingFinalAnswerProvenanceFields = nil
        activeContextCompactionProgressItemIDByCompactionID.removeAll(keepingCapacity: true)
        resetTranscriptStreamingDeltas()
        pendingToolPreparationItemIDs.removeAll(keepingCapacity: true)
        activeToolStartedAtMillisecondsByCallID.removeAll(keepingCapacity: true)
        activeToolStdoutPreviewsByCallID.removeAll(keepingCapacity: true)
        activeToolStderrPreviewsByCallID.removeAll(keepingCapacity: true)
        activeExecCommandCallIDBySessionID.removeAll(keepingCapacity: true)
        activeExecSessionIDByCallID.removeAll(keepingCapacity: true)
        activeWriteStdinParentCallIDByCallID.removeAll(keepingCapacity: true)
        if let currentTurnStartedAtMilliseconds {
            failedTurnStartedAtMilliseconds.remove(currentTurnStartedAtMilliseconds)
        }
    }

    private func clearCurrentTurnPersistenceState() {
        activeChatModelHistorySnapshotTask?.cancel()
        activeChatModelHistorySnapshotTask = nil
        activeTurnModelHistoryPrefixCountByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnModelHistoryPrefixItemsByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnModelHistorySnapshotItemCountByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnCurrentItemsSnapshotItemCountByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnLatestCurrentItemsByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnLatestModelHistoryByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        activeTurnUserModelItemsByStartedAtMilliseconds.removeAll(keepingCapacity: true)
        modelInputPersistedTurnStartedAtMilliseconds.removeAll(keepingCapacity: true)
    }

    private func cleanupFinishedAgentTurnIfCurrent(turnID: UUID) {
        guard currentAgentTurnID == turnID else {
            return
        }
        clearCurrentTurnStreamingState()
        clearCurrentTurnPersistenceState()
        currentTurnStartedAtMilliseconds = nil
        currentAgentTurnID = nil
        currentAgentTurnTask = nil
    }

    private func isTurnStopped(_ turnStartedAtMilliseconds: Int) -> Bool {
        stoppedTurnStartedAtMilliseconds.contains(turnStartedAtMilliseconds)
    }

    private func appendToolOutputDelta(
        callID: String,
        name: MSPAgentToolName,
        stream: MSPExecCommandOutputStreamName,
        text: String
    ) {
        guard !text.isEmpty,
              let targetCallID = toolOutputTargetCallID(callID: callID, name: name),
              let index = transcript.firstIndex(where: { $0.callID == targetCallID }) else {
            return
        }
        var updatedItem: MSPAgentTimelineItem?
        withoutAutomaticTranscriptRenderRebuild {
            switch stream {
            case .stdout:
                transcript[index].stdout = appendToolOutputPreviewDelta(
                    text,
                    callID: targetCallID,
                    previews: &activeToolStdoutPreviewsByCallID
                )
            case .stderr:
                transcript[index].stderr = appendToolOutputPreviewDelta(
                    text,
                    callID: targetCallID,
                    previews: &activeToolStderrPreviewsByCallID
                )
            }
            transcript[index].status = "inProgress"
            transcript[index].body = "正在执行工作区命令"
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            updatedItem = transcript[index]
        }
        applyStreamingToolActivityUpdateOrRebuild(updatedItem)
    }

    private func toolOutputTargetCallID(
        callID: String,
        name: MSPAgentToolName
    ) -> String? {
        if name == .execCommand {
            return callID
        }
        if name == .writeStdin {
            return activeWriteStdinParentCallIDByCallID[callID]
        }
        return nil
    }

    private func appendToolOutputPreviewDelta(
        _ text: String,
        callID: String,
        previews: inout [String: MSPTerminalOutputPreview]
    ) -> String {
        var preview = previews[callID] ?? MSPTerminalOutputPreview()
        let displayText = preview.append(text)
        previews[callID] = preview
        return displayText
    }

    private func beginToolPreparation(
        name: MSPAgentToolName,
        statusText: String
    ) {
        let item = MSPAgentTimelineItem(
            kind: .toolCall,
            title: "工作区命令",
            body: statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "正在执行工作区命令"
                : statusText,
            detail: nil,
            toolName: name.rawValue,
            status: "inProgress",
            startedAtMilliseconds: Self.currentMillisecondsSince1970(),
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        pendingToolPreparationItemIDs.append(item.id)
        transcript.append(item)
    }

    private func beginOrUpdateToolCall(
        _ call: MSPAgentToolCall,
        statusText: String,
        batchID: UUID?
    ) {
        if call.name == .writeStdin,
           beginOrUpdateWriteStdinCall(call) {
            return
        }

        let startedAt = Self.currentMillisecondsSince1970()
        let command = call.arguments["cmd"]?.stringValue ?? ""
        let body = statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "正在执行工作区命令"
            : statusText
        let detail = toolCallDetail(call, statusText: body)

        while !pendingToolPreparationItemIDs.isEmpty {
            let pendingToolPreparationItemID = pendingToolPreparationItemIDs.removeFirst()
            guard let index = transcript.firstIndex(where: { $0.id == pendingToolPreparationItemID }) else {
                continue
            }
            var updatedItem: MSPAgentTimelineItem?
            withoutAutomaticTranscriptRenderRebuild {
                transcript[index].callID = call.id
                transcript[index].batchID = batchID
                transcript[index].toolName = call.name.rawValue
                transcript[index].command = command
                transcript[index].cwd = "/"
                transcript[index].body = body
                transcript[index].detail = detail
                transcript[index].status = "inProgress"
                transcript[index].startedAtMilliseconds = transcript[index].startedAtMilliseconds ?? startedAt
                transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                    ?? currentTurnStartedAtMilliseconds
                activeToolStartedAtMillisecondsByCallID[call.id] = transcript[index].startedAtMilliseconds ?? startedAt
                updatedItem = transcript[index]
            }
            applyStreamingToolActivityUpdateOrRebuild(updatedItem)
            return
        }

        activeToolStartedAtMillisecondsByCallID[call.id] = startedAt
        appendTimeline(
            kind: .toolCall,
            title: "工作区命令",
            body: body,
            detail: detail,
            callID: call.id,
            batchID: batchID,
            toolName: call.name.rawValue,
            command: command,
            cwd: "/",
            status: "inProgress",
            startedAtMilliseconds: startedAt
        )
    }

    private func beginOrUpdateWriteStdinCall(_ call: MSPAgentToolCall) -> Bool {
        guard let sessionID = sessionIDArgument(from: call),
              let parentCallID = activeExecCommandCallID(forSessionID: sessionID) else {
            return false
        }

        activeWriteStdinParentCallIDByCallID[call.id] = parentCallID
        activeToolStartedAtMillisecondsByCallID[call.id] = Self.currentMillisecondsSince1970()
        guard let index = transcript.firstIndex(where: { $0.callID == parentCallID }) else {
            return true
        }

        var updatedItem: MSPAgentTimelineItem?
        withoutAutomaticTranscriptRenderRebuild {
            transcript[index].status = "inProgress"
            transcript[index].body = "正在执行工作区命令"
            transcript[index].execSessionID = sessionID
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            updatedItem = transcript[index]
        }
        applyStreamingToolActivityUpdateOrRebuild(updatedItem)
        return true
    }

    private func sessionIDArgument(from call: MSPAgentToolCall) -> Int? {
        call.arguments[MSPWriteStdinToolSchema.sessionIDArgumentName]?.intValue
    }

    private func activeExecCommandCallID(forSessionID sessionID: Int) -> String? {
        if let callID = activeExecCommandCallIDBySessionID[sessionID] {
            return callID
        }
        return transcript.last { item in
            guard item.execSessionID == sessionID,
                  let callID = item.callID,
                  !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if item.toolName == MSPExecCommandToolSchema.name {
                return true
            }
            if let command = item.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               !command.isEmpty {
                return true
            }
            return false
        }?.callID
    }

    @discardableResult
    private func completeToolCall(_ result: MSPAgentToolResult) -> MSPAgentTimelineItem? {
        let completedAt = Self.currentMillisecondsSince1970()
        let object = result.internalContent?.objectValue
        let command = object?["cmd"]?.stringValue
        let sessionID = object?["session_id"]?.intValue
        let runningSessionID = object?["running_session_id"]?.intValue
        let internalExitCode = object?["exit_code"]?.intValue
        let targetCallID = toolResultTargetCallID(result, sessionID: sessionID)
        let targetIndex = targetCallID.flatMap { callID in
            transcript.firstIndex(where: { item in
                (item.kind == .toolCall || item.kind == .toolResult) && item.callID == callID
            })
        }
        let fallbackIndex = existingToolTimelineItemIndex(for: result, command: command)
        let existingIndex = targetIndex ?? fallbackIndex
        let displayCallID = existingIndex.flatMap { transcript[$0].callID } ?? targetCallID ?? result.callID
        let isRunningSessionResult = resultStillHasRunningSession(
            result,
            sessionID: sessionID,
            runningSessionID: runningSessionID,
            exitCode: internalExitCode
        )
        let appendsToExistingOutput = result.name == .writeStdin
        let stdout = terminalDisplayOutput(
            object?["stdout"]?.stringValue,
            livePreview: activeToolStdoutPreviewsByCallID[displayCallID],
            existing: existingIndex.flatMap { transcript[$0].stdout },
            appendsToExisting: appendsToExistingOutput
        )
        let stderr = terminalDisplayOutput(
            object?["stderr"]?.stringValue,
            livePreview: activeToolStderrPreviewsByCallID[displayCallID],
            existing: existingIndex.flatMap { transcript[$0].stderr },
            appendsToExisting: appendsToExistingOutput
        )
        let exitCode = isRunningSessionResult
            ? nil
            : (internalExitCode ?? (result.ok ? 0 : 1))
        let startedAt = existingIndex.flatMap { transcript[$0].startedAtMilliseconds }
            ?? activeToolStartedAtMillisecondsByCallID[displayCallID]
            ?? activeToolStartedAtMillisecondsByCallID[result.callID]
        let duration = isRunningSessionResult
            ? nil
            : max(100, completedAt - (startedAt ?? completedAt))
        let body = isRunningSessionResult
            ? "正在执行工作区命令"
            : ((result.ok && (exitCode ?? 0) == 0) ? "已执行工作区命令" : "工作区命令执行失败")
        let status = isRunningSessionResult
            ? "inProgress"
            : ((result.ok && (exitCode ?? 0) == 0) ? "completed" : "failed")
        let detail = isRunningSessionResult
            ? existingIndex.flatMap { transcript[$0].detail }
            : toolResultDetail(result)
        let images = Self.timelineImages(from: result.modelOutputContent)
        let completedItem: MSPAgentTimelineItem?

        if let index = existingIndex {
            var updatedItem: MSPAgentTimelineItem?
            withoutAutomaticTranscriptRenderRebuild {
                transcript[index].kind = .toolCall
                transcript[index].body = body
                transcript[index].detail = detail
                if result.name != .writeStdin {
                    transcript[index].callID = result.callID
                    transcript[index].toolName = result.name.rawValue
                } else {
                    transcript[index].toolName = transcript[index].toolName ?? MSPExecCommandToolSchema.name
                    transcript[index].parentCallID = transcript[index].parentCallID ?? targetCallID
                }
                if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcript[index].command = command
                }
                transcript[index].stdout = stdout
                transcript[index].stderr = stderr
                transcript[index].exitCode = exitCode
                transcript[index].execSessionID = sessionID ?? runningSessionID ?? transcript[index].execSessionID
                transcript[index].status = status
                transcript[index].completedAtMilliseconds = isRunningSessionResult ? nil : completedAt
                transcript[index].durationMilliseconds = duration
                transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                    ?? currentTurnStartedAtMilliseconds
                if !images.isEmpty {
                    transcript[index].images = images
                }
                updatedItem = transcript[index]
            }
            completedItem = updatedItem
            if images.isEmpty {
                applyStreamingToolActivityUpdateOrRebuild(updatedItem)
            } else {
                rebuildTranscriptRenderState()
            }
        } else {
            appendTimeline(
                kind: .toolResult,
                title: "工作区命令",
                body: body,
                detail: detail,
                callID: result.callID,
                toolName: result.name.rawValue,
                command: command,
                cwd: "/",
                stdout: stdout,
                stderr: stderr,
                exitCode: exitCode,
                execSessionID: sessionID ?? runningSessionID,
                parentCallID: targetCallID,
                status: status,
                startedAtMilliseconds: startedAt,
                completedAtMilliseconds: isRunningSessionResult ? nil : completedAt,
                durationMilliseconds: duration,
                images: images
            )
            completedItem = transcript.last
        }
        updateExecSessionTracking(
            result: result,
            displayCallID: displayCallID,
            sessionID: sessionID ?? runningSessionID,
            stillRunning: isRunningSessionResult
        )
        return completedItem
    }

    private func applyStreamingToolActivityUpdateOrRebuild(_ item: MSPAgentTimelineItem?) {
        guard let item else {
            rebuildTranscriptRenderState()
            return
        }
        guard applyStreamingToolActivityUpdate(item) else {
            rebuildTranscriptRenderState()
            return
        }
    }

    private func applyStreamingToolActivityUpdate(_ item: MSPAgentTimelineItem) -> Bool {
        guard let callID = item.callID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !callID.isEmpty,
              let supportBlock = ExampleChatTranscriptPayloadFactory.streamingToolSupportBlockPayload(from: item) else {
            return false
        }
        return transcriptRenderController.applyStreamingToolActivity(
            callID: callID,
            fallbackTargetIDs: [item.id.uuidString],
            supportBlock: supportBlock
        )
    }

    private func resultStillHasRunningSession(
        _ result: MSPAgentToolResult,
        sessionID: Int?,
        runningSessionID: Int?,
        exitCode: Int?
    ) -> Bool {
        if result.name == .execCommand {
            if runningSessionID != nil {
                return true
            }
            guard sessionID != nil else {
                return false
            }
            if exitCode == nil {
                return true
            }
            return result.content?.stringValue?.contains("Process running with session ID") == true
        }
        if result.name == .writeStdin {
            return runningSessionID != nil
        }
        return false
    }

    private func toolResultTargetCallID(
        _ result: MSPAgentToolResult,
        sessionID: Int?
    ) -> String? {
        if result.name == .writeStdin {
            if let parentCallID = activeWriteStdinParentCallIDByCallID[result.callID] {
                return parentCallID
            }
            if let sessionID {
                return activeExecCommandCallID(forSessionID: sessionID)
            }
        }
        return result.callID
    }

    private func updateExecSessionTracking(
        result: MSPAgentToolResult,
        displayCallID: String,
        sessionID: Int?,
        stillRunning: Bool
    ) {
        if stillRunning, let sessionID {
            activeExecCommandCallIDBySessionID[sessionID] = displayCallID
            activeExecSessionIDByCallID[displayCallID] = sessionID
            if result.name == .writeStdin {
                activeToolStartedAtMillisecondsByCallID[result.callID] = nil
                activeWriteStdinParentCallIDByCallID[result.callID] = nil
            }
            return
        }

        if let sessionID {
            activeExecCommandCallIDBySessionID[sessionID] = nil
        }
        if let trackedSessionID = activeExecSessionIDByCallID[displayCallID] {
            activeExecCommandCallIDBySessionID[trackedSessionID] = nil
        }
        activeExecSessionIDByCallID[displayCallID] = nil
        activeToolStartedAtMillisecondsByCallID[displayCallID] = nil
        activeToolStdoutPreviewsByCallID[displayCallID] = nil
        activeToolStderrPreviewsByCallID[displayCallID] = nil

        if result.callID != displayCallID {
            activeToolStartedAtMillisecondsByCallID[result.callID] = nil
            activeToolStdoutPreviewsByCallID[result.callID] = nil
            activeToolStderrPreviewsByCallID[result.callID] = nil
        }
        activeWriteStdinParentCallIDByCallID[result.callID] = nil
    }

    private func existingToolTimelineItemIndex(
        for result: MSPAgentToolResult,
        command: String?
    ) -> Int? {
        if let exactIndex = transcript.firstIndex(where: { item in
            (item.kind == .toolCall || item.kind == .toolResult)
                && item.callID == result.callID
        }) {
            return exactIndex
        }

        let normalizedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedCommand.isEmpty,
           let commandIndex = transcript.lastIndex(where: { item in
               item.kind == .toolCall
                   && (item.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == normalizedCommand
                   && toolTimelineItemCanAcceptResult(item)
           }) {
            return commandIndex
        }

        let runningCandidates = transcript.indices.filter { index in
            let item = transcript[index]
            guard item.kind == .toolCall,
                  toolTimelineItemCanAcceptResult(item) else {
                return false
            }
            if let currentTurnStartedAtMilliseconds {
                return item.turnStartedAtMilliseconds == currentTurnStartedAtMilliseconds
                    || item.turnStartedAtMilliseconds == nil
            }
            return true
        }
        return runningCandidates.count == 1 ? runningCandidates[0] : nil
    }

    private func toolTimelineItemCanAcceptResult(_ item: MSPAgentTimelineItem) -> Bool {
        switch item.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "inprogress", "running", "processing", "streaming", "pending":
            return true
        default:
            return false
        }
    }

    private func terminalDisplayOutput(
        _ fullText: String?,
        livePreview: MSPTerminalOutputPreview?,
        existing: String? = nil,
        appendsToExisting: Bool = false
    ) -> String? {
        if let displayText = livePreview?.displayText,
           !displayText.isEmpty {
            return displayText
        }
        guard let fullText else {
            return nil
        }
        guard !fullText.isEmpty else {
            return existing
        }
        let preview = MSPTerminalOutputPreview(text: fullText)
        let displayText = preview.displayText
        guard !displayText.isEmpty else {
            return existing
        }
        guard appendsToExisting,
              let existing,
              !existing.isEmpty else {
            return displayText
        }
        if existing.hasSuffix(displayText) {
            return existing
        }
        return existing + displayText
    }

    @discardableResult
    private func ensureStreamingFinalItem() -> Bool {
        guard streamingFinalItemID == nil else {
            return false
        }
        let item = MSPAgentTimelineItem(
            kind: .assistantFinal,
            title: "",
            body: "",
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        streamingFinalItemID = item.id
        transcript.append(item)
        return true
    }

    @discardableResult
    private func ensureStreamingAssistantProgressItem() -> Bool {
        guard streamingAssistantProgressItemID == nil else {
            return false
        }
        let item = MSPAgentTimelineItem(
            kind: .assistantProgress,
            title: "模型中间回复",
            body: "",
            startedAtMilliseconds: Self.currentMillisecondsSince1970(),
            turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
        )
        streamingAssistantProgressItemID = item.id
        transcript.append(item)
        return true
    }

    private func appendAssistantProgressDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        guard streamingAssistantProgressItemID != nil else {
            let item = MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: text,
                startedAtMilliseconds: Self.currentMillisecondsSince1970(),
                turnStartedAtMilliseconds: currentTurnStartedAtMilliseconds
            )
            streamingAssistantProgressItemID = item.id
            transcript.append(item)
            return
        }
        guard let streamingAssistantProgressItemID,
              let index = transcript.firstIndex(where: { $0.id == streamingAssistantProgressItemID }) else {
            return
        }
        let previousText = transcript[index].body
        let nextText = previousText + text
        guard !previousText.isEmpty else {
            transcript[index].body = nextText
            return
        }

        withoutAutomaticTranscriptRenderRebuild {
            transcript[index].body = nextText
        }
        guard transcriptRenderController.applyStreamingProgressText(
            supportBlockID: streamingAssistantProgressItemID.uuidString,
            text: nextText,
            previousTextLength: previousText.count,
            appendText: text
        ) else {
            recordStreamTrace("vm.assistant_progress_streaming_update_fallback", fields: [
                "support_block_id": streamingAssistantProgressItemID.uuidString,
                "previous_text_length": "\(previousText.count)",
                "append_text_length": "\(text.count)"
            ])
            rebuildTranscriptRenderState(reason: "assistant_progress_streaming_update_fallback")
            return
        }
        recordStreamTrace("vm.assistant_progress_streaming_update", fields: [
            "support_block_id": streamingAssistantProgressItemID.uuidString,
            "previous_text_length": "\(previousText.count)",
            "append_text_length": "\(text.count)",
            "text_length": "\(nextText.count)"
        ])
    }

    private func replaceOrAppendAssistantProgress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let streamingAssistantProgressItemID,
           let index = transcript.firstIndex(where: { $0.id == streamingAssistantProgressItemID }) {
            transcript[index].body = text
            self.streamingAssistantProgressItemID = nil
            return
        }
        appendTimeline(kind: .assistantProgress, title: "模型中间回复", body: text)
    }

    private func appendFinalDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let startedAtMilliseconds = Self.streamTraceNowMilliseconds()
        ensureStreamingFinalItem()
        guard let streamingFinalItemID,
              let index = transcript.firstIndex(where: { $0.id == streamingFinalItemID }) else {
            return
        }
        let previousText = transcript[index].body
        let nextText = previousText + text
        recordStreamTrace("vm.append_final_delta_begin", fields: [
            "append_text_length": "\(text.count)",
            "previous_text_length": "\(previousText.count)",
            "next_text_length": "\(nextText.count)",
            "transcript_count": "\(transcript.count)"
        ])
        guard !previousText.isEmpty else {
            transcript[index].body = nextText
            recordStreamTrace("vm.append_final_delta_initial_state", fields: [
                "append_text_length": "\(text.count)",
                "next_text_length": "\(nextText.count)",
                "elapsed_ms": Self.streamTraceElapsedMilliseconds(since: startedAtMilliseconds)
            ])
            return
        }

        let messageID = streamingMainTextMessageID(for: transcript[index])
        withoutAutomaticTranscriptRenderRebuild {
            transcript[index].body = nextText
        }
        guard transcriptRenderController.applyStreamingMainText(
            messageID: messageID,
            text: nextText,
            previousTextLength: previousText.count,
            appendText: text
        ) else {
            recordStreamTrace("vm.final_answer_streaming_update_fallback", fields: [
                "message_id": messageID,
                "previous_text_length": "\(previousText.count)",
                "append_text_length": "\(text.count)",
                "elapsed_ms": Self.streamTraceElapsedMilliseconds(since: startedAtMilliseconds)
            ])
            rebuildTranscriptRenderState(reason: "final_answer_streaming_update_fallback")
            return
        }
        recordStreamTrace("vm.final_answer_streaming_update", fields: [
            "message_id": messageID,
            "previous_text_length": "\(previousText.count)",
            "append_text_length": "\(text.count)",
            "text_length": "\(nextText.count)",
            "elapsed_ms": Self.streamTraceElapsedMilliseconds(since: startedAtMilliseconds)
        ])
    }

    private func streamingMainTextMessageID(for item: MSPAgentTimelineItem) -> String {
        if let turnStartedAtMilliseconds = item.turnStartedAtMilliseconds {
            return "assistant-turn-\(turnStartedAtMilliseconds)"
        }
        return "assistant-item-\(item.id.uuidString)"
    }

    private func replaceOrAppendFinalAnswer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let streamingFinalItemID,
           let index = transcript.firstIndex(where: { $0.id == streamingFinalItemID }) {
            transcript[index].body = trimmed.isEmpty ? transcript[index].body : text
            transcript[index].turnStartedAtMilliseconds = transcript[index].turnStartedAtMilliseconds
                ?? currentTurnStartedAtMilliseconds
            return
        }
        appendTimeline(kind: .assistantFinal, title: "", body: text)
    }

    private func finishCurrentTurn() {
        guard let currentTurnStartedAtMilliseconds else {
            return
        }
        let duration = max(0, Self.currentMillisecondsSince1970() - currentTurnStartedAtMilliseconds)
        withoutAutomaticTranscriptRenderRebuild {
            for index in transcript.indices
            where transcript[index].turnStartedAtMilliseconds == currentTurnStartedAtMilliseconds {
                transcript[index].turnDurationMilliseconds = duration
            }
        }
        rebuildTranscriptRenderState()
    }

    private func applyCodexOAuthQuotaResult(_ result: MSPCodexOAuthQuotaResult) {
        codexOAuthQuota = result

        var updated = codexOAuthConfiguration.normalized()
        var shouldSave = false
        if let email = result.email, !email.isEmpty, updated.email != email {
            updated.email = email
            shouldSave = true
        }
        if let planType = result.planType, !planType.isEmpty, updated.planType != planType {
            updated.planType = planType
            shouldSave = true
        }
        if result.status == .success, updated.lastLoginStatus != .signedIn {
            updated.lastLoginStatus = .signedIn
            shouldSave = true
        }
        if updated.lastStatusMessage != result.message {
            updated.lastStatusMessage = result.message
            shouldSave = true
        }
        if updated.lastCheckedAt != result.checkedAt {
            updated.lastCheckedAt = result.checkedAt
            shouldSave = true
        }
        if shouldSave {
            codexOAuthConfiguration = updated
            MSPCodexOAuthConfigurationStore.save(updated)
        }
    }

    private func applyCodexOAuthLoginResult(_ result: MSPCodexOAuthLoginResult) {
        codexOAuthConfiguration = result.configuration
        codexOAuthConfiguration.lastStatusMessage = result.message
        MSPCodexOAuthConfigurationStore.save(codexOAuthConfiguration)
        if result.configuration.lastLoginStatus != .signedIn {
            codexOAuthQuota = nil
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func transcriptVisibleTextProbeEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-probe-transcript-visible-text")
            || environment["MSP_PLAYGROUND_TRANSCRIPT_VISIBLE_TEXT_PROBE"] == "1"
    }

    private static func transcriptToolDetailExpansionEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-expand-transcript-tool-details")
            || environment["MSP_PLAYGROUND_EXPAND_TRANSCRIPT_TOOL_DETAILS"] == "1"
    }

    private func toolCallDetail(
        _ call: MSPAgentToolCall,
        statusText: String
    ) -> String {
        let command = call.arguments["cmd"]?.stringValue ?? ""
        guard !command.isEmpty else {
            return statusText
        }
        return "\(statusText)\n命令: \(command)"
    }

    private func toolResultBody(_ result: MSPAgentToolResult) -> String {
        if let text = result.content?.stringValue, !text.isEmpty {
            return text
        }
        if let error = result.errorMessage, !error.isEmpty {
            return error
        }
        return "(no output)"
    }

    private func toolResultDetail(_ result: MSPAgentToolResult) -> String? {
        guard let object = result.internalContent?.objectValue else {
            return nil
        }
        guard let exitCode = object["exit_code"]?.intValue else {
            return nil
        }
        return "退出码: \(exitCode)"
    }

    private func toolCompletedLogFields(_ result: MSPAgentToolResult) -> [String: String] {
        let contentText = result.content?.stringValue ?? ""
        let containsStructuredShellKeys = contentText.contains("\"stdout\"")
            || contentText.contains("\"stderr\"")
            || contentText.contains("\"exit_code\"")
        var fields: [String: String] = [
            "name": result.name.rawValue,
            "ok": "\(result.ok)",
            "content_kind": result.content?.stringValue == nil ? "non_string" : "string",
            "content_length": "\(contentText.count)",
            "content_text": contentText,
            "content_preview": Self.diagnosticPreview(contentText),
            "content_contains_shell_json_keys": "\(containsStructuredShellKeys)"
        ]
        if let object = result.internalContent?.objectValue {
            fields["internal_exit_code"] = object["exit_code"]?.intValue.map(String.init) ?? ""
            fields["internal_running_session_id"] = object["running_session_id"]?.intValue.map(String.init) ?? ""
            fields["internal_stdout_length"] = "\(object["stdout"]?.stringValue?.count ?? 0)"
            fields["internal_stdout_preview"] = Self.diagnosticPreview(object["stdout"]?.stringValue ?? "")
            fields["internal_stderr_length"] = "\(object["stderr"]?.stringValue?.count ?? 0)"
            fields["internal_stderr_preview"] = Self.diagnosticPreview(object["stderr"]?.stringValue ?? "")
        }
        if let errorMessage = result.errorMessage,
           !errorMessage.isEmpty {
            fields["error_length"] = "\(errorMessage.count)"
            fields["error_message"] = errorMessage
        }
        return fields
    }

    private static func diagnosticPreview(_ text: String, limit: Int = 200) -> String {
        guard text.count > limit else {
            return text
        }
        return "\(text.prefix(limit))…"
    }

    private func recordDiagnostic(_ event: String, fields: [String: String] = [:]) {
        var commonFields: [String: String] = [
            "agent_access_mode": agentAccessMode.rawValue,
            "sensitive_read_policy": sensitiveReadPolicy.rawValue,
            "is_running_agent": "\(isRunningAgent)",
            "transcript_count": "\(transcript.count)"
        ]
        if let currentTurnStartedAtMilliseconds {
            commonFields["current_turn_started_at_ms"] = "\(currentTurnStartedAtMilliseconds)"
        }
        let mergedFields = commonFields.merging(fields) { _, new in new }
        Task {
            await diagnosticsLog.record(event, fields: mergedFields)
        }
    }

    private func recordStreamTrace(_ event: String, fields: [String: String] = [:]) {
        guard Self.streamTraceEnabled() else {
            return
        }
        var allFields = fields
        allFields["t_ms"] = String(format: "%.3f", Self.streamTraceNowMilliseconds())
        let lineFields = allFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.streamTraceToken($0.value))" }
            .joined(separator: " ")
        print("PST_STREAM_TRACE \(event)\(lineFields.isEmpty ? "" : " \(lineFields)")")
        recordDiagnostic("pst_stream_trace_\(event)", fields: allFields)
    }

    private static func streamTraceEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--photosorter-stream-trace")
            || environment["PHOTOSORTER_STREAM_TRACE"] == "1"
            || environment["SIMCTL_CHILD_PHOTOSORTER_STREAM_TRACE"] == "1"
    }

    private static func streamTraceToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func streamTraceNowMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    private static func streamTraceElapsedMilliseconds(since start: Double) -> String {
        String(format: "%.3f", max(0, streamTraceNowMilliseconds() - start))
    }

    private func modelConfigurationDiagnosticFields() -> [String: String] {
        let normalized = modelConfiguration.normalized()
        let codexOAuth = codexOAuthConfiguration.normalized()
        return [
            "provider": normalized.providerName,
            "model": normalized.modelID,
            "credential_mode": normalized.credentialMode,
            "base_url_host": normalized.resolvedBaseURL?.host ?? "",
            "has_api_key": "\(!normalized.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            "has_codex_oauth_credential": "\(codexOAuth.hasStoredCredential)",
            "codex_oauth_status": codexOAuth.lastLoginStatus.rawValue
        ]
    }

    private func transcriptToolLogFields(
        result: MSPAgentToolResult,
        item: MSPAgentTimelineItem?
    ) -> [String: String] {
        var fields: [String: String] = [
            "call_id": result.callID,
            "ok": "\(result.ok)",
            "item_found": "\(item != nil)"
        ]
        guard let item else {
            return fields
        }
        fields["item_kind"] = Self.timelineKindName(item.kind)
        fields["item_body"] = item.body
        fields["item_status"] = item.status ?? ""
        fields["item_command"] = item.command ?? ""
        fields["item_exit_code"] = item.exitCode.map(String.init) ?? ""
        fields["item_stdout_length"] = "\(item.stdout?.count ?? 0)"
        fields["item_stderr_length"] = "\(item.stderr?.count ?? 0)"
        fields["item_started_at_ms"] = item.startedAtMilliseconds.map(String.init) ?? ""
        fields["item_completed_at_ms"] = item.completedAtMilliseconds.map(String.init) ?? ""
        fields["item_duration_ms"] = item.durationMilliseconds.map(String.init) ?? ""
        fields["item_turn_started_at_ms"] = item.turnStartedAtMilliseconds.map(String.init) ?? ""
        return fields
    }

    private func payloadToolLogFields(callID: String) -> [String: String] {
        let payload = ExampleChatTranscriptPayloadFactory.payload(
            from: transcript,
            isGenerating: isRunningAgent,
            expandToolActivityBlocks: expandsTranscriptToolDetailsForTesting,
            expansionState: transcriptExpansionState
        )
        guard let messages = payload["messages"] as? [[String: Any]] else {
            return [
                "call_id": callID,
                "payload_has_messages": "false"
            ]
        }

        var fields: [String: String] = [
            "call_id": callID,
            "payload_has_messages": "true",
            "message_count": "\(messages.count)"
        ]
        var supportBlockCount = 0
        for message in messages {
            let supportBlocks = message["supportBlocks"] as? [[String: Any]] ?? []
            supportBlockCount += supportBlocks.count
            for block in supportBlocks {
                let activityItems = block["items"] as? [[String: Any]] ?? []
                guard let activity = activityItems.first(where: { activityItem in
                    Self.diagnosticString(activityItem["id"]) == callID
                        || Self.diagnosticNestedString(activityItem["commandExecution"], key: "callID") == callID
                }) else {
                    continue
                }

                fields["support_block_count"] = "\(supportBlockCount)"
                fields["message_id"] = Self.diagnosticString(message["id"])
                fields["message_status"] = Self.diagnosticString(message["status"])
                fields["message_is_streaming"] = Self.diagnosticString(message["isStreaming"])
                fields["support_block_found"] = "true"
                fields["support_block_id"] = Self.diagnosticString(block["id"])
                fields["support_block_kind"] = Self.diagnosticString(block["kind"])
                fields["support_block_text"] = Self.diagnosticString(block["text"])
                fields["support_block_status"] = Self.diagnosticString(block["status"])
                fields["activity_found"] = "true"
                fields["activity_id"] = Self.diagnosticString(activity["id"])
                fields["activity_text"] = Self.diagnosticString(activity["text"])
                fields["activity_status"] = Self.diagnosticString(activity["status"])
                fields["activity_completed"] = Self.diagnosticString(activity["completed"])
                fields["activity_completed_at_ms"] = Self.diagnosticString(activity["completedAtMilliseconds"])
                fields["activity_duration_ms"] = Self.diagnosticString(activity["durationMilliseconds"])
                fields["command_execution_status"] = Self.diagnosticNestedString(activity["commandExecution"], key: "status")
                fields["command_execution_exit_code"] = Self.diagnosticNestedString(activity["commandExecution"], key: "exitCode")
                fields["shell_execution_exit_code"] = Self.diagnosticNestedString(activity["shellExecution"], key: "exitCode")
                fields["shell_execution_output_length"] = "\(Self.diagnosticNestedString(activity["shellExecution"], key: "output").count)"
                return fields
            }
        }

        fields["support_block_count"] = "\(supportBlockCount)"
        fields["support_block_found"] = "false"
        fields["activity_found"] = "false"
        return fields
    }

    private static func timelineKindName(_ kind: MSPAgentTimelineItem.Kind) -> String {
        switch kind {
        case .system:
            return "system"
        case .user:
            return "user"
        case .assistantProgress:
            return "assistantProgress"
        case .toolCall:
            return "toolCall"
        case .toolResult:
            return "toolResult"
        case .assistantFinal:
            return "assistantFinal"
        case .stoppedMarker:
            return "stoppedMarker"
        case .error:
            return "error"
        }
    }

    private static func diagnosticNestedString(_ value: Any?, key: String) -> String {
        guard let object = value as? [String: Any] else {
            return ""
        }
        return diagnosticString(object[key])
    }

    private static func diagnosticString(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let string as String:
            return string
        case let bool as Bool:
            return "\(bool)"
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return "\(int)"
        case let double as Double:
            return "\(double)"
        default:
            return String(describing: value ?? "")
        }
    }

    static func resolvedPrompt(
        text: String,
        textSelections: [PhotoSorterTextSelectionSnapshot]
    ) -> String {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }
        return textSelections.isEmpty ? "" : "请查看选中的文本。"
    }

    private static func currentMillisecondsSince1970() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func millisecondsSince1970(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    private var workspaceCacheVersionToken: String {
        [
            "index",
            photoLibraryIndexStatus.phase.rawValue,
            "\(photoLibraryIndexStatus.version)",
            "workspace",
            "\(photoLibraryWorkspaceChangeSummary.version)"
        ].joined(separator: "-")
    }

    private func refreshWorkspace() async {
        guard let runtime else {
            return
        }

        let cacheVersionToken = workspaceCacheVersionToken
        do {
            fileTreeState = .loaded(
                try runtime.snapshotWorkspace(
                    maxDepth: 1,
                    maxEntriesPerDirectory: Self.workspaceTreeEntriesPerDirectoryLimit
                )
            )
        } catch {
            fileTreeState = .failed(error.localizedDescription)
        }
        await refreshOpenWorkspacePreviewIfNeeded(
            cacheVersionToken: cacheVersionToken,
            runtime: runtime
        )
    }

    private func refreshWorkspaceTrashNow() async {
        guard let runtime else {
            workspaceTrashTreeState = .loaded([])
            return
        }

        do {
            workspaceTrashTreeState = .loaded(
                try runtime.snapshotWorkspaceTrash(
                    maxEntries: Self.workspaceTreeEntriesPerDirectoryLimit
                )
            )
            workspaceTrashErrorMessage = nil
        } catch {
            workspaceTrashTreeState = .failed(error.localizedDescription)
            workspaceTrashErrorMessage = error.localizedDescription
        }
    }

    private func refreshOpenWorkspacePreviewIfNeeded(
        cacheVersionToken: String,
        runtime: MSPPlaygroundShellRuntime
    ) async {
        guard let preview = workspaceMediaPreview,
              preview.invalidateCachedContentIfWorkspaceChanged(to: cacheVersionToken)
        else {
            return
        }
        await loadWorkspacePreviewNode(
            Self.workspacePreviewReloadNode(
                path: preview.path,
                title: preview.title
            ),
            into: preview,
            runtime: runtime
        )
    }

    private static func workspacePreviewReloadNode(
        path: String,
        title: String
    ) -> WorkspaceFileNode {
        let name = path.split(separator: "/").last.map(String.init) ?? title
        return WorkspaceFileNode(
            name: name,
            path: path,
            type: .regularFile,
            mediaKind: WorkspaceFileMediaKind.inferred(fromFileName: name)
        )
    }

    private func observePhotoLibraryIndexStatus() {
        photoLibraryIndexStatusTask?.cancel()
        photoLibraryIndexStatus = photoLibraryMount.photoLibraryIndexStatus
        photoLibraryIndexStatusTask = Task { [weak self] in
            var previousPhase = self?.photoLibraryIndexStatus.phase
            var previousVersion = self?.photoLibraryIndexStatus.version
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let freshStatus = self.photoLibraryMount.photoLibraryIndexStatus
                if self.photoLibraryIndexStatus != freshStatus {
                    self.photoLibraryIndexStatus = freshStatus
                }
                if freshStatus.phase == .ready,
                   previousPhase != .ready || previousVersion != freshStatus.version {
                    await self.refreshWorkspace()
                    self.startPlaceCachePreheatIfAllowed()
                }
                previousPhase = freshStatus.phase
                previousVersion = freshStatus.version
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func observePhotoLibraryOCRCacheStatus() {
        photoLibraryOCRCacheStatusTask?.cancel()
        photoLibraryOCRCacheStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let freshStatus = await self.loadPhotoLibraryOCRCacheStatus()
                guard !Task.isCancelled else {
                    return
                }
                self.applyPhotoLibraryOCRCacheStatus(freshStatus)
                let interval: UInt64 = freshStatus.isPreheating || freshStatus.isPaused
                    ? 1_000_000_000
                    : 3_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func observePhotoLibraryVLMSummaryCacheStatus() {
        photoLibraryVLMSummaryCacheStatusTask?.cancel()
        photoLibraryVLMSummaryCacheStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let freshStatus = await self.loadPhotoLibraryVLMSummaryCacheStatus()
                guard !Task.isCancelled else {
                    return
                }
                self.applyPhotoLibraryVLMSummaryCacheStatus(freshStatus)
                let interval: UInt64 = freshStatus.isPreheating || freshStatus.isPaused
                    ? 1_000_000_000
                    : 3_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func observePhotoLibraryPlaceCacheStatus() {
        photoLibraryPlaceCacheStatusTask?.cancel()
        photoLibraryPlaceCacheStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let freshStatus = await self.loadPhotoLibraryPlaceCacheStatus()
                guard !Task.isCancelled else {
                    return
                }
                self.applyPhotoLibraryPlaceCacheStatus(freshStatus)
                let interval: UInt64 = freshStatus.isPreheating || freshStatus.isPaused
                    ? 1_000_000_000
                    : 3_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func observePhotoLibraryWorkspaceChanges() {
        photoLibraryWorkspaceChangeStatusTask?.cancel()
        photoLibraryWorkspaceChangeSummary = photoLibraryMount.photoLibraryWorkspaceChangeSummary
        photoLibraryWorkspaceChangeStatusTask = Task { [weak self] in
            var previousVersion = self?.photoLibraryWorkspaceChangeSummary.version
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                let freshSummary = self.photoLibraryMount.photoLibraryWorkspaceChangeSummary
                if self.photoLibraryWorkspaceChangeSummary != freshSummary {
                    self.photoLibraryWorkspaceChangeSummary = freshSummary
                }
                if previousVersion != freshSummary.version {
                    await self.refreshWorkspace()
                }
                previousVersion = freshSummary.version
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startPlaceCachePreheatIfAllowed() {
        guard agentAccessMode == .full,
              placeCacheTaskMode == .running
        else {
            return
        }
        photoLibraryMount.startPlaceCachePreheatBatch()
        schedulePhotoLibraryPlaceCacheStatusRefresh()
    }

    private func applyPersistedPlaceCachePauseStateIfNeeded() {
        guard placeCacheTaskMode == .paused else {
            return
        }
        photoLibraryMount.pausePlaceCachePreheat()
        schedulePhotoLibraryPlaceCacheStatusRefresh()
    }

    private func updatePlaceCacheTaskMode(_ mode: PhotoSorterPlaceCacheTaskMode) {
        placeCacheTaskMode = mode
        savePlaceCacheTaskModeHandler(mode)
    }

    private struct TranscriptFixture {
        var variant: TranscriptFixtureVariant
        var items: [MSPAgentTimelineItem]
        var isGenerating: Bool
    }

    private enum TranscriptFixtureVariant: String {
        case completed
        case running
        case thinking
        case failed
        case markdown
    }

    private static func launchTranscriptFixtureIfRequested() -> TranscriptFixture? {
        guard let variant = transcriptFixtureVariant() else {
            return nil
        }
        let turnStartedAt = currentMillisecondsSince1970() - 2_400
        switch variant {
        case .completed:
            return TranscriptFixture(
                variant: variant,
                items: completedTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        case .running:
            return TranscriptFixture(
                variant: variant,
                items: runningTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: true
            )
        case .thinking:
            return TranscriptFixture(
                variant: variant,
                items: thinkingTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: true
            )
        case .failed:
            return TranscriptFixture(
                variant: variant,
                items: failedTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        case .markdown:
            return TranscriptFixture(
                variant: variant,
                items: markdownTranscriptFixture(turnStartedAt: turnStartedAt),
                isGenerating: false
            )
        }
    }

    private static func transcriptFixtureVariant() -> TranscriptFixtureVariant? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--msp-transcript-fixture=") }) {
            let rawValue = String(inline.dropFirst("--msp-transcript-fixture=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptFixtureVariant(rawValue: rawValue).map { $0 } ?? .completed
        }
        guard let flagIndex = arguments.firstIndex(of: "--msp-transcript-fixture") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return .completed
        }
        let rawValue = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.hasPrefix("--") else {
            return .completed
        }
        return TranscriptFixtureVariant(rawValue: rawValue) ?? .completed
    }

    private static func completedTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先查看当前工作区。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                detail: "退出码: 0",
                callID: "fixture-ls",
                command: "ls /",
                cwd: "/",
                stdout: "notes\nwelcome.md\nMSP_HIDDEN_TOOL_STDOUT_SENTINEL\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 1_200,
                durationMilliseconds: 900,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "工作区里现在有一个 notes 目录和一个 welcome.md 文件。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            )
        ]
    }

    private static func thinkingTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "先分析一下工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先确认当前工作区状态。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]
    }

    private static func runningTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先查看当前工作区。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                detail: "命令: ls /",
                callID: "fixture-running-ls",
                command: "ls /",
                cwd: "/",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 300,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]
    }

    private static func failedTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我找一下 docs",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先用工作区命令查找。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "工作区命令执行失败",
                detail: "退出码: 127",
                callID: "fixture-failed-find",
                command: "find /docs -maxdepth 2 -print",
                cwd: "/",
                stdout: "",
                stderr: "find: command not found\nMSP_HIDDEN_TOOL_STDERR_SENTINEL\n",
                exitCode: 127,
                status: "failed",
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 900,
                durationMilliseconds: 600,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "这个工作区命令没有执行成功，我会换一种方式继续检查。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 2_400
            )
        ]
    }

    private static func markdownTranscriptFixture(turnStartedAt: Int) -> [MSPAgentTimelineItem] {
        [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "展示数学和代码渲染",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: """
                下面是数学和代码：

                内联公式 $E=mc^2$，块公式：

                $$\\int_0^1 x^2 dx = \\frac{1}{3}$$

                ```swift
                let answer = 42
                print(answer)
                ```
                """,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 1_800
            )
        ]
    }

    private static func launchAutoSubmitPromptIfRequested() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--msp-auto-submit=") }) {
            let value = String(inline.dropFirst("--msp-auto-submit=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let flagIndex = arguments.firstIndex(of: "--msp-auto-submit") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func launchAutoSubmitPromptSequenceIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        let rawSequence = argumentValue(
            named: "--msp-auto-submit-sequence-json",
            in: arguments
        ) ?? environment["MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON"]

        guard let rawSequence,
              !rawSequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = rawSequence.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }

        let prompts = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return prompts.isEmpty ? nil : prompts
    }

    private static func launchShellDiagnosticCommandIfRequested() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--msp-shell-diagnostic-command=") }) {
            let value = String(inline.dropFirst("--msp-shell-diagnostic-command=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let flagIndex = arguments.firstIndex(of: "--msp-shell-diagnostic-command") else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        let inlinePrefix = name + "="
        if let inline = arguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return arguments[valueIndex]
    }

    static func e2ePhotoLibraryAuthorizationRequestSkipEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--msp-skip-photo-library-authorization-request")
            || environment["MSP_PHOTOSORTER_SKIP_PHOTO_LIBRARY_AUTHORIZATION_REQUEST"] == "1"
    }

    static func shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: PHAuthorizationStatus) -> Bool {
        switch photoAuthorizationStatus {
        case .authorized, .limited:
            return true
        case .notDetermined, .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func launchVLMSummaryPreheatDiagnosticLimitIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Int? {
        let flag = "--msp-vlm-preheat-diagnostic-limit"
        if let inline = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
            let value = String(inline.dropFirst((flag + "=").count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedVLMSummaryPreheatDiagnosticLimit(value)
        }
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: flagIndex)
        guard arguments.indices.contains(valueIndex) else {
            return defaultVLMSummaryPreheatDiagnosticLimit
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("--") else {
            return defaultVLMSummaryPreheatDiagnosticLimit
        }
        return normalizedVLMSummaryPreheatDiagnosticLimit(value)
            ?? defaultVLMSummaryPreheatDiagnosticLimit
    }

    private static let defaultVLMSummaryPreheatDiagnosticLimit = 20
    private static let maximumVLMSummaryPreheatDiagnosticLimit = 50

    private static func normalizedVLMSummaryPreheatDiagnosticLimit(_ value: String) -> Int? {
        guard let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return min(parsed, maximumVLMSummaryPreheatDiagnosticLimit)
    }
}

import Foundation

public actor MSPAgentConversation {
    public typealias EventHandler = @Sendable (MSPAgentEvent) async -> Void
    public typealias RequestBuiltHandler = @Sendable (MSPAgentRequestBody) async -> Void

    enum CurrentWindowPrefillTokens: Equatable {
        case estimated(Int)
        case serverObserved(Int)

        var value: Int {
            switch self {
            case .estimated(let tokens), .serverObserved(let tokens):
                return tokens
            }
        }
    }

    public nonisolated let chatID: String

    /// Compatibility identifier for the existing Goal, Plan, steer, and
    /// interrupt capability APIs. Chat-facing integrations should use
    /// ``chatID``.
    public nonisolated var threadID: String { chatID }
    var configuration: MSPAgentConversationConfiguration
    let modelCatalog: any MSPModelCatalogResolving
    let modelClient: any MSPAgentModelTurnClient
    let execCommandBridge: MSPExecCommandBridge
    let applyPatchExecutor: (any MSPApplyPatchExecuting)?
    let requestBuilder: MSPAgentRequestBuilder
    let compactionRequestBuilder = MSPCompactionRequestBuilder()
    let turnInterruptController: MSPTurnInterruptController
    let turnSteerController: MSPTurnSteerController
    let goalController: MSPGoalController
    let planModeController: MSPPlanModeController
    let compactionHooks: any MSPCompactionLifecycleHookRuntime
    let compactionPersistenceAdapter: any MSPCompactionPersistenceAdapter
    let chatNamingCoordinator: MSPChatNamingCoordinator?
    let toolCallLimit: MSPAgentToolCallLimit
    var transcriptItems: [MSPAgentJSONValue] {
        didSet {
            transcriptRevision &+= 1
            promptTranscriptProjectionCache = nil
        }
    }
    var transcriptRevision = 0
    var promptTranscriptProjectionCache: MSPAgentPromptTranscriptProjection?
    var contextWindowLineage: MSPContextWindowLineageState
    var currentContextWindowID: String
    var previousContextWindowID: String?
    var contextWindowNumber: Int
    var latestContextUsage: MSPAgentContextUsageRecord?
    var resolvedModelProfile: MSPResolvedModelProfile?
    var previousResolvedModelProfile: MSPResolvedModelProfile?
    var currentWindowPrefillTokens: CurrentWindowPrefillTokens?
    var didScheduleInitialChatNaming = false
    var activeUserTurnResultWaiters:
        [CheckedContinuation<MSPAgentRunResult, Error>] = []

    init(
        configuration: MSPAgentConversationConfiguration,
        modelCatalog: any MSPModelCatalogResolving = MSPModelCatalogManager.bundledOnly(),
        modelClient: any MSPAgentModelTurnClient,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder,
        toolCallLimit: MSPAgentToolCallLimit,
        compactionHooks: any MSPCompactionLifecycleHookRuntime = MSPNoopCompactionLifecycleHookRuntime(),
        compactionPersistenceAdapter: any MSPCompactionPersistenceAdapter = MSPNoopCompactionPersistenceAdapter(),
        chatNamingCoordinator: MSPChatNamingCoordinator? = nil,
        schedulesInitialChatNamingOnFirstSend: Bool = true,
        transcriptItems: [MSPAgentJSONValue] = [],
        chatID: String = UUID().uuidString
    ) {
        let initialLineage = MSPContextWindowLineageState()
        self.chatID = chatID
        self.configuration = configuration
        self.modelCatalog = modelCatalog
        self.modelClient = modelClient
        self.execCommandBridge = execCommandBridge
        self.applyPatchExecutor = applyPatchExecutor
        self.requestBuilder = requestBuilder
        self.toolCallLimit = toolCallLimit
        self.turnInterruptController = MSPTurnInterruptController(
            capability: configuration.turnInterruptCapability
        )
        self.turnSteerController = MSPTurnSteerController(
            capability: configuration.turnSteerCapability
        )
        self.goalController = MSPGoalController(
            capability: configuration.goalCapability
        )
        self.planModeController = MSPPlanModeController(
            capability: configuration.planModeCapability
        )
        self.compactionHooks = compactionHooks
        self.compactionPersistenceAdapter = compactionPersistenceAdapter
        self.chatNamingCoordinator = chatNamingCoordinator
        self.didScheduleInitialChatNaming =
            !schedulesInitialChatNamingOnFirstSend
        self.transcriptItems = transcriptItems
        self.contextWindowLineage = initialLineage
        self.currentContextWindowID = initialLineage.currentWindowID
        self.previousContextWindowID = initialLineage.previousWindowID
        self.contextWindowNumber = initialLineage.windowNumber
    }

    @discardableResult
    func resolveModelProfileForCurrentTurn() async throws -> MSPResolvedModelProfile {
        let nextProfile = await modelCatalog.resolve(
            modelID: configuration.model,
            refreshPolicy: .onlineIfUncached
        )
        try Task.checkCancellation()
        if let currentProfile = resolvedModelProfile,
           currentProfile != nextProfile {
            previousResolvedModelProfile = currentProfile
        }
        resolvedModelProfile = nextProfile
        return nextProfile
    }

    func acknowledgeResolvedModelProfileTransition() {
        previousResolvedModelProfile = nil
    }

    public func send(
        _ userMessage: String,
        additionalDeveloperContextBlocks: [String] = [],
        dynamicDeveloperContextBlocks: [MSPAgentDynamicDeveloperContextBlock] = [],
        additionalEnvironmentNotes: [String] = [],
        chatNamingInput: MSPChatNamingInput? = nil,
        onRequestBuilt: RequestBuiltHandler? = nil,
        onTranscriptSnapshotUpdated: (@Sendable ([MSPAgentJSONValue]) async -> Void)? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> MSPAgentRunResult {
        try Task.checkCancellation()
        if shouldSteerSendIntoActiveTurn(
            additionalDeveloperContextBlocks: additionalDeveloperContextBlocks,
            dynamicDeveloperContextBlocks: dynamicDeveloperContextBlocks,
            additionalEnvironmentNotes: additionalEnvironmentNotes,
            onRequestBuilt: onRequestBuilt
        ) {
            if try await steerActiveUserTurnFromSend(userMessage) {
                return try await waitForActiveUserTurnResult()
            }
        }
        await waitForTurnSlot()
        try Task.checkCancellation()
        let turnID = UUID()
        let currentUserItemsForCancellation = try currentUserTranscriptItems(
            userMessage: userMessage
        )
        let earlyTranscriptRecorder = MSPAgentTurnTranscriptRecorder(
            initialItems: currentUserItemsForCancellation,
            onSnapshotUpdated: onTranscriptSnapshotUpdated
        )
        await startTrackedTurn(
            id: turnID,
            kind: .user,
            transcriptRecorder: earlyTranscriptRecorder,
            fallbackTranscriptItems: currentUserItemsForCancellation,
            onEvent: onEvent
        )
        await earlyTranscriptRecorder.emitSnapshotUpdated()
        startAutomaticChatNaming(
            input: chatNamingInput ?? MSPChatNamingInput(text: userMessage)
        )

        do {
            let result = try await runActiveTurn(
                id: turnID,
                userMessage: userMessage,
                additionalDeveloperContextBlocks: additionalDeveloperContextBlocks,
                dynamicDeveloperContextBlocks: dynamicDeveloperContextBlocks,
                additionalEnvironmentNotes: additionalEnvironmentNotes,
                onRequestBuilt: onRequestBuilt,
                onTranscriptSnapshotUpdated: onTranscriptSnapshotUpdated,
                onEvent: onEvent,
                currentUserItemsOverride: currentUserItemsForCancellation
            )
            if result.wasCancelled {
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                resolveActiveUserTurnResultWaiters(returning: cancelledResult)
                return cancelledResult
            }
            let shouldAcceptTurnResult = shouldAppendResultTranscript(for: turnID)
            if shouldAcceptTurnResult,
               !result.transcriptAppendItems.isEmpty {
                appendTranscriptItems(result.transcriptAppendItems)
            }
            if shouldAcceptTurnResult {
                recordLatestNormalTurnContextUsage(result.contextUsage)
            }
            await finishActiveTurn(id: turnID, status: .completed)
            resolveActiveUserTurnResultWaiters(returning: result)
            return result
        } catch {
            if Self.isCancellationLikeError(error) {
                let result = MSPAgentRunResult(
                    finalAnswer: "",
                    toolResults: [],
                    transcriptAppendItems: currentUserItemsForCancellation,
                    wasCancelled: true
                )
                let cancelledResult = await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
                resolveActiveUserTurnResultWaiters(returning: cancelledResult)
                return cancelledResult
            }
            await appendActiveTurnTranscriptSnapshotIfAccepted(id: turnID)
            await finishActiveTurn(id: turnID, status: .failed)
            resolveActiveUserTurnResultWaiters(throwing: error)
            throw error
        }
    }

    private func startAutomaticChatNaming(input: MSPChatNamingInput) {
        guard !didScheduleInitialChatNaming else {
            return
        }
        didScheduleInitialChatNaming = true
        guard let chatNamingCoordinator else {
            return
        }
        let request = MSPChatNamingRequest(
            chatID: chatID,
            input: input,
            source: .initialUserInput
        )
        Task {
            do {
                _ = try await chatNamingCoordinator.generateTitleIfNeeded(request)
            } catch is CancellationError {
                // Manual naming or host cancellation intentionally wins.
            } catch {
                // Chat naming is auxiliary metadata work and must never fail
                // or delay the main agent turn. The coordinator emits its own
                // lifecycle events for host diagnostics and UI projection.
            }
        }
    }

    public func compactLocal(
        onRequestBuilt: RequestBuiltHandler? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> MSPAgentRunResult {
        try Task.checkCancellation()
        await waitForTurnSlot()
        try Task.checkCancellation()
        try await resolveModelProfileForCurrentTurn()

        let turnID = UUID()
        await startTrackedTurn(
            id: turnID,
            kind: .maintenance,
            transcriptRecorder: nil,
            fallbackTranscriptItems: [],
            onEvent: onEvent
        )

        do {
            let result = try await runManualLocalCompact(
                id: turnID,
                onRequestBuilt: onRequestBuilt,
                onEvent: onEvent
            )
            if result.wasCancelled {
                return await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
            }
            latestContextUsage = result.contextUsage
            acknowledgeResolvedModelProfileTransition()
            await finishActiveTurn(id: turnID, status: .completed)
            return result
        } catch {
            if Self.isCancellationLikeError(error) {
                let result = MSPAgentRunResult(
                    finalAnswer: "",
                    toolResults: [],
                    transcriptAppendItems: [],
                    wasCancelled: true
                )
                return await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
            }
            await finishActiveTurn(id: turnID, status: .failed)
            throw error
        }
    }

    public func compact(
        onRequestBuilt: RequestBuiltHandler? = nil,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> MSPAgentRunResult {
        try Task.checkCancellation()
        await waitForTurnSlot()
        try Task.checkCancellation()
        try await resolveModelProfileForCurrentTurn()

        let turnID = UUID()
        await startTrackedTurn(
            id: turnID,
            kind: .maintenance,
            transcriptRecorder: nil,
            fallbackTranscriptItems: [],
            onEvent: onEvent
        )

        do {
            let result = try await runManualCompact(
                id: turnID,
                onRequestBuilt: onRequestBuilt,
                onEvent: onEvent
            )
            if result.wasCancelled {
                return await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
            }
            latestContextUsage = result.contextUsage
            acknowledgeResolvedModelProfileTransition()
            await finishActiveTurn(id: turnID, status: .completed)
            return result
        } catch {
            if Self.isCancellationLikeError(error) {
                let result = MSPAgentRunResult(
                    finalAnswer: "",
                    toolResults: [],
                    transcriptAppendItems: [],
                    wasCancelled: true
                )
                return await completeCancelledTurn(
                    id: turnID,
                    result: result,
                    reason: .interrupted
                )
            }
            await finishActiveTurn(id: turnID, status: .failed)
            throw error
        }
    }

    public func snapshotTranscriptItems() -> [MSPAgentJSONValue] {
        transcriptItems
    }

    public func replaceTranscriptItems(_ items: [MSPAgentJSONValue]) {
        transcriptItems = items
        clearContextUsageForTranscriptReplacement()
    }

    public func resetTranscript() {
        transcriptItems.removeAll(keepingCapacity: true)
        clearContextUsageForTranscriptReplacement()
    }
}

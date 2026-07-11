import Foundation

public struct MSPAgentRuntime: Sendable {
    public typealias ModelClientFactory = @Sendable (MSPAgentConversationConfiguration) -> any MSPAgentModelTurnClient

    private let modelClientFactory: ModelClientFactory
    private let modelCatalog: any MSPModelCatalogResolving
    private let execCommandBridge: MSPExecCommandBridge
    private let applyPatchExecutor: (any MSPApplyPatchExecuting)?
    private let requestBuilder: MSPAgentRequestBuilder
    private let toolCallLimit: MSPAgentToolCallLimit

    public init(
        modelClientFactory: @escaping ModelClientFactory,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        toolCallLimit: MSPAgentToolCallLimit = .unlimited,
        modelCatalog: any MSPModelCatalogResolving = MSPModelCatalogManager.bundledOnly()
    ) {
        self.modelClientFactory = modelClientFactory
        self.modelCatalog = modelCatalog
        self.execCommandBridge = execCommandBridge
        self.applyPatchExecutor = applyPatchExecutor
        self.requestBuilder = requestBuilder
        self.toolCallLimit = toolCallLimit
    }

    public init(
        modelClientFactory: @escaping ModelClientFactory,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        maximumToolCalls: Int,
        modelCatalog: any MSPModelCatalogResolving = MSPModelCatalogManager.bundledOnly()
    ) {
        self.init(
            modelClientFactory: modelClientFactory,
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: .maximum(maximumToolCalls),
            modelCatalog: modelCatalog
        )
    }

    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        toolCallLimit: MSPAgentToolCallLimit = .unlimited,
        modelCatalog: (any MSPModelCatalogResolving)? = nil
    ) {
        let resolvedModelCatalog = modelCatalog
            ?? Self.defaultModelCatalog(for: modelConfiguration)
        self.init(
            modelClientFactory: { conversationConfiguration in
                var turnModelConfiguration = modelConfiguration
                turnModelConfiguration.model = conversationConfiguration.model
                return MSPResponsesStreamingModelClient(configuration: turnModelConfiguration)
            },
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: toolCallLimit,
            modelCatalog: resolvedModelCatalog
        )
    }

    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        maximumToolCalls: Int,
        modelCatalog: (any MSPModelCatalogResolving)? = nil
    ) {
        self.init(
            modelConfiguration: modelConfiguration,
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: .maximum(maximumToolCalls),
            modelCatalog: modelCatalog
        )
    }

    public func makeConversation(
        configuration: MSPAgentConversationConfiguration
    ) -> MSPAgentConversation {
        makeConversation(
            configuration: configuration,
            chatID: UUID().uuidString,
            chatNamingCoordinator: nil,
            schedulesInitialChatNamingOnFirstSend: true
        )
    }

    public func makeConversation(
        configuration: MSPAgentConversationConfiguration,
        chatID: String,
        chatNamingCoordinator: MSPChatNamingCoordinator? = nil
    ) -> MSPAgentConversation {
        makeConversation(
            configuration: configuration,
            chatID: chatID,
            chatNamingCoordinator: chatNamingCoordinator,
            schedulesInitialChatNamingOnFirstSend: true
        )
    }

    /// Low-level ChatNaming lifecycle wiring. Persisted `.chat` hosts should
    /// prefer the `MSPAgentChatNamingIntegration` overload from
    /// `MSPAgentChatStore`. Pass `false` only when another path, such as
    /// historical backfill, already owns initial naming.
    public func makeConversation(
        configuration: MSPAgentConversationConfiguration,
        chatID: String,
        chatNamingCoordinator: MSPChatNamingCoordinator?,
        schedulesInitialChatNamingOnFirstSend: Bool
    ) -> MSPAgentConversation {
        makeConversation(
            configuration: configuration,
            compactionHooks: MSPNoopCompactionLifecycleHookRuntime(),
            chatID: chatID,
            chatNamingCoordinator: chatNamingCoordinator,
            schedulesInitialChatNamingOnFirstSend:
                schedulesInitialChatNamingOnFirstSend
        )
    }

    func makeConversation(
        configuration: MSPAgentConversationConfiguration,
        compactionHooks: any MSPCompactionLifecycleHookRuntime,
        compactionPersistenceAdapter: any MSPCompactionPersistenceAdapter = MSPNoopCompactionPersistenceAdapter(),
        chatID: String = UUID().uuidString,
        chatNamingCoordinator: MSPChatNamingCoordinator? = nil,
        schedulesInitialChatNamingOnFirstSend: Bool = true
    ) -> MSPAgentConversation {
        MSPAgentConversation(
            configuration: configuration,
            modelCatalog: modelCatalog,
            modelClient: modelClientFactory(configuration),
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: toolCallLimit,
            compactionHooks: compactionHooks,
            compactionPersistenceAdapter: compactionPersistenceAdapter,
            chatNamingCoordinator: chatNamingCoordinator,
            schedulesInitialChatNamingOnFirstSend:
                schedulesInitialChatNamingOnFirstSend,
            chatID: chatID
        )
    }

    private static func defaultModelCatalog(
        for configuration: MSPAgentModelConfiguration
    ) -> any MSPModelCatalogResolving {
        return MSPModelCatalogManager.responses(configuration: configuration)
    }
}

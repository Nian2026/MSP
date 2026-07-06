import Foundation

public struct MSPAgentRuntime: Sendable {
    public typealias ModelClientFactory = @Sendable (MSPAgentConversationConfiguration) -> any MSPAgentModelTurnClient

    private let modelClientFactory: ModelClientFactory
    private let execCommandBridge: MSPExecCommandBridge
    private let applyPatchExecutor: (any MSPApplyPatchExecuting)?
    private let requestBuilder: MSPAgentRequestBuilder
    private let toolCallLimit: MSPAgentToolCallLimit

    public init(
        modelClientFactory: @escaping ModelClientFactory,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        toolCallLimit: MSPAgentToolCallLimit = .unlimited
    ) {
        self.modelClientFactory = modelClientFactory
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
        maximumToolCalls: Int
    ) {
        self.init(
            modelClientFactory: modelClientFactory,
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: .maximum(maximumToolCalls)
        )
    }

    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        toolCallLimit: MSPAgentToolCallLimit = .unlimited
    ) {
        self.init(
            modelClientFactory: { _ in
                MSPResponsesStreamingModelClient(configuration: modelConfiguration)
            },
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: toolCallLimit
        )
    }

    public init(
        modelConfiguration: MSPAgentModelConfiguration,
        execCommandBridge: MSPExecCommandBridge,
        applyPatchExecutor: (any MSPApplyPatchExecuting)? = nil,
        requestBuilder: MSPAgentRequestBuilder = MSPAgentRequestBuilder(),
        maximumToolCalls: Int
    ) {
        self.init(
            modelConfiguration: modelConfiguration,
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: .maximum(maximumToolCalls)
        )
    }

    public func makeConversation(
        configuration: MSPAgentConversationConfiguration
    ) -> MSPAgentConversation {
        makeConversation(
            configuration: configuration,
            compactionHooks: MSPNoopCompactionLifecycleHookRuntime()
        )
    }

    func makeConversation(
        configuration: MSPAgentConversationConfiguration,
        compactionHooks: any MSPCompactionLifecycleHookRuntime,
        compactionPersistenceAdapter: any MSPCompactionPersistenceAdapter = MSPNoopCompactionPersistenceAdapter()
    ) -> MSPAgentConversation {
        MSPAgentConversation(
            configuration: configuration,
            modelClient: modelClientFactory(configuration),
            execCommandBridge: execCommandBridge,
            applyPatchExecutor: applyPatchExecutor,
            requestBuilder: requestBuilder,
            toolCallLimit: toolCallLimit,
            compactionHooks: compactionHooks,
            compactionPersistenceAdapter: compactionPersistenceAdapter
        )
    }
}

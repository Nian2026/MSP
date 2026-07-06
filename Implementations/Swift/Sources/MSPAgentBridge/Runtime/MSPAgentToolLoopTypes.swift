public enum MSPAgentToolCallLimit: Sendable, Equatable {
    case unlimited
    case maximum(Int)

    public static func limited(to count: Int) -> MSPAgentToolCallLimit {
        .maximum(count)
    }

    var remainingToolCalls: Int? {
        switch self {
        case .unlimited:
            return nil
        case .maximum(let count):
            return max(0, count)
        }
    }
}

extension MSPAgentToolLoop {
    public typealias EventHandler = @Sendable (MSPAgentEvent) async -> Void
    public typealias ToolExecutor = @Sendable (MSPAgentToolCall) async -> MSPAgentToolResult
    public typealias MidTurnCompactionHandler = @Sendable (MidTurnCompactionContext) async throws -> MidTurnCompactionUpdate?
    public typealias PendingInputProvider = @Sendable (PendingInputRequest) async -> [MSPAgentJSONValue]

    public enum PendingInputRequest: Sendable {
        case peek
        case drain
    }

    public struct MidTurnCompactionContext: Sendable {
        public var liveInput: [MSPAgentJSONValue]
        public var transcriptAppendItems: [MSPAgentJSONValue]
        public var latestContextUsage: MSPAgentContextUsageRecord?
        public var modelNeedsFollowUp: Bool
        public var hasPendingInput: Bool
        public var preserveTranscriptAppendItems: Bool

        public init(
            liveInput: [MSPAgentJSONValue],
            transcriptAppendItems: [MSPAgentJSONValue],
            latestContextUsage: MSPAgentContextUsageRecord?,
            modelNeedsFollowUp: Bool = true,
            hasPendingInput: Bool = false,
            preserveTranscriptAppendItems: Bool = false
        ) {
            self.liveInput = liveInput
            self.transcriptAppendItems = transcriptAppendItems
            self.latestContextUsage = latestContextUsage
            self.modelNeedsFollowUp = modelNeedsFollowUp
            self.hasPendingInput = hasPendingInput
            self.preserveTranscriptAppendItems = preserveTranscriptAppendItems
        }
    }

    public struct MidTurnCompactionUpdate: Sendable {
        public var liveInput: [MSPAgentJSONValue]
        public var transcriptAppendItems: [MSPAgentJSONValue]
        public var contextUsage: MSPAgentContextUsageRecord?
        public var canDrainPendingInput: Bool

        public init(
            liveInput: [MSPAgentJSONValue],
            transcriptAppendItems: [MSPAgentJSONValue],
            contextUsage: MSPAgentContextUsageRecord?,
            canDrainPendingInput: Bool = false
        ) {
            self.liveInput = liveInput
            self.transcriptAppendItems = transcriptAppendItems
            self.contextUsage = contextUsage
            self.canDrainPendingInput = canDrainPendingInput
        }
    }

    public struct DynamicDeveloperContext: Sendable {
        public var blocks: [MSPAgentDynamicDeveloperContextBlock]
        public var contentStartIndex: Int

        public init(
            blocks: [MSPAgentDynamicDeveloperContextBlock] = [],
            contentStartIndex: Int = 0
        ) {
            self.blocks = blocks
            self.contentStartIndex = max(0, contentStartIndex)
        }

        var isEmpty: Bool {
            blocks.isEmpty
        }
    }
}

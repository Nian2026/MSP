import Foundation

public struct MSPAgentModelConfiguration: Hashable, Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var providerName: String
    public var additionalHTTPHeaders: [String: String]
    public var supportsRequestMetadata: Bool

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        providerName: String = "OpenAI",
        additionalHTTPHeaders: [String: String] = [:]
    ) {
        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            providerName: providerName,
            additionalHTTPHeaders: additionalHTTPHeaders,
            supportsRequestMetadata: false
        )
    }

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        providerName: String = "OpenAI",
        additionalHTTPHeaders: [String: String] = [:],
        supportsRequestMetadata: Bool
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.providerName = providerName
        self.additionalHTTPHeaders = additionalHTTPHeaders
        self.supportsRequestMetadata = supportsRequestMetadata
    }

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        additionalHTTPHeaders: [String: String]
    ) {
        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            providerName: "OpenAI",
            additionalHTTPHeaders: additionalHTTPHeaders,
            supportsRequestMetadata: false
        )
    }

    public init(
        baseURL: URL,
        apiKey: String,
        model: String,
        additionalHTTPHeaders: [String: String],
        supportsRequestMetadata: Bool
    ) {
        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            providerName: "OpenAI",
            additionalHTTPHeaders: additionalHTTPHeaders,
            supportsRequestMetadata: supportsRequestMetadata
        )
    }
}

public struct MSPAgentRequestEnvelope: Hashable, Sendable {
    public var payload: [String: MSPAgentJSONValue]
    public var input: [MSPAgentJSONValue]

    public init(
        payload: [String: MSPAgentJSONValue],
        input: [MSPAgentJSONValue]
    ) {
        self.payload = payload
        self.input = input
    }

    public func replacingInput(_ input: [MSPAgentJSONValue]) -> MSPAgentRequestEnvelope {
        MSPAgentRequestEnvelope(payload: payload, input: input)
    }

    public func replacingPayload(_ payload: [String: MSPAgentJSONValue]) -> MSPAgentRequestEnvelope {
        MSPAgentRequestEnvelope(payload: payload, input: input)
    }
}

public struct MSPAgentToolName: RawRepresentable, Codable, Hashable, Sendable {
    public static let execCommand = MSPAgentToolName(rawValue: MSPExecCommandToolSchema.name)
    public static let writeStdin = MSPAgentToolName(rawValue: MSPWriteStdinToolSchema.name)
    public static let applyPatch = MSPAgentToolName(rawValue: MSPApplyPatchToolSchema.name)
    public static let updatePlan = MSPAgentToolName(rawValue: MSPUpdatePlanToolSchema.name)
    public static let getGoal = MSPAgentToolName(rawValue: MSPGoalTools.getGoalName)
    public static let createGoal = MSPAgentToolName(rawValue: MSPGoalTools.createGoalName)
    public static let updateGoal = MSPAgentToolName(rawValue: MSPGoalTools.updateGoalName)

    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(apiName: String) {
        self.init(rawValue: apiName)
    }
}

public enum MSPAgentToolCallKind: String, Codable, Hashable, Sendable {
    case function
    case custom
}

public enum MSPAgentToolOutputKind: String, Codable, Hashable, Sendable {
    case function
    case custom
}

public struct MSPAgentToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: MSPAgentToolName
    public var kind: MSPAgentToolCallKind
    public var rawArguments: String?
    public var arguments: [String: MSPAgentJSONValue]
    public var input: String?

    public init(
        id: String = UUID().uuidString,
        name: MSPAgentToolName,
        kind: MSPAgentToolCallKind = .function,
        rawArguments: String? = nil,
        arguments: [String: MSPAgentJSONValue] = [:],
        input: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rawArguments = rawArguments
        self.arguments = arguments
        self.input = input
    }

    public var outputKind: MSPAgentToolOutputKind {
        kind == .custom ? .custom : .function
    }
}

public struct MSPAgentToolResult: Codable, Hashable, Sendable {
    public var callID: String
    public var name: MSPAgentToolName
    public var outputKind: MSPAgentToolOutputKind
    public var ok: Bool
    public var content: MSPAgentJSONValue?
    public var internalContent: MSPAgentJSONValue?
    public var modelOutputContent: MSPAgentJSONValue?
    public var errorMessage: String?

    public init(
        callID: String,
        name: MSPAgentToolName,
        outputKind: MSPAgentToolOutputKind = .function,
        ok: Bool,
        content: MSPAgentJSONValue?,
        internalContent: MSPAgentJSONValue? = nil,
        modelOutputContent: MSPAgentJSONValue? = nil,
        errorMessage: String?
    ) {
        self.callID = callID
        self.name = name
        self.outputKind = outputKind
        self.ok = ok
        self.content = content
        self.internalContent = internalContent
        self.modelOutputContent = modelOutputContent
        self.errorMessage = errorMessage
    }
}

public struct MSPAgentProbeEvent: Hashable, Sendable {
    public var name: String
    public var fields: [String: String]

    public init(name: String, fields: [String: String] = [:]) {
        self.name = name
        self.fields = fields
    }
}

public struct MSPAgentModelStreamDelta: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case assistantMessage
        case finalAnswer
        case unknown
    }

    public var text: String
    public var phase: Phase
    public var itemID: String?
    public var outputIndex: Int?

    public init(
        text: String,
        phase: Phase,
        itemID: String? = nil,
        outputIndex: Int? = nil
    ) {
        self.text = text
        self.phase = phase
        self.itemID = itemID
        self.outputIndex = outputIndex
    }
}

public struct MSPAgentTokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct MSPAgentContextWindowProfile: Codable, Hashable, Sendable {
    public var modelID: String
    public var modelFamily: String
    public var contextWindowTokens: Int
    public var effectiveContextWindowTokens: Int
    public var autoCompactTokenLimit: Int

    public init(
        modelID: String,
        modelFamily: String,
        contextWindowTokens: Int,
        effectiveContextWindowTokens: Int,
        autoCompactTokenLimit: Int
    ) {
        self.modelID = modelID
        self.modelFamily = modelFamily
        self.contextWindowTokens = contextWindowTokens
        self.effectiveContextWindowTokens = effectiveContextWindowTokens
        self.autoCompactTokenLimit = autoCompactTokenLimit
    }

    public static func profile(for modelID: String) -> MSPAgentContextWindowProfile? {
        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let modelComponent = normalizedModelID
            .replacingOccurrences(of: "｜", with: "|")
            .components(separatedBy: CharacterSet(charactersIn: "/|:"))
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? normalizedModelID
        guard modelComponent.hasPrefix("gpt-5") else { return nil }

        let contextWindowTokens = 272_000
        return MSPAgentContextWindowProfile(
            modelID: modelID,
            modelFamily: "gpt-5",
            contextWindowTokens: contextWindowTokens,
            effectiveContextWindowTokens: contextWindowTokens * 95 / 100,
            autoCompactTokenLimit: contextWindowTokens * 9 / 10
        )
    }
}

public enum MSPAgentContextUsageLevel: String, Codable, Hashable, Sendable {
    case low
    case moderate
    case high
    case critical
}

public struct MSPAgentContextUsageRecord: Codable, Hashable, Sendable {
    public var modelID: String
    public var modelDisplayName: String
    public var contextWindowTokens: Int
    public var effectiveContextWindowTokens: Int
    public var autoCompactTokenLimit: Int
    public var estimatedInputTokens: Int
    public var currentTokens: Int
    public var serverInputTokens: Int?
    public var serverCachedInputTokens: Int?
    public var serverOutputTokens: Int?
    public var serverTotalTokens: Int?
    public var measuredAt: Date

    public init(
        modelID: String,
        modelDisplayName: String,
        contextWindowTokens: Int,
        effectiveContextWindowTokens: Int,
        autoCompactTokenLimit: Int,
        estimatedInputTokens: Int,
        currentTokens: Int,
        serverInputTokens: Int?,
        serverCachedInputTokens: Int? = nil,
        serverOutputTokens: Int?,
        serverTotalTokens: Int?,
        measuredAt: Date = Date()
    ) {
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.contextWindowTokens = contextWindowTokens
        self.effectiveContextWindowTokens = effectiveContextWindowTokens
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.estimatedInputTokens = estimatedInputTokens
        self.currentTokens = currentTokens
        self.serverInputTokens = serverInputTokens
        self.serverCachedInputTokens = serverCachedInputTokens
        self.serverOutputTokens = serverOutputTokens
        self.serverTotalTokens = serverTotalTokens
        self.measuredAt = measuredAt
    }

    public var currentWindowFraction: Double? {
        guard contextWindowTokens > 0 else { return nil }
        return Double(currentTokens) / Double(contextWindowTokens)
    }

    public var currentUsageLevel: MSPAgentContextUsageLevel? {
        guard let currentWindowFraction else { return nil }
        return Self.usageLevel(forWindowFraction: currentWindowFraction)
    }

    public var serverInputWindowFraction: Double? {
        guard let serverInputTokens, contextWindowTokens > 0 else { return nil }
        return Double(serverInputTokens) / Double(contextWindowTokens)
    }

    public var serverInputUsageLevel: MSPAgentContextUsageLevel? {
        guard let serverInputWindowFraction else { return nil }
        return Self.usageLevel(forWindowFraction: serverInputWindowFraction)
    }

    public static func usageLevel(forWindowFraction rawFraction: Double) -> MSPAgentContextUsageLevel {
        let fraction = min(max(rawFraction, 0), 1)
        if fraction < 0.4 {
            return .low
        }
        if fraction < 0.6 {
            return .moderate
        }
        if fraction < 0.8 {
            return .high
        }
        return .critical
    }
}

public enum MSPAgentContextUsageAdapter {
    public static func fullWindowRecord(
        modelID: String,
        modelDisplayName: String? = nil,
        measuredAt: Date = Date()
    ) -> MSPAgentContextUsageRecord? {
        guard let profile = MSPAgentContextWindowProfile.profile(for: modelID) else {
            return nil
        }
        let displayName = modelDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName: String
        if let displayName, !displayName.isEmpty {
            resolvedDisplayName = displayName
        } else {
            resolvedDisplayName = modelID
        }

        return MSPAgentContextUsageRecord(
            modelID: modelID,
            modelDisplayName: resolvedDisplayName,
            contextWindowTokens: profile.contextWindowTokens,
            effectiveContextWindowTokens: profile.effectiveContextWindowTokens,
            autoCompactTokenLimit: profile.autoCompactTokenLimit,
            estimatedInputTokens: profile.contextWindowTokens,
            currentTokens: profile.contextWindowTokens,
            serverInputTokens: nil,
            serverOutputTokens: nil,
            serverTotalTokens: nil,
            measuredAt: measuredAt
        )
    }

    public static func record(
        usage: MSPAgentTokenUsage?,
        modelID: String,
        modelDisplayName: String? = nil,
        measuredAt: Date = Date()
    ) -> MSPAgentContextUsageRecord? {
        guard let usage,
              let profile = MSPAgentContextWindowProfile.profile(for: modelID) else {
            return nil
        }

        let inputTokens = usage.inputTokens.map { max(0, $0) }
        let cachedInputTokens = usage.cachedInputTokens.map { max(0, $0) }
        let outputTokens = usage.outputTokens.map { max(0, $0) }
        let serverTotalTokens = usage.totalTokens.map { max(0, $0) }
            ?? inputTokens.flatMap { input in
                outputTokens.map { input + $0 }
            }
        let currentTokens = serverTotalTokens ?? inputTokens ?? 0
        let displayName = modelDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName: String
        if let displayName, !displayName.isEmpty {
            resolvedDisplayName = displayName
        } else {
            resolvedDisplayName = modelID
        }

        return MSPAgentContextUsageRecord(
            modelID: modelID,
            modelDisplayName: resolvedDisplayName,
            contextWindowTokens: profile.contextWindowTokens,
            effectiveContextWindowTokens: profile.effectiveContextWindowTokens,
            autoCompactTokenLimit: profile.autoCompactTokenLimit,
            estimatedInputTokens: 0,
            currentTokens: max(0, currentTokens),
            serverInputTokens: inputTokens,
            serverCachedInputTokens: cachedInputTokens,
            serverOutputTokens: outputTokens,
            serverTotalTokens: serverTotalTokens,
            measuredAt: measuredAt
        )
    }
}

public struct MSPAgentModelTurnOutput: Sendable {
    public var assistantMessage: String?
    public var toolCalls: [MSPAgentToolCall]
    public var finalAnswer: String?
    public var responseID: String?
    public var nativeOutputItems: [MSPAgentJSONValue]
    public var tokenUsage: MSPAgentTokenUsage?
    public var sawCompleted: Bool

    public init(
        assistantMessage: String? = nil,
        toolCalls: [MSPAgentToolCall] = [],
        finalAnswer: String? = nil,
        responseID: String? = nil,
        nativeOutputItems: [MSPAgentJSONValue] = [],
        tokenUsage: MSPAgentTokenUsage? = nil,
        sawCompleted: Bool = false
    ) {
        self.assistantMessage = assistantMessage
        self.toolCalls = toolCalls
        self.finalAnswer = finalAnswer
        self.responseID = responseID
        self.nativeOutputItems = nativeOutputItems
        self.tokenUsage = tokenUsage
        self.sawCompleted = sawCompleted
    }
}

public enum MSPAgentModelClientError: LocalizedError {
    case invalidBaseURL
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case apiError(String)
    case contextWindowExceeded(String)
    case invalidStreamPayload(String)
    case invalidToolArguments(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Model base URL is invalid."
        case .invalidHTTPResponse:
            return "The model provider returned an invalid HTTP response."
        case let .httpStatus(status, message):
            return "The model provider returned HTTP \(status): \(message)"
        case let .apiError(message):
            return message
        case let .contextWindowExceeded(message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying."
            }
            return trimmed
        case let .invalidStreamPayload(payload):
            return "The model provider returned an unparseable stream payload: \(payload)"
        case let .invalidToolArguments(message):
            return message
        case let .unknownTool(name):
            return "The model requested an unknown tool: \(name)"
        }
    }
}

extension MSPAgentModelClientError {
    static func isLikelyContextWindowExceeded(_ error: Error) -> Bool {
        if let clientError = error as? MSPAgentModelClientError {
            switch clientError {
            case .contextWindowExceeded:
                return true
            case let .httpStatus(_, message),
                 let .apiError(message),
                 let .invalidStreamPayload(message):
                return isLikelyContextWindowExceededMessage(message)
            case .invalidBaseURL,
                 .invalidHTTPResponse:
                break
            case .invalidToolArguments(_),
                 .unknownTool(_):
                break
            }
        }

        return isLikelyContextWindowExceededMessage(
            (error as NSError).localizedDescription
        )
    }

    static func isLikelyContextWindowExceededMessage(_ message: String) -> Bool {
        let text = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else {
            return false
        }
        return text.contains("context_length_exceeded")
            || text.contains("context window")
            || text.contains("input exceeds")
            || text.contains("maximum context")
            || text.contains("too many tokens")
    }
}

public protocol MSPAgentModelTurnClient: Sendable {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput
}

protocol MSPAgentRemoteCompactionClient: Sendable {
    var supportsRemoteCompaction: Bool { get }
    var supportsRequestMetadata: Bool { get }

    func compactConversation(
        payload: MSPRemoteCompactPayload
    ) async throws -> [MSPAgentJSONValue]
}

public enum MSPAgentEvent: Hashable, Sendable {
    case turnStarted(MSPTurnInterruptTurnStartedEvent)
    case turnAborted(MSPTurnInterruptTurnAbortedEvent)
    case turnSteerAccepted(MSPTurnSteerAcceptedEvent)
    case turnSteerApplied(MSPTurnSteerAppliedEvent)
    case threadGoalUpdated(MSPGoalUpdatedEvent)
    case threadGoalCleared(MSPGoalClearedEvent)
    case threadGoalAccounted(MSPGoalAccountedEvent)
    case planProgressUpdated(MSPPlanProgressUpdatedEvent)
    case planModeProposalDelta(MSPPlanModeProposalDeltaEvent)
    case planModeProposed(MSPPlanModeProposedEvent)
    case planModeApproved(MSPPlanModeDecisionEvent)
    case planModeRejected(MSPPlanModeDecisionEvent)
    case planModeModified(MSPPlanModeDecisionEvent)
    case planModeHandoff(MSPPlanModeHandoffEvent)
    case compactTurnStarted(UUID)
    case contextCompactionStarted(String)
    case contextCompactionCompleted(String)
    case contextCompactionFailed(String, message: String)
    case compactionWarning(String)
    case modelRequestPreparing(statusText: String)
    case assistantProgressSegmentStarted(UUID)
    case assistantProgressDelta(String)
    case assistantProgress(String)
    case toolPreparing(MSPAgentToolName, statusText: String)
    case toolStarted(MSPAgentToolCall, statusText: String, batchID: UUID)
    case toolOutputDelta(
        callID: String,
        name: MSPAgentToolName,
        stream: MSPExecCommandOutputStreamName,
        text: String
    )
    case toolCompleted(MSPAgentToolResult, batchID: UUID)
    case finalAnswerStarted
    case finalAnswerDelta(String)
    case finalAnswer(String)
    case contextUsageUpdated(MSPAgentContextUsageRecord)
    case modelStreamRetrying(statusText: String)
    case probe(MSPAgentProbeEvent)
}

public struct MSPAgentRunResult: Hashable, Sendable {
    public var finalAnswer: String
    public var toolResults: [MSPAgentToolResult]
    public var responseID: String?
    public var transcriptAppendItems: [MSPAgentJSONValue]
    public var wasCancelled: Bool
    public var contextUsage: MSPAgentContextUsageRecord?
    public var planModeProposalContent: String?

    public init(
        finalAnswer: String,
        toolResults: [MSPAgentToolResult],
        responseID: String? = nil,
        transcriptAppendItems: [MSPAgentJSONValue] = [],
        wasCancelled: Bool = false,
        contextUsage: MSPAgentContextUsageRecord? = nil,
        planModeProposalContent: String? = nil
    ) {
        self.finalAnswer = finalAnswer
        self.toolResults = toolResults
        self.responseID = responseID
        self.transcriptAppendItems = transcriptAppendItems
        self.wasCancelled = wasCancelled
        self.contextUsage = contextUsage
        self.planModeProposalContent = planModeProposalContent
    }
}

public enum MSPAgentInterruptedTurnMarker {
    public static let interruptedGuidance =
        "The previous turn was interrupted on purpose. Any running workspace commands may still be running in the background. If any tools/commands were aborted, they may have partially executed."

    public static var text: String {
        """
        <turn_aborted>
        \(interruptedGuidance)
        </turn_aborted>
        """
    }

    public static func inputItem() -> MSPAgentJSONValue {
        MSPTurnInterruptChatMapping.interruptedMarkerInputItem()
    }
}

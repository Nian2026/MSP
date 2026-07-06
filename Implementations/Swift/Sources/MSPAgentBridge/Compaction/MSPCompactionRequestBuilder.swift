import Foundation

struct MSPCompactionRequestMetadata: Codable, Hashable, Sendable {
    var requestKind: String
    var compaction: MSPCompactionDecision
    var windowID: String?
    var turnID: String?

    enum CodingKeys: String, CodingKey {
        case requestKind = "request_kind"
        case compaction
        case windowID = "window_id"
        case turnID = "turn_id"
    }

    init(
        compaction: MSPCompactionDecision,
        windowID: String? = nil,
        turnID: String? = nil
    ) {
        self.requestKind = "compaction"
        self.compaction = compaction
        self.windowID = windowID
        self.turnID = turnID
    }
}

struct MSPRemoteCompactPayload: Hashable, Sendable {
    var endpoint: String
    var body: [String: MSPAgentJSONValue]
    var timeoutIdleMultiplier: Int
}

struct MSPRemoteCompactInputRewriteResult: Hashable, Sendable {
    var input: [MSPAgentJSONValue]
    var rewrittenOutputCount: Int
    var estimatedDeletedTokens: Int
}

struct MSPLocalCompactHistoryRewriteResult: Hashable, Sendable {
    var historyItems: [MSPAgentJSONValue]
    var rewrittenOutputCount: Int
    var estimatedDeletedTokens: Int
}

enum MSPRemoteCompactRequestBuildError: Error, Equatable, LocalizedError {
    case missingModel

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Remote compact payload requires a model value."
        }
    }
}

struct MSPCompactionRequestBuilder: Sendable {
    static let remoteCompactEndpoint = "/responses/compact"
    static let remoteCompactTimeoutIdleMultiplier = 4
    static let remoteCompactTruncatedOutputMessage =
        "Output exceeded the available model context and was truncated"

    static let summarizationPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """

    func localPromptItem(prompt: String = summarizationPrompt) -> MSPAgentJSONValue {
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
    }

    func metadataValue(
        decision: MSPCompactionDecision,
        windowID: String? = nil,
        turnID: String? = nil
    ) throws -> MSPAgentJSONValue {
        try MSPAgentJSONValue(encoding: MSPCompactionRequestMetadata(
            compaction: decision,
            windowID: windowID,
            turnID: turnID
        ))
    }

    func applyingCompactionMetadata(
        to envelope: MSPAgentRequestEnvelope,
        decision: MSPCompactionDecision,
        windowID: String? = nil,
        turnID: String? = nil
    ) throws -> MSPAgentRequestEnvelope {
        var payload = envelope.payload
        payload["metadata"] = try metadataValue(
            decision: decision,
            windowID: windowID,
            turnID: turnID
        )
        return envelope.replacingPayload(payload)
    }

    func remoteCompactPayload(
        from envelope: MSPAgentRequestEnvelope,
        serviceTier: String? = nil,
        includeMetadata: Bool = false
    ) throws -> MSPRemoteCompactPayload {
        guard let model = envelope.payload["model"] else {
            throw MSPRemoteCompactRequestBuildError.missingModel
        }

        var body: [String: MSPAgentJSONValue] = [
            "model": model,
            "input": .array(envelope.input),
            "parallel_tool_calls": envelope.payload["parallel_tool_calls"] ?? .bool(false)
        ]

        if let instructions = envelope.payload["instructions"],
           instructions.stringValue?.isEmpty != true {
            body["instructions"] = instructions
        }
        if let tools = envelope.payload["tools"],
           tools != .null,
           tools.arrayValue?.isEmpty != true {
            body["tools"] = tools
        }
        if let reasoning = envelope.payload["reasoning"], reasoning != .null {
            body["reasoning"] = reasoning
        }
        if let serviceTier {
            body["service_tier"] = .string(serviceTier)
        } else if let serviceTier = envelope.payload["service_tier"], serviceTier != .null {
            body["service_tier"] = serviceTier
        }
        if let promptCacheKey = envelope.payload["prompt_cache_key"], promptCacheKey != .null {
            body["prompt_cache_key"] = promptCacheKey
        }
        if let text = envelope.payload["text"], text != .null {
            body["text"] = text
        }
        if includeMetadata,
           let metadata = envelope.payload["metadata"],
           metadata != .null {
            body["metadata"] = metadata
        }

        return MSPRemoteCompactPayload(
            endpoint: Self.remoteCompactEndpoint,
            body: body,
            timeoutIdleMultiplier: Self.remoteCompactTimeoutIdleMultiplier
        )
    }

    func remoteCompactInputByRewritingOutputsToFitContextWindow(
        _ input: [MSPAgentJSONValue],
        contextWindow: Int?,
        estimatedTokenCount: ([MSPAgentJSONValue]) -> Int?
    ) -> MSPRemoteCompactInputRewriteResult {
        guard let contextWindow else {
            return MSPRemoteCompactInputRewriteResult(
                input: input,
                rewrittenOutputCount: 0,
                estimatedDeletedTokens: 0
            )
        }

        var rewritten = input
        var rewrittenOutputCount = 0
        var estimatedDeletedTokens = 0

        for index in rewritten.indices.reversed() {
            guard let estimatedTokensBefore = estimatedTokenCount(rewritten) else {
                break
            }
            guard estimatedTokensBefore > contextWindow else {
                break
            }
            guard let rewrittenItem = Self.rewrittenOutputForContextWindow(rewritten[index]) else {
                break
            }

            rewritten[index] = rewrittenItem
            let estimatedTokensAfter = estimatedTokenCount(rewritten) ?? 0
            rewrittenOutputCount += 1
            estimatedDeletedTokens += max(0, estimatedTokensBefore - estimatedTokensAfter)
        }

        return MSPRemoteCompactInputRewriteResult(
            input: rewritten,
            rewrittenOutputCount: rewrittenOutputCount,
            estimatedDeletedTokens: estimatedDeletedTokens
        )
    }

    func localCompactHistoryByRewritingOutputsToFitContextWindow(
        prefixItems: [MSPAgentJSONValue],
        historyItems: [MSPAgentJSONValue],
        suffixItems: [MSPAgentJSONValue],
        contextWindow: Int?,
        estimatedTokenCount: ([MSPAgentJSONValue]) -> Int?
    ) -> MSPLocalCompactHistoryRewriteResult {
        guard let contextWindow else {
            return MSPLocalCompactHistoryRewriteResult(
                historyItems: historyItems,
                rewrittenOutputCount: 0,
                estimatedDeletedTokens: 0
            )
        }

        var rewritten = historyItems
        var rewrittenOutputCount = 0
        var estimatedDeletedTokens = 0

        for index in rewritten.indices.reversed() {
            let inputBefore = prefixItems + rewritten + suffixItems
            guard let estimatedTokensBefore = estimatedTokenCount(inputBefore) else {
                break
            }
            guard estimatedTokensBefore > contextWindow else {
                break
            }
            guard let rewrittenItem = Self.rewrittenOutputForContextWindow(rewritten[index]) else {
                break
            }

            rewritten[index] = rewrittenItem
            let estimatedTokensAfter = estimatedTokenCount(prefixItems + rewritten + suffixItems) ?? 0
            rewrittenOutputCount += 1
            estimatedDeletedTokens += max(0, estimatedTokensBefore - estimatedTokensAfter)
        }

        return MSPLocalCompactHistoryRewriteResult(
            historyItems: rewritten,
            rewrittenOutputCount: rewrittenOutputCount,
            estimatedDeletedTokens: estimatedDeletedTokens
        )
    }

    func remoteV2Input(promptInput: [MSPAgentJSONValue]) -> [MSPAgentJSONValue] {
        promptInput + [Self.compactionTriggerItem()]
    }

    static func compactionTriggerItem() -> MSPAgentJSONValue {
        .object([
            "type": .string("compaction_trigger")
        ])
    }

    static func isCompactionTrigger(_ item: MSPAgentJSONValue) -> Bool {
        item.objectValue?["type"]?.stringValue == "compaction_trigger"
    }

    static func collectRemoteV2Output(
        outputItems: [MSPAgentJSONValue],
        sawCompleted: Bool,
        tokenUsage: MSPAgentTokenUsage? = nil
    ) throws -> MSPRemoteCompactionV2Output {
        guard sawCompleted else {
            throw MSPRemoteCompactionV2Error.streamClosedBeforeCompleted
        }

        let compactionItems = outputItems.filter(Self.isCompactionOutput)
        guard compactionItems.count == 1 else {
            throw MSPRemoteCompactionV2Error.invalidCompactionOutputCount(
                compactionCount: compactionItems.count,
                outputItemCount: outputItems.count
            )
        }

        return MSPRemoteCompactionV2Output(
            compactionOutput: compactionItems[0],
            tokenUsage: tokenUsage
        )
    }

    private static func isCompactionOutput(_ item: MSPAgentJSONValue) -> Bool {
        guard let type = item.objectValue?["type"]?.stringValue else {
            return false
        }
        return type == "compaction" || type == "compaction_summary"
    }

    private static func rewrittenOutputForContextWindow(
        _ item: MSPAgentJSONValue
    ) -> MSPAgentJSONValue? {
        guard var object = item.objectValue,
              let type = object["type"]?.stringValue else {
            return nil
        }

        switch type {
        case "function_call_output", "custom_tool_call_output":
            object["output"] = .string(remoteCompactTruncatedOutputMessage)
            return .object(object)
        case "tool_search_output":
            object["tools"] = .array([])
            return .object(object)
        default:
            return nil
        }
    }
}

struct MSPRemoteCompactionV2Output: Hashable, Sendable {
    var compactionOutput: MSPAgentJSONValue
    var tokenUsage: MSPAgentTokenUsage?
}

enum MSPRemoteCompactionV2Error: Error, Equatable, LocalizedError {
    case streamClosedBeforeCompleted
    case invalidCompactionOutputCount(compactionCount: Int, outputItemCount: Int)

    var errorDescription: String? {
        switch self {
        case .streamClosedBeforeCompleted:
            return "Remote compaction v2 stream closed before response.completed."
        case let .invalidCompactionOutputCount(compactionCount, outputItemCount):
            return "Remote compaction v2 expected exactly one compaction output item, got \(compactionCount) from \(outputItemCount) output items."
        }
    }
}

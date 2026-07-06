import Foundation

struct MSPAgentPromptTranscriptProjection {
    var transcriptRevision: Int
    var items: [MSPAgentJSONValue]
    var estimatedTokenCount: Int
}

enum MSPAgentPromptTranscriptNormalizer {
    static let defaultMaxPromptToolOutputTokens = 6_000
    static let strictMaxPromptToolOutputTokens = 1_500

    static func normalizedItemsForPrompt(
        _ items: [MSPAgentJSONValue],
        maxToolOutputTokens: Int = defaultMaxPromptToolOutputTokens
    ) -> [MSPAgentJSONValue] {
        var normalized = items
        ensureToolCallOutputsPresent(in: &normalized)
        removeOrphanToolCallOutputs(from: &normalized)
        normalized = providerSafeItemsForPrompt(
            normalized,
            maxToolOutputTokens: maxToolOutputTokens
        )
        removeOrphanToolCallOutputs(from: &normalized)
        return normalized
    }

    static func providerSafeItemsForPrompt(
        _ items: [MSPAgentJSONValue],
        maxToolOutputTokens: Int = defaultMaxPromptToolOutputTokens
    ) -> [MSPAgentJSONValue] {
        items.map { providerSafePromptItem($0, maxToolOutputTokens: maxToolOutputTokens) }
    }

    static func incrementallyAppending(
        _ appendedItems: [MSPAgentJSONValue],
        to projection: MSPAgentPromptTranscriptProjection,
        nextTranscriptRevision: Int
    ) -> MSPAgentPromptTranscriptProjection? {
        guard !appendedItems.isEmpty else {
            var projection = projection
            projection.transcriptRevision = nextTranscriptRevision
            return projection
        }
        guard appendedToolCallOutputsAreSelfContained(appendedItems) else {
            return nil
        }

        var normalizedAppendedItems = appendedItems
        ensureToolCallOutputsPresent(in: &normalizedAppendedItems)
        normalizedAppendedItems = providerSafeItemsForPrompt(normalizedAppendedItems)
        removeOrphanToolCallOutputs(from: &normalizedAppendedItems)
        return MSPAgentPromptTranscriptProjection(
            transcriptRevision: nextTranscriptRevision,
            items: projection.items + normalizedAppendedItems,
            estimatedTokenCount: projection.estimatedTokenCount
                + MSPAgentConversation.approximateTokenCount(in: normalizedAppendedItems)
        )
    }

    private static func appendedToolCallOutputsAreSelfContained(
        _ items: [MSPAgentJSONValue]
    ) -> Bool {
        let callIDs = toolCallIDsByType(in: items)
        for item in items {
            guard let object = item.objectValue,
                  let outputType = object["type"]?.stringValue,
                  let expectedCallType = toolCallType(forOutputType: outputType) else {
                continue
            }
            guard let callID = object["call_id"]?.stringValue,
                  callIDs[expectedCallType, default: []].contains(callID) else {
                return false
            }
        }
        return true
    }

    private static func providerSafePromptItem(
        _ item: MSPAgentJSONValue,
        maxToolOutputTokens: Int
    ) -> MSPAgentJSONValue {
        guard var object = item.objectValue else {
            return item
        }
        switch object["type"]?.stringValue {
        case "message":
            normalizeProviderSafePhase(in: &object)
            normalizeProviderSafeID(in: &object)
            return .object(object)

        case "function_call_output", "custom_tool_call_output":
            normalizePromptToolOutput(in: &object, maxToolOutputTokens: maxToolOutputTokens)
            return .object(object)

        default:
            return item
        }
    }

    private static func normalizePromptToolOutput(
        in object: inout [String: MSPAgentJSONValue],
        maxToolOutputTokens: Int
    ) {
        guard let output = object["output"]?.stringValue else {
            return
        }
        let maxToolOutputTokens = max(0, maxToolOutputTokens)
        let originalTokens = MSPExecCommandOutputTruncation.approximateTokenCount(output)
        guard originalTokens > maxToolOutputTokens else {
            return
        }
        let truncated = MSPExecCommandOutputTruncation.formattedTruncateText(
            output,
            maxOutputTokens: maxToolOutputTokens
        )
        object["output"] = .string("""
        [MSP note: tool output was preserved in the durable transcript, but this model-visible copy was truncated from about \(originalTokens) tokens to fit the context window.]
        \(truncated)
        """)
    }

    private static func normalizeProviderSafePhase(in object: inout [String: MSPAgentJSONValue]) {
        guard object.keys.contains("phase") else {
            return
        }
        guard let rawPhase = object["phase"]?.stringValue else {
            object.removeValue(forKey: "phase")
            return
        }
        guard let phase = providerSafePhase(rawPhase) else {
            object.removeValue(forKey: "phase")
            return
        }
        object["phase"] = .string(phase)
    }

    private static func providerSafePhase(_ rawPhase: String) -> String? {
        switch rawPhase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "commentary", "interim", "assistant_message", "checkpoint":
            return "commentary"
        case "final_answer", "final":
            return "final_answer"
        default:
            return nil
        }
    }

    private static func normalizeProviderSafeID(in object: inout [String: MSPAgentJSONValue]) {
        guard object.keys.contains("id") else {
            return
        }
        guard let rawID = object["id"]?.stringValue else {
            object.removeValue(forKey: "id")
            return
        }

        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            object.removeValue(forKey: "id")
            return
        }

        // Provider-authored Responses message IDs begin with `msg`. Local
        // interrupted/cancelled snapshots are prompt messages and must not
        // masquerade as provider output items.
        guard id.hasPrefix("msg") else {
            object.removeValue(forKey: "id")
            return
        }

        if id != rawID {
            object["id"] = .string(id)
        }
    }

    private static func ensureToolCallOutputsPresent(
        in items: inout [MSPAgentJSONValue]
    ) {
        let outputCallIDs = toolOutputIDsByType(in: items)

        var missingOutputs: [(Int, MSPAgentJSONValue)] = []
        for (index, item) in items.enumerated() {
            guard let object = item.objectValue,
                  let callType = object["type"]?.stringValue,
                  let outputType = toolOutputType(forCallType: callType),
                  let callID = object["call_id"]?.stringValue,
                  !outputCallIDs[outputType, default: []].contains(callID) else {
                continue
            }
            missingOutputs.append((
                index,
                abortedToolOutputItem(callID: callID, outputType: outputType)
            ))
        }

        for (index, outputItem) in missingOutputs.reversed() {
            items.insert(outputItem, at: index + 1)
        }
    }

    private static func removeOrphanToolCallOutputs(
        from items: inout [MSPAgentJSONValue]
    ) {
        let callIDs = toolCallIDsByType(in: items)
        items.removeAll { item in
            guard let object = item.objectValue,
                  let outputType = object["type"]?.stringValue,
                  let expectedCallType = toolCallType(forOutputType: outputType) else {
                return false
            }
            guard let callID = object["call_id"]?.stringValue else {
                return true
            }
            return !callIDs[expectedCallType, default: []].contains(callID)
        }
    }

    private static func toolCallIDsByType(
        in items: [MSPAgentJSONValue]
    ) -> [String: Set<String>] {
        var callIDs: [String: Set<String>] = [:]
        for item in items {
            guard let object = item.objectValue,
                  let type = object["type"]?.stringValue,
                  toolOutputType(forCallType: type) != nil,
                  let callID = object["call_id"]?.stringValue else {
                continue
            }
            callIDs[type, default: []].insert(callID)
        }
        return callIDs
    }

    private static func toolOutputIDsByType(
        in items: [MSPAgentJSONValue]
    ) -> [String: Set<String>] {
        var outputIDs: [String: Set<String>] = [:]
        for item in items {
            guard let object = item.objectValue,
                  let type = object["type"]?.stringValue,
                  toolCallType(forOutputType: type) != nil,
                  let callID = object["call_id"]?.stringValue else {
                continue
            }
            outputIDs[type, default: []].insert(callID)
        }
        return outputIDs
    }

    private static func toolOutputType(forCallType callType: String) -> String? {
        switch callType {
        case "function_call":
            return "function_call_output"
        case "custom_tool_call":
            return "custom_tool_call_output"
        default:
            return nil
        }
    }

    private static func toolCallType(forOutputType outputType: String) -> String? {
        switch outputType {
        case "function_call_output":
            return "function_call"
        case "custom_tool_call_output":
            return "custom_tool_call"
        default:
            return nil
        }
    }

    private static func abortedToolOutputItem(
        callID: String,
        outputType: String
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string(outputType),
            "call_id": .string(callID),
            "output": .string("aborted")
        ])
    }
}

extension MSPAgentConversation {
    func appendTranscriptItems(_ items: [MSPAgentJSONValue]) {
        guard !items.isEmpty else {
            return
        }

        let cachedProjection = promptTranscriptProjectionCache
        let cachedRevision = transcriptRevision
        transcriptItems.append(contentsOf: items)
        guard let cachedProjection,
              cachedProjection.transcriptRevision == cachedRevision,
              let updatedProjection = MSPAgentPromptTranscriptNormalizer.incrementallyAppending(
                items,
                to: cachedProjection,
                nextTranscriptRevision: transcriptRevision
              ) else {
            return
        }
        promptTranscriptProjectionCache = updatedProjection
    }

    func promptTranscriptProjection() -> MSPAgentPromptTranscriptProjection {
        if let promptTranscriptProjectionCache,
           promptTranscriptProjectionCache.transcriptRevision == transcriptRevision {
            return promptTranscriptProjectionCache
        }

        let items = MSPAgentPromptTranscriptNormalizer.normalizedItemsForPrompt(transcriptItems)
        let projection = MSPAgentPromptTranscriptProjection(
            transcriptRevision: transcriptRevision,
            items: items,
            estimatedTokenCount: Self.approximateTokenCount(in: items)
        )
        promptTranscriptProjectionCache = projection
        return projection
    }
}

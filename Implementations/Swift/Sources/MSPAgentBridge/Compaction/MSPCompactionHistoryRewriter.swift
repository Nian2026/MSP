import Foundation

struct MSPCompactionLocalRewriteResult: Hashable, Sendable {
    var replacementHistory: [MSPAgentJSONValue]
    var summaryText: String
    var retainedUserMessageCount: Int
    var discardedUserMessageCount: Int
}

struct MSPCompactionRemoteV2RewriteResult: Hashable, Sendable {
    var replacementHistory: [MSPAgentJSONValue]
    var retainedImageCount: Int
}

enum MSPCompactionHistoryRewriter {
    static let summaryPrefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

    static let defaultRetainedUserMessageTokenBudget = 20_000
    static let defaultRemoteV2RetainedMessageTokenBudget = 64_000

    static func localReplacementHistory(
        from promptItems: [MSPAgentJSONValue],
        assistantSummary: String,
        initialContext: [MSPAgentJSONValue] = [],
        retainedUserMessageTokenBudget: Int = defaultRetainedUserMessageTokenBudget
    ) -> MSPCompactionLocalRewriteResult {
        let realUserMessages = promptItems.compactMap(realUserMessageText)
        let selectedMessages = retainedUserMessages(
            realUserMessages,
            maxTokens: retainedUserMessageTokenBudget
        )
        let summaryText = "\(summaryPrefix)\n\(assistantSummary)"
        var replacementHistory = selectedMessages.map(userMessage)
        replacementHistory.append(userMessage(summaryText))
        if !initialContext.isEmpty {
            replacementHistory = insertingInitialContext(
                initialContext,
                into: replacementHistory
            )
        }
        return MSPCompactionLocalRewriteResult(
            replacementHistory: replacementHistory,
            summaryText: summaryText,
            retainedUserMessageCount: selectedMessages.count,
            discardedUserMessageCount: max(0, realUserMessages.count - selectedMessages.count)
        )
    }

    static func legacyCompactedHistory(
        from promptItems: [MSPAgentJSONValue],
        summaryText: String,
        retainedUserMessageTokenBudget: Int = defaultRetainedUserMessageTokenBudget
    ) -> [MSPAgentJSONValue] {
        let realUserMessages = promptItems.compactMap(realUserMessageText)
        let selectedMessages = retainedUserMessages(
            realUserMessages,
            maxTokens: retainedUserMessageTokenBudget
        )
        let persistedSummaryText = summaryText.isEmpty
            ? "(no summary available)"
            : summaryText
        return selectedMessages.map(userMessage) + [userMessage(persistedSummaryText)]
    }

    static func remoteV2CompactedHistory(
        promptInput: [MSPAgentJSONValue],
        compactionOutput: MSPAgentJSONValue,
        retainedMessageTokenBudget: Int = defaultRemoteV2RetainedMessageTokenBudget
    ) -> MSPCompactionRemoteV2RewriteResult {
        let retained = promptInput
            .filter(isRemoteV2RetainedCandidate)
            .filter(shouldKeepRemoteCompactedHistoryItem)
        var replacementHistory = truncateRetainedRemoteMessages(
            retained,
            maxTokens: retainedMessageTokenBudget
        )
        let retainedImageCount = replacementHistory
            .map(inputImageCount)
            .reduce(0, +)
        replacementHistory.append(compactionOutput)
        return MSPCompactionRemoteV2RewriteResult(
            replacementHistory: replacementHistory,
            retainedImageCount: retainedImageCount
        )
    }

    static func remoteCompactedHistory(
        serverOutput: [MSPAgentJSONValue],
        initialContext: [MSPAgentJSONValue] = []
    ) -> [MSPAgentJSONValue] {
        insertingInitialContext(
            initialContext,
            into: serverOutput.filter(shouldKeepRemoteCompactedHistoryItem)
        )
    }

    static func insertingInitialContext(
        _ initialContext: [MSPAgentJSONValue],
        into compactedHistory: [MSPAgentJSONValue]
    ) -> [MSPAgentJSONValue] {
        guard !initialContext.isEmpty else {
            return compactedHistory
        }
        var lastUserOrSummaryIndex: Int?
        var lastRealUserIndex: Int?
        for index in compactedHistory.indices.reversed() {
            guard isUserMessageLike(compactedHistory[index]) else {
                continue
            }
            if lastUserOrSummaryIndex == nil {
                lastUserOrSummaryIndex = index
            }
            if realUserMessageText(compactedHistory[index]) != nil {
                lastRealUserIndex = index
                break
            }
        }
        let lastCompactionIndex = compactedHistory.indices.reversed().first { index in
            let type = compactedHistory[index].objectValue?["type"]?.stringValue
            return type == "compaction" || type == "context_compaction"
        }
        let insertionIndex = lastRealUserIndex ?? lastUserOrSummaryIndex ?? lastCompactionIndex
        var rewritten = compactedHistory
        if let insertionIndex {
            rewritten.insert(contentsOf: initialContext, at: insertionIndex)
        } else {
            rewritten.append(contentsOf: initialContext)
        }
        return rewritten
    }

    private static func retainedUserMessages(
        _ messages: [String],
        maxTokens: Int
    ) -> [String] {
        guard maxTokens > 0 else {
            return []
        }
        var remaining = maxTokens
        var selected: [String] = []
        for message in messages.reversed() {
            guard remaining > 0 else {
                break
            }
            let tokens = approximateTokenCount(message)
            if tokens <= remaining {
                selected.append(message)
                remaining -= tokens
            } else {
                let truncated = truncateText(message, maxTokens: remaining)
                if !truncated.isEmpty {
                    selected.append(truncated)
                }
                break
            }
        }
        return selected.reversed()
    }

    private static func truncateRetainedRemoteMessages(
        _ items: [MSPAgentJSONValue],
        maxTokens: Int
    ) -> [MSPAgentJSONValue] {
        guard maxTokens > 0 else {
            return []
        }
        var remaining = maxTokens
        var selected: [MSPAgentJSONValue] = []
        for item in items.reversed() {
            guard remaining > 0 else {
                continue
            }

            let tokens = max(1, messageTextTokenCount(item))
            if tokens <= remaining {
                selected.append(item)
                remaining -= tokens
            } else if let truncated = truncateMessageText(item, maxTokens: remaining) {
                selected.append(truncated)
                remaining = 0
            }
        }
        return selected.reversed()
    }

    private static func isRemoteV2RetainedCandidate(_ item: MSPAgentJSONValue) -> Bool {
        guard let object = item.objectValue,
              object["type"]?.stringValue == "message",
              let role = object["role"]?.stringValue else {
            return false
        }
        return role == "user" || role == "developer" || role == "system"
    }

    private static func shouldKeepRemoteCompactedHistoryItem(_ item: MSPAgentJSONValue) -> Bool {
        guard let object = item.objectValue,
              let type = object["type"]?.stringValue else {
            return false
        }
        switch type {
        case "message":
            guard let role = object["role"]?.stringValue else {
                return false
            }
            switch role {
            case "developer", "system":
                return false
            case "user":
                return isHookPromptMessage(item) || isRemoteVisibleUserMessage(item)
            case "assistant":
                return true
            default:
                return false
            }
        case "agent_message", "compaction", "compaction_summary", "context_compaction":
            return true
        case "compaction_trigger",
             "additional_tools",
             "reasoning",
             "local_shell_call",
             "function_call",
             "function_call_output",
             "tool_search_call",
             "tool_search_output",
             "custom_tool_call",
             "custom_tool_call_output",
             "web_search_call",
             "image_generation_call":
            return false
        default:
            return false
        }
    }

    private static func realUserMessageText(_ item: MSPAgentJSONValue) -> String? {
        guard isUserMessageLike(item),
              let text = messageText(item),
              !isSummaryMessage(text),
              !isCodexGeneratedUserMessage(text) else {
            return nil
        }
        return text
    }

    private static func isRemoteVisibleUserMessage(_ item: MSPAgentJSONValue) -> Bool {
        guard isUserMessageLike(item) else {
            return false
        }
        if let text = messageText(item) {
            return !isCodexGeneratedUserMessage(text)
        }
        return inputImageCount(item) > 0
    }

    private static func isUserMessageLike(_ item: MSPAgentJSONValue) -> Bool {
        guard let object = item.objectValue else {
            return false
        }
        return object["type"]?.stringValue == "message"
            && object["role"]?.stringValue == "user"
    }

    private static func isSummaryMessage(_ text: String) -> Bool {
        text.hasPrefix("\(summaryPrefix)\n")
    }

    private static func isCodexGeneratedUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        return trimmed.hasPrefix("# AGENTS.md")
            || lowercased.hasPrefix("<environment_context")
            || lowercased.hasPrefix("<turn_aborted")
            || trimmed.hasPrefix("Warning: The maximum number of unified exec processes")
            || trimmed.hasPrefix("Warning: apply_patch was requested via exec_command.")
            || trimmed.hasPrefix("Warning: Your account was flagged")
    }

    private static func messageText(_ item: MSPAgentJSONValue) -> String? {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return nil
        }
        let pieces = content.compactMap { contentItem -> String? in
            guard let object = contentItem.objectValue,
                  let type = object["type"]?.stringValue,
                  type == "input_text" || type == "output_text",
                  let text = object["text"]?.stringValue,
                  !text.isEmpty else {
                return nil
            }
            return text
        }
        guard !pieces.isEmpty else {
            return nil
        }
        return pieces.joined(separator: "\n")
    }

    private static func isHookPromptMessage(_ item: MSPAgentJSONValue) -> Bool {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return false
        }
        return content.contains { contentItem in
            guard let text = contentItem.objectValue?["text"]?.stringValue else {
                return false
            }
            return text.contains("<hook_prompt")
        }
    }

    private static func messageTextTokenCount(_ item: MSPAgentJSONValue) -> Int {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return 0
        }
        return content.reduce(0) { total, contentItem in
            guard let object = contentItem.objectValue,
                  let type = object["type"]?.stringValue,
                  type == "input_text" || type == "output_text",
                  let text = object["text"]?.stringValue else {
                return total
            }
            return total + approximateTokenCount(text)
        }
    }

    private static func inputImageCount(_ item: MSPAgentJSONValue) -> Int {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return 0
        }
        return content.filter { contentItem in
            contentItem.objectValue?["type"]?.stringValue == "input_image"
        }.count
    }

    private static func truncateMessageText(
        _ item: MSPAgentJSONValue,
        maxTokens: Int
    ) -> MSPAgentJSONValue? {
        guard maxTokens > 0,
              var object = item.objectValue,
              object["type"]?.stringValue == "message",
              let content = object["content"]?.arrayValue else {
            return nil
        }

        var remaining = maxTokens
        var truncatedContent: [MSPAgentJSONValue] = []
        for contentItem in content {
            guard var contentObject = contentItem.objectValue,
                  let type = contentObject["type"]?.stringValue else {
                continue
            }

            if type == "input_text" || type == "output_text" {
                guard remaining > 0,
                      let text = contentObject["text"]?.stringValue else {
                    continue
                }
                let tokenCount = approximateTokenCount(text)
                if tokenCount <= remaining {
                    remaining -= tokenCount
                } else {
                    contentObject["text"] = .string(truncateTextMiddle(text, maxTokens: remaining))
                    remaining = 0
                }
                if contentObject["text"]?.stringValue?.isEmpty == false {
                    truncatedContent.append(.object(contentObject))
                }
            } else if type == "input_image" {
                truncatedContent.append(contentItem)
            }
        }

        guard !truncatedContent.isEmpty else {
            return nil
        }
        object["content"] = .array(truncatedContent)
        return .object(object)
    }

    private static func userMessage(_ text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private static func approximateTokenCount(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    private static func truncateText(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else {
            return ""
        }
        let maxCharacters = max(0, maxTokens * 4)
        guard text.count > maxCharacters else {
            return text
        }
        return String(text.prefix(maxCharacters))
            + "\n[truncated to \(maxTokens) approximate tokens]"
    }

    private static func truncateTextMiddle(_ text: String, maxTokens: Int) -> String {
        let maxBytes = max(0, maxTokens * 4)
        guard maxBytes > 0 else {
            return "…\(approximateTokenCount(text)) tokens truncated…"
        }
        let totalBytes = text.utf8.count
        guard totalBytes > maxBytes else {
            return text
        }

        let leftBudget = maxBytes / 2
        let rightBudget = maxBytes - leftBudget
        let prefix = textPrefix(text, maxBytes: leftBudget)
        let suffix = textSuffix(text, maxBytes: rightBudget)
        let removedTokens = max(1, (totalBytes - maxBytes + 3) / 4)
        return "\(prefix)…\(removedTokens) tokens truncated…\(suffix)"
    }

    private static func textPrefix(_ text: String, maxBytes: Int) -> String {
        var used = 0
        var scalars: [Character] = []
        for character in text {
            let count = String(character).utf8.count
            guard used + count <= maxBytes else {
                break
            }
            scalars.append(character)
            used += count
        }
        return String(scalars)
    }

    private static func textSuffix(_ text: String, maxBytes: Int) -> String {
        var used = 0
        var scalars: [Character] = []
        for character in text.reversed() {
            let count = String(character).utf8.count
            guard used + count <= maxBytes else {
                break
            }
            scalars.append(character)
            used += count
        }
        return String(scalars.reversed())
    }
}

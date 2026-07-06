import Foundation

struct MSPResponsesVisibleMessageParts {
    var assistantMessages: [String]
    var finalAnswers: [String]
}

extension MSPResponsesStreamingModelClient {
    static func visibleMessageParts(from nativeOutputItems: [MSPAgentJSONValue]) -> MSPResponsesVisibleMessageParts {
        var assistantMessages: [String] = []
        var finalAnswers: [String] = []

        for item in nativeOutputItems {
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "message",
                  object["role"]?.stringValue == "assistant" else {
                continue
            }
            let text = messageText(from: object)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            switch visibleDeltaPhase(from: object["phase"]?.stringValue) {
            case .assistantMessage?:
                assistantMessages.append(text)
            case .finalAnswer?:
                finalAnswers.append(text)
            case .unknown?, .none:
                finalAnswers.append(text)
            }
        }

        return MSPResponsesVisibleMessageParts(
            assistantMessages: assistantMessages,
            finalAnswers: finalAnswers
        )
    }

    static func visibleDeltaPhase(from rawPhase: String?) -> MSPAgentModelStreamDelta.Phase? {
        switch rawPhase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "commentary", "interim", "assistant_message", "checkpoint":
            return .assistantMessage
        case "final_answer", "final":
            return .finalAnswer
        default:
            return nil
        }
    }

    static func messageText(from object: [String: MSPAgentJSONValue]) -> String {
        guard let content = object["content"]?.arrayValue else {
            return ""
        }
        return content
            .compactMap(\.objectValue)
            .compactMap { item -> String? in
                let type = item["type"]?.stringValue
                guard type == nil || type == "output_text" || type == "text" else {
                    return nil
                }
                return item["text"]?.stringValue
            }
            .joined(separator: "\n")
    }

    static func joinedVisibleMessageParts(_ parts: [String]) -> String? {
        let text = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func extractResponsesDelta(from json: [String: Any]) -> String {
        let eventName = stringValue(at: ["type"], in: json) ?? ""
        if !eventName.isEmpty {
            if eventName.hasPrefix("response.reasoning_")
                || eventName.hasPrefix("response.web_search_")
                || eventName.hasPrefix("response.function_call_arguments.")
                || eventName.hasPrefix("response.custom_tool_call_input.")
                || stringValue(at: ["item", "type"], in: json) == "reasoning" {
                return ""
            }

            switch eventName {
            case "response.output_text.delta", "response.refusal.delta":
                return stringValue(at: ["delta"], in: json) ?? ""
            case let name where name.hasSuffix(".delta"):
                if let delta = stringValue(at: ["delta"], in: json), !delta.isEmpty {
                    return delta
                }
                if let part = stringValue(at: ["item", "delta"], in: json), !part.isEmpty {
                    return part
                }
                return ""
            default:
                return ""
            }
        }

        if stringValue(at: ["item", "type"], in: json) == "reasoning" {
            return ""
        }
        if let outputText = flattenTextPayload(json["output_text"]), !outputText.isEmpty {
            return outputText
        }
        if let output = flattenTextPayload(json["output"]), !output.isEmpty {
            return output
        }
        return ""
    }

    static func extractResponsesText(from json: [String: Any]) -> String {
        if let outputText = flattenTextPayload(json["output_text"]), !outputText.isEmpty {
            return outputText
        }
        if let output = flattenTextPayload(json["output"]), !output.isEmpty {
            return output
        }
        if let content = flattenTextPayload(json["content"]), !content.isEmpty {
            return content
        }
        if let candidates = flattenTextPayload(json["candidates"]), !candidates.isEmpty {
            return candidates
        }
        if let response = json["response"] as? [String: Any] {
            let nested = extractResponsesText(from: response)
            if !nested.isEmpty {
                return nested
            }
        }
        return ""
    }

    static func flattenTextPayload(_ payload: Any?) -> String? {
        switch payload {
        case let string as String:
            return string
        case let array as [Any]:
            let parts = array.compactMap { flattenTextPayload($0) }.filter { !$0.isEmpty }
            let joined = mergeTextFragments(parts)
            return joined.isEmpty ? nil : joined
        case let dictionary as [String: Any]:
            if let text = dictionary["text"] as? String, !text.isEmpty {
                return text
            }
            if let parts = flattenTextPayload(dictionary["parts"]), !parts.isEmpty {
                return parts
            }
            if let candidates = flattenTextPayload(dictionary["candidates"]), !candidates.isEmpty {
                return candidates
            }
            if let content = flattenTextPayload(dictionary["content"]), !content.isEmpty {
                return content
            }
            if let value = dictionary["value"] as? String, !value.isEmpty {
                return value
            }
            if let delta = dictionary["delta"] as? String, !delta.isEmpty {
                return delta
            }
            return nil
        default:
            return nil
        }
    }

    static func mergeTextFragments(_ fragments: [String]) -> String {
        guard var result = fragments.first else {
            return ""
        }
        for fragment in fragments.dropFirst() {
            if result.hasSuffix("\n") || fragment.hasPrefix("\n") {
                result += fragment
                continue
            }
            let last = result.last
            let first = fragment.first
            let needsParagraphBreak =
                (last == "。" || last == "！" || last == "？" || last == ":" || last == "：" || last == ";")
                || (first?.isNumber == true)
                || fragment.hasPrefix("- ")
                || fragment.hasPrefix("* ")
            result += needsParagraphBreak ? "\n\n\(fragment)" : fragment
        }
        return result
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

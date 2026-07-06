import Foundation

extension MSPResponsesStreamingModelClient {
    static func shouldParseImmediately(_ dataLines: [String]) -> Bool {
        guard dataLines.count == 1 else {
            return false
        }
        return isLikelyStandaloneEvent(dataLines[0])
    }

    static func isLikelyStandaloneEvent(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed == "[DONE]" {
            return true
        }
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    static func isResponsesStreamErrorEvent(
        eventName: String,
        json: [String: Any]
    ) -> Bool {
        let normalizedEventName = eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedEventName == "error" || normalizedEventName.hasSuffix(".failed") {
            return true
        }
        return responseErrorMessage(from: json) != nil
            || responseErrorMessage(from: value(at: ["response"], in: json)) != nil
    }

    static func contextWindowExceededMessage(from json: [String: Any]) -> String? {
        if isContextWindowExceededCode(stringValue(at: ["error", "code"], in: json)) {
            return responseErrorMessage(from: value(at: ["error"], in: json))
                ?? "context_length_exceeded"
        }
        if isContextWindowExceededCode(stringValue(at: ["response", "error", "code"], in: json)) {
            return responseErrorMessage(from: value(at: ["response", "error"], in: json))
                ?? "context_length_exceeded"
        }
        if isContextWindowExceededCode(stringValue(at: ["code"], in: json)) {
            return responseErrorMessage(from: json)
                ?? "context_length_exceeded"
        }
        if let message = responseErrorMessage(from: json),
           MSPAgentModelClientError.isLikelyContextWindowExceededMessage(message) {
            return message
        }
        if let message = responseErrorMessage(from: value(at: ["response"], in: json)),
           MSPAgentModelClientError.isLikelyContextWindowExceededMessage(message) {
            return message
        }
        return nil
    }

    private static func isContextWindowExceededCode(_ code: String?) -> Bool {
        code?.trimmingCharacters(in: .whitespacesAndNewlines) == "context_length_exceeded"
    }

    static func streamErrorMessage(from json: [String: Any], dataString: String) -> String {
        responseErrorMessage(from: json)
            ?? responseErrorMessage(from: value(at: ["response"], in: json))
            ?? String(dataString.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }

    static func responseErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return responseErrorMessage(from: object)
    }

    static func responseErrorMessage(from object: Any?) -> String? {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let message = stringValue(at: ["error", "message"], in: dictionary) {
            return message
        }
        if let message = stringValue(at: ["message"], in: dictionary),
           !(dictionary["type"] as? String == "response.completed") {
            return message
        }
        if let nested = dictionary["error"] {
            return responseErrorMessage(from: nested)
        }
        return nil
    }

    static func errorMessage(from data: Data) -> String {
        responseErrorMessage(from: data)
            ?? String((String(data: data, encoding: .utf8) ?? "").prefix(220))
    }
}

import Foundation

extension MSPResponsesStreamingModelClient {
    public static func toolOutputInputItems(
        from results: [MSPAgentToolResult]
    ) throws -> [MSPAgentJSONValue] {
        try results.map { result in
            .object([
                "type": .string(result.outputKind == .custom ? "custom_tool_call_output" : "function_call_output"),
                "call_id": .string(result.callID),
                "output": try toolResultOutputValue(result)
            ])
        }
    }

    public static func functionCallOutputInputItems(
        from results: [MSPAgentToolResult]
    ) throws -> [MSPAgentJSONValue] {
        try toolOutputInputItems(from: results)
    }

    public static func toolResultOutputValue(_ result: MSPAgentToolResult) throws -> MSPAgentJSONValue {
        if let modelOutputContent = result.modelOutputContent {
            return modelOutputContent
        }
        return .string(try toolResultOutputString(result))
    }

    public static func toolResultOutputString(_ result: MSPAgentToolResult) throws -> String {
        if (result.name == .execCommand || result.name == .writeStdin || result.outputKind == .custom),
           let output = result.content?.stringValue {
            return output
        }
        var payload: [String: Any] = [
            "tool_name": result.name.rawValue,
            "ok": result.ok
        ]
        if let content = result.content {
            payload["content"] = content.jsonObject
        }
        if let errorMessage = result.errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["error_message"] = errorMessage
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

import Foundation

extension MSPResponsesStreamingModelClient {
    static func tokenUsage(from json: [String: Any]) -> MSPAgentTokenUsage? {
        let usageObject: [String: Any]?
        if let usage = json["usage"] as? [String: Any] {
            usageObject = usage
        } else {
            usageObject = json
        }
        guard let usageObject else {
            return nil
        }

        let inputTokens = intValue(at: ["input_tokens"], in: usageObject)
            ?? intValue(at: ["inputTokens"], in: usageObject)
            ?? intValue(at: ["prompt_tokens"], in: usageObject)
            ?? intValue(at: ["promptTokens"], in: usageObject)
        let cachedInputTokens = intValue(at: ["cached_input_tokens"], in: usageObject)
            ?? intValue(at: ["cachedInputTokens"], in: usageObject)
            ?? intValue(at: ["input_tokens_details", "cached_tokens"], in: usageObject)
            ?? intValue(at: ["inputTokensDetails", "cachedTokens"], in: usageObject)
            ?? intValue(at: ["prompt_tokens_details", "cached_tokens"], in: usageObject)
            ?? intValue(at: ["promptTokensDetails", "cachedTokens"], in: usageObject)
        let outputTokens = intValue(at: ["output_tokens"], in: usageObject)
            ?? intValue(at: ["outputTokens"], in: usageObject)
            ?? intValue(at: ["completion_tokens"], in: usageObject)
            ?? intValue(at: ["completionTokens"], in: usageObject)
        let totalTokens = intValue(at: ["total_tokens"], in: usageObject)
            ?? intValue(at: ["totalTokens"], in: usageObject)
        guard inputTokens != nil || outputTokens != nil || totalTokens != nil else {
            return nil
        }
        return MSPAgentTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }
}

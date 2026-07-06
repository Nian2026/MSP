import Foundation

extension MSPAgentModelConfiguration {
    public static let openAIProviderName = "OpenAI"

    public var supportsRemoteCompaction: Bool {
        providerName == Self.openAIProviderName
            || Self.isAzureResponsesProvider(
                name: providerName,
                baseURL: baseURL.absoluteString
            )
    }

    static func isAzureResponsesProvider(
        name: String,
        baseURL: String?
    ) -> Bool {
        if name.compare("Azure", options: [.caseInsensitive]) == .orderedSame {
            return true
        }
        guard let baseURL else {
            return false
        }
        let lowercasedBaseURL = baseURL.lowercased()
        return [
            "openai.azure.",
            "cognitiveservices.azure.",
            "aoai.azure.",
            "azure-api.",
            "azurefd.",
            "windows.net/openai"
        ].contains { lowercasedBaseURL.contains($0) }
    }
}

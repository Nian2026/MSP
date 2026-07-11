import Foundation

enum MSPBundledModelCatalog {
    static let revision = "2026-07-12"

    static let models: [MSPModelCapabilities] = [
        model(
            slug: "gpt-5.6-sol",
            displayName: "GPT-5.6-Sol",
            description: "Latest frontier agentic coding model.",
            defaultEffort: .low,
            efforts: [.low, .medium, .high, .xhigh, .max, .ultra],
            priority: 1,
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "3000"
        ),
        model(
            slug: "gpt-5.6-terra",
            displayName: "GPT-5.6-Terra",
            description: "Frontier agentic model for deep, long-running work.",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh, .max, .ultra],
            priority: 2,
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "3000"
        ),
        model(
            slug: "gpt-5.6-luna",
            displayName: "GPT-5.6-Luna",
            description: "Fast and affordable agentic coding model.",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh, .max],
            priority: 3,
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "3000"
        ),
        model(
            slug: "gpt-5.5",
            displayName: "GPT-5.5",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh],
            priority: 7,
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            compHash: "2911"
        ),
        model(
            slug: "gpt-5.4",
            displayName: "GPT-5.4",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh],
            priority: 16,
            contextWindow: 272_000,
            maxContextWindow: 1_000_000,
            compHash: "2911"
        ),
        model(
            slug: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh],
            priority: 23,
            contextWindow: 272_000,
            maxContextWindow: 272_000,
            compHash: "2911"
        ),
        model(
            slug: "gpt-5.2",
            displayName: "GPT-5.2",
            defaultEffort: .medium,
            efforts: [.low, .medium, .high, .xhigh],
            priority: 29,
            contextWindow: 272_000,
            maxContextWindow: 272_000
        )
    ]

    private static func model(
        slug: String,
        displayName: String,
        description: String? = nil,
        defaultEffort: MSPReasoningEffort,
        efforts: [MSPReasoningEffort],
        priority: Int,
        contextWindow: Int,
        maxContextWindow: Int,
        compHash: String? = nil,
        supportedInAPI: Bool = true
    ) -> MSPModelCapabilities {
        MSPModelCapabilities(
            slug: slug,
            displayName: displayName,
            description: description,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts.map {
                MSPReasoningEffortPreset(
                    effort: $0,
                    description: effortDescription(for: $0)
                )
            },
            visibility: "list",
            supportedInAPI: supportedInAPI,
            priority: priority,
            contextWindow: contextWindow,
            maxContextWindow: maxContextWindow,
            effectiveContextWindowPercent: 95,
            explicitAutoCompactTokenLimit: nil,
            compHash: compHash
        )
    }

    private static func effortDescription(for effort: MSPReasoningEffort) -> String {
        switch effort {
        case .minimal: "Minimal reasoning for the fastest response"
        case .low: "Fast responses with lighter reasoning"
        case .medium: "Balances speed and reasoning depth for everyday tasks"
        case .high: "Greater reasoning depth for complex problems"
        case .xhigh: "Extra high reasoning depth for complex problems"
        case .max: "Maximum reasoning depth for the hardest problems"
        case .ultra: "Maximum reasoning with automatic task delegation"
        default: effort.rawValue
        }
    }
}

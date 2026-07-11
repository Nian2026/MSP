import Foundation

public enum MSPModelMetadataSource: String, Codable, Hashable, Sendable {
    case bundled
    case diskCache = "disk_cache"
    case remote
    case provided
    case fallback
}

/// Fully calculated model behavior consumed by request and compaction runtime.
///
/// Provenance: context-window, effective-window, auto-compaction, and reasoning
/// reconciliation rules are Swift ports of Apache-2.0 OpenAI Codex behavior.
public struct MSPResolvedModelProfile: Codable, Hashable, Sendable {
    public var modelID: String
    public var matchedModelID: String
    public var displayName: String
    public var description: String?
    public var defaultReasoningEffort: MSPReasoningEffort?
    public var supportedReasoningEfforts: [MSPReasoningEffortPreset]
    public var visibility: String
    public var supportedInAPI: Bool
    public var priority: Int
    public var contextWindowTokens: Int?
    public var maxContextWindowTokens: Int?
    public var effectiveContextWindowPercent: Int
    public var effectiveContextWindowTokens: Int?
    public var autoCompactTokenLimit: Int?
    public var compHash: String?
    public var metadataSource: MSPModelMetadataSource
    public var metadataRevision: String?
    public var usedFallbackMetadata: Bool

    public init(
        modelID: String,
        matchedModelID: String,
        capabilities: MSPModelCapabilities,
        metadataSource: MSPModelMetadataSource,
        metadataRevision: String? = nil,
        usedFallbackMetadata: Bool = false,
        contextWindowOverride: Int? = nil,
        autoCompactTokenLimitOverride: Int? = nil
    ) {
        let resolvedContextWindow: Int?
        if let contextWindowOverride {
            resolvedContextWindow = capabilities.maxContextWindow.map {
                min(contextWindowOverride, $0)
            } ?? contextWindowOverride
        } else {
            resolvedContextWindow = capabilities.resolvedContextWindow
        }

        let effectiveTokens = resolvedContextWindow.map {
            Self.saturatingMultiplyDivide(
                $0,
                capabilities.effectiveContextWindowPercent,
                divisor: 100
            )
        }
        let derivedAutoLimit = resolvedContextWindow.map {
            Self.saturatingMultiplyDivide($0, 9, divisor: 10)
        }
        let explicitAutoLimit = autoCompactTokenLimitOverride
            ?? capabilities.explicitAutoCompactTokenLimit
        let resolvedAutoLimit: Int?
        if let derivedAutoLimit {
            resolvedAutoLimit = min(explicitAutoLimit ?? derivedAutoLimit, derivedAutoLimit)
        } else {
            resolvedAutoLimit = explicitAutoLimit
        }

        self.modelID = modelID
        self.matchedModelID = matchedModelID
        displayName = capabilities.displayName
        description = capabilities.description
        defaultReasoningEffort = capabilities.defaultReasoningEffort
        supportedReasoningEfforts = capabilities.supportedReasoningEfforts
        visibility = capabilities.visibility
        supportedInAPI = capabilities.supportedInAPI
        priority = capabilities.priority
        contextWindowTokens = resolvedContextWindow
        maxContextWindowTokens = capabilities.maxContextWindow
        effectiveContextWindowPercent = capabilities.effectiveContextWindowPercent
        effectiveContextWindowTokens = effectiveTokens
        autoCompactTokenLimit = resolvedAutoLimit
        compHash = capabilities.compHash
        self.metadataSource = metadataSource
        self.metadataRevision = metadataRevision
        self.usedFallbackMetadata = usedFallbackMetadata
    }

    public var isFallback: Bool { usedFallbackMetadata }

    public var contextWindowProfile: MSPAgentContextWindowProfile? {
        guard let contextWindowTokens,
              let effectiveContextWindowTokens,
              let autoCompactTokenLimit,
              contextWindowTokens > 0,
              effectiveContextWindowTokens > 0,
              autoCompactTokenLimit > 0 else {
            return nil
        }
        return MSPAgentContextWindowProfile(
            modelID: modelID,
            modelFamily: matchedModelID,
            contextWindowTokens: contextWindowTokens,
            effectiveContextWindowTokens: effectiveContextWindowTokens,
            autoCompactTokenLimit: autoCompactTokenLimit
        )
    }

    /// Reconcile a selection while preserving the explicit model-default sentinel.
    public func reconciledReasoningEffort(
        _ requested: MSPReasoningEffort?
    ) -> MSPReasoningEffort? {
        if requested == .modelDefault {
            return .modelDefault
        }
        let supported = supportedReasoningEfforts.map(\.effort)
        if supported.isEmpty, let requested {
            return requested
        }
        if let requested, supported.contains(requested) {
            return requested
        }
        if !supported.isEmpty {
            return supported[(supported.count - 1) / 2]
        }
        return defaultReasoningEffort
    }

    public func reconciledReasoningEffort(_ requested: String) -> MSPReasoningEffort? {
        reconciledReasoningEffort(MSPReasoningEffort(rawValue: requested))
    }

    /// Resolve a UI/config selection to the concrete value sent on the wire.
    public func effectiveReasoningEffort(
        for requested: MSPReasoningEffort?
    ) -> MSPReasoningEffort? {
        if requested == nil || requested == .modelDefault {
            return defaultReasoningEffort
        }
        let reconciled = reconciledReasoningEffort(requested)
        return reconciled == .modelDefault ? defaultReasoningEffort : reconciled
    }

    public func effectiveReasoningEffort(for requested: String?) -> MSPReasoningEffort? {
        guard let requested else { return defaultReasoningEffort }
        return effectiveReasoningEffort(for: MSPReasoningEffort(rawValue: requested))
    }

    private static func saturatingMultiplyDivide(
        _ lhs: Int,
        _ rhs: Int,
        divisor: Int
    ) -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        if !result.overflow {
            return result.partialValue / divisor
        }
        let sameSign = (lhs >= 0) == (rhs >= 0)
        return (sameSign ? Int.max : Int.min) / divisor
    }
}

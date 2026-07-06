import Foundation

enum MSPCompactionTrigger: String, Codable, Hashable, Sendable {
    case manual
    case auto
}

enum MSPCompactionReason: String, Codable, Hashable, Sendable {
    case userRequested = "user_requested"
    case contextLimit = "context_limit"
    case modelDownshift = "model_downshift"
    case compHashChanged = "comp_hash_changed"
}

enum MSPCompactionImplementation: String, Codable, Hashable, Sendable {
    case responses
    case responsesCompactionV2 = "responses_compaction_v2"
    case responsesCompact = "responses_compact"
    case freshContextWindow = "fresh_context_window"
}

enum MSPCompactionPhase: String, Codable, Hashable, Sendable {
    case standaloneTurn = "standalone_turn"
    case preTurn = "pre_turn"
    case midTurn = "mid_turn"
}

enum MSPCompactionStatus: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case interrupted
}

enum MSPCompactionStrategy: String, Codable, Hashable, Sendable {
    case memento
    case prefixCompaction = "prefix_compaction"
}

public enum MSPCompactionTokenLimitScope: String, Codable, Hashable, Sendable {
    case total
    case bodyAfterPrefix = "body_after_prefix"
}

struct MSPCompactionTokenStatus: Codable, Hashable, Sendable {
    var activeTokens: Int
    var contextWindowTokens: Int?
    var autoCompactTokenLimit: Int?
    var currentWindowPrefillTokens: Int?

    init(
        activeTokens: Int,
        contextWindowTokens: Int? = nil,
        autoCompactTokenLimit: Int? = nil,
        currentWindowPrefillTokens: Int? = nil
    ) {
        self.activeTokens = max(0, activeTokens)
        self.contextWindowTokens = contextWindowTokens.map { max(0, $0) }
        self.autoCompactTokenLimit = autoCompactTokenLimit.map { max(0, $0) }
        self.currentWindowPrefillTokens = currentWindowPrefillTokens.map { max(0, $0) }
    }

    func limitReached(scope: MSPCompactionTokenLimitScope) -> Bool {
        if let contextWindowTokens, contextWindowTokens > 0, activeTokens >= contextWindowTokens {
            return true
        }
        guard let autoCompactTokenLimit, autoCompactTokenLimit > 0 else {
            return false
        }
        switch scope {
        case .total:
            return activeTokens >= autoCompactTokenLimit

        case .bodyAfterPrefix:
            let baseline = currentWindowPrefillTokens ?? 0
            let bodyTokens = max(0, activeTokens - baseline)
            return bodyTokens >= autoCompactTokenLimit
        }
    }
}

struct MSPMidTurnCompactionEvaluation: Codable, Hashable, Sendable {
    var needsFollowUp: Bool
    var canDrainPendingInputAfterCompaction: Bool
    var decision: MSPCompactionDecision?
}

struct MSPCompactionModelSnapshot: Codable, Hashable, Sendable {
    var model: String
    var compHash: String?
    var contextWindowTokens: Int?
    var autoCompactTokenLimit: Int?

    init(
        model: String,
        compHash: String? = nil,
        contextWindowTokens: Int? = nil,
        autoCompactTokenLimit: Int? = nil
    ) {
        self.model = model
        self.compHash = compHash
        self.contextWindowTokens = contextWindowTokens.map { max(0, $0) }
        self.autoCompactTokenLimit = autoCompactTokenLimit.map { max(0, $0) }
    }
}

struct MSPPreviousModelCompactionDecision: Codable, Hashable, Sendable {
    var decision: MSPCompactionDecision
    var compactionModel: String
}

public struct MSPCompactionPolicy: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var tokenLimitScope: MSPCompactionTokenLimitScope
    public var tokenBudgetFeatureEnabled: Bool
    public var remoteCompactionEnabled: Bool
    public var remoteCompactionV2Enabled: Bool

    public init(
        enabled: Bool = false,
        tokenLimitScope: MSPCompactionTokenLimitScope = .total,
        tokenBudgetFeatureEnabled: Bool = false,
        remoteCompactionEnabled: Bool = false,
        remoteCompactionV2Enabled: Bool = false
    ) {
        self.enabled = enabled
        self.tokenLimitScope = tokenLimitScope
        self.tokenBudgetFeatureEnabled = tokenBudgetFeatureEnabled
        self.remoteCompactionEnabled = remoteCompactionEnabled
        self.remoteCompactionV2Enabled = remoteCompactionV2Enabled
    }

    public static let disabled = MSPCompactionPolicy()

    func implementation(providerSupportsRemoteCompaction: Bool) -> MSPCompactionImplementation {
        if tokenBudgetFeatureEnabled {
            return .freshContextWindow
        }
        if remoteCompactionEnabled, providerSupportsRemoteCompaction {
            return remoteCompactionV2Enabled ? .responsesCompactionV2 : .responsesCompact
        }
        return .responses
    }

    func preTurnDecision(
        tokenStatus: MSPCompactionTokenStatus,
        providerSupportsRemoteCompaction: Bool,
        reason: MSPCompactionReason = .contextLimit
    ) -> MSPCompactionDecision? {
        guard enabled, tokenStatus.limitReached(scope: tokenLimitScope) else {
            return nil
        }
        return MSPCompactionDecision(
            trigger: .auto,
            reason: reason,
            implementation: implementation(providerSupportsRemoteCompaction: providerSupportsRemoteCompaction),
            phase: .preTurn,
            strategy: .memento
        )
    }

    func previousModelPreTurnDecision(
        previous: MSPCompactionModelSnapshot?,
        current: MSPCompactionModelSnapshot,
        activeTokens: Int,
        providerSupportsRemoteCompaction: Bool
    ) -> MSPPreviousModelCompactionDecision? {
        guard enabled, let previous else {
            return nil
        }

        if compHashChanged(previous.compHash, current.compHash) {
            return previousModelDecision(
                reason: .compHashChanged,
                previousModel: previous.model,
                providerSupportsRemoteCompaction: providerSupportsRemoteCompaction
            )
        }

        guard let previousContextWindow = previous.contextWindowTokens,
              let currentContextWindow = current.contextWindowTokens,
              previous.model != current.model,
              previousContextWindow > currentContextWindow
        else {
            return nil
        }

        let activeTokens = max(0, activeTokens)
        let shouldCompact: Bool
        switch tokenLimitScope {
        case .total:
            let currentAutoLimit = current.autoCompactTokenLimit ?? Int.max
            shouldCompact = activeTokens > currentAutoLimit
                || activeTokens >= currentContextWindow

        case .bodyAfterPrefix:
            shouldCompact = activeTokens >= currentContextWindow
        }

        guard shouldCompact else {
            return nil
        }
        return previousModelDecision(
            reason: .modelDownshift,
            previousModel: previous.model,
            providerSupportsRemoteCompaction: providerSupportsRemoteCompaction
        )
    }

    func midTurnDecision(
        tokenStatus: MSPCompactionTokenStatus,
        providerSupportsRemoteCompaction: Bool
    ) -> MSPCompactionDecision? {
        evaluateMidTurn(
            tokenStatus: tokenStatus,
            providerSupportsRemoteCompaction: providerSupportsRemoteCompaction,
            modelNeedsFollowUp: true,
            hasPendingInput: false
        ).decision
    }

    func evaluateMidTurn(
        tokenStatus: MSPCompactionTokenStatus,
        providerSupportsRemoteCompaction: Bool,
        modelNeedsFollowUp: Bool,
        hasPendingInput: Bool,
        newContextWindowRequested: Bool = false
    ) -> MSPMidTurnCompactionEvaluation {
        // Mirrors codex-rs/core/src/session/turn.rs: pending input participates
        // in the mid-turn continuation/compaction decision, but after compaction
        // queued input drains immediately only when the model does not still
        // require its own follow-up request.
        let needsFollowUp = modelNeedsFollowUp || hasPendingInput
        let canDrainPendingInputAfterCompaction = !modelNeedsFollowUp
        guard enabled,
              needsFollowUp,
              newContextWindowRequested || tokenStatus.limitReached(scope: tokenLimitScope)
        else {
            return MSPMidTurnCompactionEvaluation(
                needsFollowUp: needsFollowUp,
                canDrainPendingInputAfterCompaction: canDrainPendingInputAfterCompaction,
                decision: nil
            )
        }
        return MSPMidTurnCompactionEvaluation(
            needsFollowUp: needsFollowUp,
            canDrainPendingInputAfterCompaction: canDrainPendingInputAfterCompaction,
            decision: MSPCompactionDecision(
                trigger: .auto,
                reason: .contextLimit,
                implementation: implementation(providerSupportsRemoteCompaction: providerSupportsRemoteCompaction),
                phase: .midTurn,
                strategy: .memento
            )
        )
    }

    private func compHashChanged(_ previous: String?, _ current: String?) -> Bool {
        guard let previous, let current else {
            return false
        }
        return previous != current
    }

    private func previousModelDecision(
        reason: MSPCompactionReason,
        previousModel: String,
        providerSupportsRemoteCompaction: Bool
    ) -> MSPPreviousModelCompactionDecision {
        MSPPreviousModelCompactionDecision(
            decision: MSPCompactionDecision(
                trigger: .auto,
                reason: reason,
                implementation: implementation(
                    providerSupportsRemoteCompaction: providerSupportsRemoteCompaction
                ),
                phase: .preTurn,
                strategy: .memento
            ),
            compactionModel: previousModel
        )
    }
}

struct MSPCompactionDecision: Codable, Hashable, Sendable {
    var trigger: MSPCompactionTrigger
    var reason: MSPCompactionReason
    var implementation: MSPCompactionImplementation
    var phase: MSPCompactionPhase
    var strategy: MSPCompactionStrategy
}

import Foundation

extension MSPAgentConversation {
    func recordLatestNormalTurnContextUsage(_ usage: MSPAgentContextUsageRecord?) {
        latestContextUsage = usage
        guard configuration.compactionPolicy.tokenLimitScope == .bodyAfterPrefix,
              let usage,
              let serverInputTokens = usage.serverInputTokens else {
            return
        }
        let observedInputTokens = max(0, serverInputTokens)
        switch currentWindowPrefillTokens {
        case .serverObserved:
            return
        case .estimated:
            currentWindowPrefillTokens = .serverObserved(observedInputTokens)
        case nil:
            if usage.autoCompactTokenLimit > 0,
               observedInputTokens >= usage.autoCompactTokenLimit {
                currentWindowPrefillTokens = .serverObserved(0)
            } else {
                currentWindowPrefillTokens = .serverObserved(observedInputTokens)
            }
        }
    }

    func installEstimatedWindowPrefill(from usage: MSPAgentContextUsageRecord) {
        guard configuration.compactionPolicy.tokenLimitScope == .bodyAfterPrefix else {
            currentWindowPrefillTokens = nil
            return
        }
        currentWindowPrefillTokens = .estimated(max(0, usage.currentTokens))
    }

    func currentWindowPrefillTokensForLimitEvaluation(
        observing usage: MSPAgentContextUsageRecord?,
        protectsImmediateFollowUp: Bool = false
    ) -> Int? {
        guard configuration.compactionPolicy.tokenLimitScope == .bodyAfterPrefix else {
            return nil
        }
        let baseline = currentWindowPrefillTokens?.value
        guard let usage,
              usage.autoCompactTokenLimit > 0
        else {
            return baseline
        }
        if protectsImmediateFollowUp,
           usage.currentTokens >= usage.autoCompactTokenLimit {
            if let baseline, usage.currentTokens <= baseline {
                return baseline
            }
            return 0
        }
        guard let serverInputTokens = usage.serverInputTokens,
              serverInputTokens >= usage.autoCompactTokenLimit
        else {
            return baseline
        }
        if let baseline, serverInputTokens <= baseline {
            return baseline
        }
        return 0
    }

    func clearContextUsageForTranscriptReplacement() {
        latestContextUsage = nil
        currentWindowPrefillTokens = nil
    }

    func estimatedContextUsageRecord(
        for modelVisibleItems: [MSPAgentJSONValue]
    ) -> MSPAgentContextUsageRecord? {
        estimatedContextUsageRecord(
            estimatedTokens: Self.approximateTokenCount(in: modelVisibleItems)
        )
    }

    func estimatedContextUsageRecord(
        estimatedTokens: Int
    ) -> MSPAgentContextUsageRecord? {
        guard let profile = MSPAgentContextWindowProfile.profile(for: configuration.model) else {
            return nil
        }
        return MSPAgentContextUsageRecord(
            modelID: configuration.model,
            modelDisplayName: configuration.model,
            contextWindowTokens: profile.contextWindowTokens,
            effectiveContextWindowTokens: profile.effectiveContextWindowTokens,
            autoCompactTokenLimit: profile.autoCompactTokenLimit,
            estimatedInputTokens: estimatedTokens,
            currentTokens: estimatedTokens,
            serverInputTokens: nil,
            serverCachedInputTokens: nil,
            serverOutputTokens: nil,
            serverTotalTokens: nil
        )
    }

    func projectedPreTurnTokenStatus(
        currentUsage: MSPAgentContextUsageRecord?,
        projectedInputItems: [MSPAgentJSONValue]
    ) -> MSPCompactionTokenStatus? {
        projectedPreTurnTokenStatus(
            currentUsage: currentUsage,
            projectedInputTokenCount: Self.approximateTokenCount(in: projectedInputItems)
        )
    }

    func projectedPreTurnTokenStatus(
        currentUsage: MSPAgentContextUsageRecord?,
        projectedInputTokenCount: Int
    ) -> MSPCompactionTokenStatus? {
        let estimatedUsage = estimatedContextUsageRecord(estimatedTokens: projectedInputTokenCount)
        guard let usageForLimits = estimatedUsage ?? currentUsage else {
            return nil
        }
        let projectedTokens = estimatedUsage?.currentTokens ?? 0
        let activeTokens = max(currentUsage?.currentTokens ?? 0, projectedTokens)
        return MSPCompactionTokenStatus(
            activeTokens: activeTokens,
            contextWindowTokens: usageForLimits.contextWindowTokens,
            autoCompactTokenLimit: usageForLimits.autoCompactTokenLimit,
            currentWindowPrefillTokens: currentWindowPrefillTokensForLimitEvaluation(
                observing: currentUsage
            )
        )
    }

    func assertProjectedInputFitsContextWindow(
        _ modelVisibleItems: [MSPAgentJSONValue]
    ) throws {
        guard let usage = estimatedContextUsageRecord(for: modelVisibleItems),
              usage.contextWindowTokens > 0,
              usage.currentTokens >= usage.contextWindowTokens else {
            return
        }
        throw MSPAgentModelClientError.contextWindowExceeded(
            "The next request is estimated at \(usage.currentTokens) tokens, over the \(usage.contextWindowTokens)-token context window, even after compacting previous context. Shorten the current message or start a new thread."
        )
    }

    static func approximateTokenCount(in items: [MSPAgentJSONValue]) -> Int {
        max(0, items.reduce(0) { total, item in
            total + approximateTokenCount(in: item)
        })
    }

    static func approximateTokenCount(in value: MSPAgentJSONValue) -> Int {
        switch value {
        case .string(let text):
            return max(1, (text.count + 3) / 4)
        case .number, .bool:
            return 1
        case .object(let object):
            return object.values.reduce(0) { total, value in
                total + approximateTokenCount(in: value)
            }
        case .array(let values):
            return values.reduce(0) { total, value in
                total + approximateTokenCount(in: value)
            }
        case .null:
            return 0
        }
    }
}

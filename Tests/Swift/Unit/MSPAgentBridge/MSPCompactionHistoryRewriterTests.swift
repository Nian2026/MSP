@testable import MSPAgentBridge
import XCTest

final class MSPCompactionHistoryRewriterTests: XCTestCase {
    func testDisabledPolicyDoesNotTriggerWhenUsageExceedsLimit() {
        let policy = MSPCompactionPolicy.disabled
        let status = MSPCompactionTokenStatus(
            activeTokens: 250_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000
        )

        XCTAssertNil(policy.preTurnDecision(
            tokenStatus: status,
            providerSupportsRemoteCompaction: true
        ))
    }

    func testEnabledPolicySelectsRemoteV2WhenProviderSupportsIt() throws {
        let policy = MSPCompactionPolicy(
            enabled: true,
            remoteCompactionEnabled: true,
            remoteCompactionV2Enabled: true
        )
        let status = MSPCompactionTokenStatus(
            activeTokens: 250_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000
        )

        let decision = try XCTUnwrap(policy.preTurnDecision(
            tokenStatus: status,
            providerSupportsRemoteCompaction: true
        ))

        XCTAssertEqual(decision.trigger, .auto)
        XCTAssertEqual(decision.reason, .contextLimit)
        XCTAssertEqual(decision.implementation, .responsesCompactionV2)
        XCTAssertEqual(decision.phase, .preTurn)
        XCTAssertEqual(decision.strategy, .memento)
    }

    func testBodyAfterPrefixScopeUsesTotalBudgetWhenPrefillBaselineIsMissing() throws {
        let policy = MSPCompactionPolicy(
            enabled: true,
            tokenLimitScope: .bodyAfterPrefix
        )
        let status = MSPCompactionTokenStatus(
            activeTokens: 250_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000,
            currentWindowPrefillTokens: nil
        )

        let decision = try XCTUnwrap(policy.preTurnDecision(
            tokenStatus: status,
            providerSupportsRemoteCompaction: false
        ))
        XCTAssertEqual(decision.trigger, .auto)
        XCTAssertEqual(decision.reason, .contextLimit)
        XCTAssertEqual(decision.implementation, .responses)
        XCTAssertEqual(decision.phase, .preTurn)
    }

    func testBodyAfterPrefixScopeStillTriggersAtFullContextWindow() throws {
        let policy = MSPCompactionPolicy(
            enabled: true,
            tokenLimitScope: .bodyAfterPrefix
        )
        let status = MSPCompactionTokenStatus(
            activeTokens: 272_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 300_000,
            currentWindowPrefillTokens: 260_000
        )

        let decision = try XCTUnwrap(policy.preTurnDecision(
            tokenStatus: status,
            providerSupportsRemoteCompaction: false
        ))

        XCTAssertEqual(decision.trigger, .auto)
        XCTAssertEqual(decision.reason, .contextLimit)
        XCTAssertEqual(decision.implementation, .responses)
        XCTAssertEqual(decision.phase, .preTurn)
    }

    func testPreviousModelPreTurnCompactsWhenCompHashChanges() throws {
        let policy = MSPCompactionPolicy(
            enabled: true,
            remoteCompactionEnabled: true,
            remoteCompactionV2Enabled: true
        )

        let result = try XCTUnwrap(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                compHash: "hash-a",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                compHash: "hash-b",
                contextWindowTokens: 125_000
            ),
            activeTokens: 100,
            providerSupportsRemoteCompaction: true
        ))

        XCTAssertEqual(result.compactionModel, "gpt-5.3-codex")
        XCTAssertEqual(result.decision.trigger, .auto)
        XCTAssertEqual(result.decision.reason, .compHashChanged)
        XCTAssertEqual(result.decision.implementation, .responsesCompactionV2)
        XCTAssertEqual(result.decision.phase, .preTurn)
        XCTAssertEqual(result.decision.strategy, .memento)
    }

    func testPreviousModelPreTurnSkipsWhenEitherCompHashIsMissing() {
        let policy = MSPCompactionPolicy(enabled: true)

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.4",
                compHash: nil,
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                compHash: "hash-a",
                contextWindowTokens: 273_000
            ),
            activeTokens: 100,
            providerSupportsRemoteCompaction: false
        ))

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                compHash: "hash-a",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                compHash: nil,
                contextWindowTokens: 273_000
            ),
            activeTokens: 100,
            providerSupportsRemoteCompaction: false
        ))
    }

    func testPreviousModelPreTurnDownshiftUsesTotalScopeThresholds() throws {
        let policy = MSPCompactionPolicy(enabled: true)

        let overAutoLimit = try XCTUnwrap(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 125_000,
                autoCompactTokenLimit: 120_000
            ),
            activeTokens: 120_001,
            providerSupportsRemoteCompaction: false
        ))
        XCTAssertEqual(overAutoLimit.compactionModel, "gpt-5.3-codex")
        XCTAssertEqual(overAutoLimit.decision.reason, .modelDownshift)
        XCTAssertEqual(overAutoLimit.decision.phase, .preTurn)

        let fullWindow = try XCTUnwrap(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 125_000,
                autoCompactTokenLimit: nil
            ),
            activeTokens: 125_000,
            providerSupportsRemoteCompaction: false
        ))
        XCTAssertEqual(fullWindow.decision.reason, .modelDownshift)
    }

    func testPreviousModelPreTurnDownshiftDoesNotTriggerAtEqualTotalAutoLimit() {
        let policy = MSPCompactionPolicy(enabled: true)

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 125_000,
                autoCompactTokenLimit: 120_000
            ),
            activeTokens: 120_000,
            providerSupportsRemoteCompaction: false
        ))
    }

    func testPreviousModelPreTurnBodyAfterPrefixUsesFullWindowForDownshift() throws {
        let policy = MSPCompactionPolicy(
            enabled: true,
            tokenLimitScope: .bodyAfterPrefix
        )

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 125_000,
                autoCompactTokenLimit: 20
            ),
            activeTokens: 150,
            providerSupportsRemoteCompaction: false
        ))

        let fullWindow = try XCTUnwrap(policy.previousModelPreTurnDecision(
            previous: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 273_000
            ),
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 125_000,
                autoCompactTokenLimit: 20
            ),
            activeTokens: 125_000,
            providerSupportsRemoteCompaction: false
        ))
        XCTAssertEqual(fullWindow.compactionModel, "gpt-5.3-codex")
        XCTAssertEqual(fullWindow.decision.reason, .modelDownshift)
    }

    func testPreviousModelPreTurnDownshiftRequiresDifferentSmallerModelWindow() {
        let policy = MSPCompactionPolicy(enabled: true)
        let previous = MSPCompactionModelSnapshot(
            model: "gpt-5.3-codex",
            contextWindowTokens: 125_000
        )

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: previous,
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.3-codex",
                contextWindowTokens: 100_000,
                autoCompactTokenLimit: 50_000
            ),
            activeTokens: 60_000,
            providerSupportsRemoteCompaction: false
        ))

        XCTAssertNil(policy.previousModelPreTurnDecision(
            previous: previous,
            current: MSPCompactionModelSnapshot(
                model: "gpt-5.2",
                contextWindowTokens: 200_000,
                autoCompactTokenLimit: 50_000
            ),
            activeTokens: 60_000,
            providerSupportsRemoteCompaction: false
        ))
    }

    func testMidTurnPendingInputCanTriggerCompactionWithoutModelFollowUp() throws {
        let policy = MSPCompactionPolicy(enabled: true)
        let status = MSPCompactionTokenStatus(
            activeTokens: 250_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000
        )

        let evaluation = policy.evaluateMidTurn(
            tokenStatus: status,
            providerSupportsRemoteCompaction: false,
            modelNeedsFollowUp: false,
            hasPendingInput: true
        )

        XCTAssertTrue(evaluation.needsFollowUp)
        XCTAssertTrue(evaluation.canDrainPendingInputAfterCompaction)
        let decision = try XCTUnwrap(evaluation.decision)
        XCTAssertEqual(decision.trigger, .auto)
        XCTAssertEqual(decision.reason, .contextLimit)
        XCTAssertEqual(decision.implementation, .responses)
        XCTAssertEqual(decision.phase, .midTurn)
        XCTAssertEqual(decision.strategy, .memento)
    }

    func testMidTurnModelFollowUpDefersPendingInputDrainAfterCompaction() throws {
        let policy = MSPCompactionPolicy(enabled: true)
        let status = MSPCompactionTokenStatus(
            activeTokens: 250_000,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000
        )

        let evaluation = policy.evaluateMidTurn(
            tokenStatus: status,
            providerSupportsRemoteCompaction: false,
            modelNeedsFollowUp: true,
            hasPendingInput: true
        )

        XCTAssertTrue(evaluation.needsFollowUp)
        XCTAssertFalse(evaluation.canDrainPendingInputAfterCompaction)
        let decision = try XCTUnwrap(evaluation.decision)
        XCTAssertEqual(decision.phase, .midTurn)
        XCTAssertEqual(decision.reason, .contextLimit)
    }

    func testMidTurnPendingInputDoesNotCompactWhenContinuationFits() {
        let policy = MSPCompactionPolicy(enabled: true)
        let status = MSPCompactionTokenStatus(
            activeTokens: 100,
            contextWindowTokens: 272_000,
            autoCompactTokenLimit: 200_000
        )

        let evaluation = policy.evaluateMidTurn(
            tokenStatus: status,
            providerSupportsRemoteCompaction: false,
            modelNeedsFollowUp: false,
            hasPendingInput: true
        )

        XCTAssertTrue(evaluation.needsFollowUp)
        XCTAssertTrue(evaluation.canDrainPendingInputAfterCompaction)
        XCTAssertNil(evaluation.decision)
    }

    func testContextWindowLineageAdvancesLikeCodexAutoCompactWindow() {
        var lineage = MSPContextWindowLineageState(firstWindowID: "window-0")

        XCTAssertEqual(lineage.lineage.windowNumber, 0)
        XCTAssertEqual(lineage.lineage.firstWindowID, "window-0")
        XCTAssertNil(lineage.lineage.previousWindowID)
        XCTAssertEqual(lineage.lineage.currentWindowID, "window-0")

        let firstCompaction = lineage.advance(nextWindowID: "window-1")
        XCTAssertEqual(firstCompaction.windowNumber, 1)
        XCTAssertEqual(firstCompaction.firstWindowID, "window-0")
        XCTAssertEqual(firstCompaction.previousWindowID, "window-0")
        XCTAssertEqual(firstCompaction.currentWindowID, "window-1")

        let secondCompaction = lineage.advance(nextWindowID: "window-2")
        XCTAssertEqual(secondCompaction.windowNumber, 2)
        XCTAssertEqual(secondCompaction.firstWindowID, "window-0")
        XCTAssertEqual(secondCompaction.previousWindowID, "window-1")
        XCTAssertEqual(secondCompaction.currentWindowID, "window-2")
    }
}

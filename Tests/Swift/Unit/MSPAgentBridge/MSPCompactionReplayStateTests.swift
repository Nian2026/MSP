@testable import MSPAgentBridge
import XCTest

extension MSPCompactionHistoryRewriterTests {
    func testWorldStateReplayAppliesFullSnapshotAndPatchChronologically() {
        let replay = MSPCompactionCheckpointReplay.replayWorldStateChronologically([
            .fullSnapshot(.object([
                "environment": .object([
                    "status": .string("starting"),
                    "cwd": .string("/workspace")
                ])
            ])),
            .patch(.object([
                "environment": .object([
                    "status": .string("ready")
                ])
            ]))
        ])

        XCTAssertEqual(replay.baseline, .object([
            "environment": .object([
                "status": .string("ready"),
                "cwd": .string("/workspace")
            ])
        ]))
        XCTAssertFalse(replay.isDegraded)
        XCTAssertEqual(replay.degradations, [])
    }

    func testWorldStateReplayCompactionClearsPreviousBaseline() {
        let replay = MSPCompactionCheckpointReplay.replayWorldStateChronologically([
            .fullSnapshot(.object([
                "environment": .object([
                    "status": .string("old")
                ])
            ])),
            .compactionBoundary()
        ])

        XCTAssertNil(replay.baseline)
        XCTAssertFalse(replay.isDegraded)
    }

    func testWorldStateReplayPatchWithoutBaselineRecordsDegradedState() {
        let replay = MSPCompactionCheckpointReplay.replayWorldStateChronologically([
            .patch(.object([
                "environment": .object([
                    "status": .string("ignored")
                ])
            ]))
        ])

        XCTAssertNil(replay.baseline)
        XCTAssertEqual(replay.degradations, [
            MSPCompactionWorldStateReplayDegradation(
                index: 0,
                reason: .patchWithoutBaseline
            )
        ])
    }

    func testWorldStateReplayInvalidPatchClearsBaselineAndRecordsDegradedState() {
        let replay = MSPCompactionCheckpointReplay.replayWorldStateChronologically([
            .fullSnapshot(.object([
                "environment": .object([
                    "status": .string("starting")
                ])
            ])),
            .patch(.string("not a world-state snapshot"))
        ])

        XCTAssertNil(replay.baseline)
        XCTAssertEqual(replay.degradations, [
            MSPCompactionWorldStateReplayDegradation(
                index: 1,
                reason: .patchApplicationFailed
            )
        ])
    }

    func testWorldStateReplayInvalidFullSnapshotClearsBaselineAndRecordsDegradedState() {
        let replay = MSPCompactionCheckpointReplay.replayWorldStateChronologically([
            .fullSnapshot(.string("not a world-state snapshot"))
        ])

        XCTAssertNil(replay.baseline)
        XCTAssertEqual(replay.degradations, [
            MSPCompactionWorldStateReplayDegradation(
                index: 0,
                reason: .invalidFullSnapshot
            )
        ])
    }

    func testReferenceContextReplayBareTurnContextDoesNotSeedReferenceContext() {
        let replay = MSPCompactionCheckpointReplay.replayReferenceContext(
            fromChronologicalItems: [
                .turnContext(Self.turnContext(turnID: "turn-1", model: "gpt-5.4"))
            ]
        )

        XCTAssertNil(replay.previousTurnSettings)
        XCTAssertEqual(replay.referenceContextState, .neverSet)
        XCTAssertNil(replay.referenceContextItem)
    }

    func testReferenceContextReplayCompactionClearsOlderReferenceContext() {
        let snapshot = Self.turnContext(
            turnID: "turn-1",
            model: "gpt-5.4",
            compHash: "hash-a",
            realtimeActive: true
        )

        let replay = MSPCompactionCheckpointReplay.replayReferenceContext(
            fromChronologicalItems: [
                .turnStarted(id: "turn-1"),
                .userMessage,
                .turnContext(snapshot),
                .compaction,
                .turnComplete(id: "turn-1")
            ]
        )

        XCTAssertEqual(replay.previousTurnSettings, MSPCompactionPreviousTurnSettings(
            model: "gpt-5.4",
            compHash: "hash-a",
            realtimeActive: true
        ))
        XCTAssertEqual(replay.referenceContextState, .cleared)
        XCTAssertNil(replay.referenceContextItem)
    }

    func testReferenceContextReplayTurnContextAfterCompactionReestablishesReferenceContext() {
        let snapshot = Self.turnContext(
            turnID: "turn-1",
            model: "gpt-5.4",
            compHash: "hash-b",
            realtimeActive: false
        )

        let replay = MSPCompactionCheckpointReplay.replayReferenceContext(
            fromChronologicalItems: [
                .turnStarted(id: "turn-1"),
                .userMessage,
                .compaction,
                .turnContext(snapshot),
                .turnComplete(id: "turn-1")
            ]
        )

        XCTAssertEqual(replay.previousTurnSettings, MSPCompactionPreviousTurnSettings(
            model: "gpt-5.4",
            compHash: "hash-b",
            realtimeActive: false
        ))
        XCTAssertEqual(replay.referenceContextState, .latest(snapshot))
        XCTAssertEqual(replay.referenceContextItem, snapshot)
    }

    func testReferenceContextReplayRollbackDropsIncompleteCompactedUserTurnMetadata() {
        let surviving = Self.turnContext(
            turnID: "turn-1",
            model: "gpt-5.4",
            compHash: "hash-surviving",
            realtimeActive: true
        )
        let rolledBack = Self.turnContext(
            turnID: "turn-2",
            model: "rolled-back-model",
            compHash: "hash-rolled-back",
            realtimeActive: false
        )

        let replay = MSPCompactionCheckpointReplay.replayReferenceContext(
            fromChronologicalItems: [
                .turnStarted(id: "turn-1"),
                .userMessage,
                .turnContext(surviving),
                .turnComplete(id: "turn-1"),
                .turnStarted(id: "turn-2"),
                .userMessage,
                .turnContext(rolledBack),
                .compaction,
                .rollback(userTurns: 1)
            ]
        )

        XCTAssertEqual(replay.previousTurnSettings, MSPCompactionPreviousTurnSettings(
            model: "gpt-5.4",
            compHash: "hash-surviving",
            realtimeActive: true
        ))
        XCTAssertEqual(replay.referenceContextState, .latest(surviving))
        XCTAssertEqual(replay.referenceContextItem, surviving)
    }
}

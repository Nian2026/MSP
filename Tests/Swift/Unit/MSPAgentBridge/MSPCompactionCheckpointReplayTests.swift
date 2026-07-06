@testable import MSPAgentBridge
import XCTest

extension MSPCompactionHistoryRewriterTests {
    func testCheckpointReplayRebuildsExactReplacementHistoryWithSuffixAndLineage() throws {
        let replacementHistory = [
            Self.message(role: "developer", text: "fresh context"),
            Self.message(role: "user", text: "compacted summary")
        ]
        let suffixItems = [
            Self.message(role: "user", text: "surviving follow-up")
        ]
        let lineage = MSPCompactionWindowLineage(
            windowNumber: 3,
            firstWindowID: "window-0",
            previousWindowID: "window-2",
            currentWindowID: "window-3"
        )
        let checkpoint = try MSPCompactionCheckpointBuilder.checkpoint(
            checkpointID: "checkpoint-1",
            sourceItems: [
                Self.message(role: "user", text: "old user"),
                Self.message(role: "assistant", text: "old answer", contentType: "output_text")
            ],
            replacementHistory: replacementHistory,
            summaryRef: "summary-blob",
            lineage: lineage
        )

        let replay = try MSPCompactionCheckpointReplay.rebuildExactModelVisibleHistory(
            from: checkpoint,
            suffixItems: suffixItems
        )

        XCTAssertEqual(replay.checkpointID, "checkpoint-1")
        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory + suffixItems)
        XCTAssertEqual(replay.lineage, lineage)
        XCTAssertEqual(replay.replayMode, .exact)
    }

    func testCheckpointReplayRejectsReplacementHistoryHashMismatch() throws {
        var checkpoint = try Self.checkpoint(
            replacementHistory: [
                Self.message(role: "user", text: "summary")
            ]
        )
        checkpoint.replacementHistoryHash = "fnv1a64:deadbeefdeadbeef"

        XCTAssertThrowsError(try MSPCompactionCheckpointReplay.rebuildExactModelVisibleHistory(
            from: checkpoint
        )) { error in
            XCTAssertEqual(error as? MSPCompactionReplayError, .replacementHistoryHashMismatch(
                checkpointID: "checkpoint-1"
            ))
        }
    }

    func testCheckpointReplayRejectsMissingReplacementHistory() throws {
        let checkpoint = MSPCompactionCheckpoint(
            checkpointID: "checkpoint-1",
            sourceRange: MSPCompactionSourceRange(sourceHash: "source"),
            replacementHistory: nil,
            replacementHistoryHash: nil,
            lineage: Self.lineage(),
            replayMode: .exact
        )

        XCTAssertThrowsError(try MSPCompactionCheckpointReplay.rebuildExactModelVisibleHistory(
            from: checkpoint
        )) { error in
            XCTAssertEqual(error as? MSPCompactionReplayError, .missingReplacementHistory(
                checkpointID: "checkpoint-1"
            ))
        }
    }

    func testCheckpointReplayRejectsUnsupportedReplayMode() throws {
        var checkpoint = try Self.checkpoint(
            replacementHistory: [
                Self.message(role: "user", text: "summary")
            ]
        )
        checkpoint.replayMode = .resumeDegraded

        XCTAssertThrowsError(try MSPCompactionCheckpointReplay.rebuildExactModelVisibleHistory(
            from: checkpoint
        )) { error in
            XCTAssertEqual(error as? MSPCompactionReplayError, .unsupportedReplayMode(
                checkpointID: "checkpoint-1",
                mode: .resumeDegraded
            ))
        }
    }

    func testCheckpointReplayRebuildsLegacyCompactionFromPriorUsersAndSummary() throws {
        let priorHistory = [
            Self.message(role: "user", text: "before compact"),
            Self.message(role: "assistant", text: "assistant reply", contentType: "output_text"),
            Self.message(role: "user", text: "\(MSPCompactionHistoryRewriter.summaryPrefix)\nold summary")
        ]
        let suffixItems = [
            Self.message(role: "user", text: "after legacy compact")
        ]
        let checkpoint = MSPCompactionCheckpoint(
            checkpointID: "legacy-checkpoint",
            sourceRange: MSPCompactionSourceRange(sourceHash: "source-hash"),
            replacementHistory: nil,
            summaryText: "legacy summary",
            lineage: Self.lineage(),
            replayMode: .rebuildLegacy
        )

        let replay = try MSPCompactionCheckpointReplay.rebuildLegacyModelVisibleHistory(
            from: checkpoint,
            priorHistory: priorHistory,
            suffixItems: suffixItems
        )

        XCTAssertEqual(replay.checkpointID, "legacy-checkpoint")
        XCTAssertEqual(replay.replayMode, .rebuildLegacy)
        XCTAssertEqual(Self.messageTexts(from: replay.modelVisibleHistory), [
            "before compact",
            "legacy summary",
            "after legacy compact"
        ])
    }

    func testChatReplayRebuildsBlobBackedCheckpointWithSuffixAndIgnoresProjection() throws {
        let replacementHistory = [
            Self.message(role: "developer", text: "fresh context"),
            Self.message(role: "user", text: "checkpoint summary")
        ]
        let suffix = Self.message(role: "user", text: "surviving suffix")
        let checkpoint = try Self.chatCheckpoint(
            replacementHistoryRef: "blobs/replacement-1",
            replacementHistoryHash: MSPCompactionCheckpointBuilder.fingerprint(replacementHistory)
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(checkpoint),
                .modelVisibleSuffixItem(suffix)
            ],
            blobs: [
                "blobs/replacement-1": replacementHistory
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection must not be canonical")
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.checkpointID, "checkpoint-1")
        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory + [suffix])
        XCTAssertEqual(replay.lineage, Self.lineage())
        XCTAssertEqual(replay.replayMode, .exact)
        XCTAssertFalse(replay.usedModelContextProjection)
        XCTAssertEqual(replay.referenceContext.referenceContextState, .cleared)
    }

    func testChatReplayUsesJournalReplacementHistoryBeforeProjection() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "journal replacement")
        ]
        let checkpoint = try Self.chatCheckpoint(
            replacementHistoryRef: "journal/replacement-1",
            replacementHistoryHash: MSPCompactionCheckpointBuilder.fingerprint(replacementHistory)
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(checkpoint)
            ],
            journal: [
                MSPChatCompactionJournalEntry(
                    ref: "journal/replacement-1",
                    sourceTransport: .object([
                        "type": .string("source_transport")
                    ]),
                    replacementHistory: replacementHistory
                )
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection")
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory)
        XCTAssertFalse(replay.usedModelContextProjection)
    }

    func testChatReplayRejectsMissingReplacementHistoryBlob() throws {
        let checkpoint = try Self.chatCheckpoint(
            replacementHistoryRef: "blobs/missing",
            replacementHistoryHash: nil
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(checkpoint)
            ],
            blobs: [:],
            modelContextProjection: [
                Self.message(role: "user", text: "projection cannot repair missing blob")
            ]
        )

        XCTAssertThrowsError(try MSPChatCompactionReplay.rebuildModelContext(from: package)) { error in
            XCTAssertEqual(error as? MSPChatCompactionReplayError, .missingReplacementHistory(
                checkpointID: "checkpoint-1",
                ref: "blobs/missing"
            ))
        }
    }

    func testChatReplayRejectsBlobReplacementHistoryHashMismatch() throws {
        let checkpoint = try Self.chatCheckpoint(
            replacementHistoryRef: "blobs/replacement-1",
            replacementHistoryHash: "fnv1a64:deadbeefdeadbeef"
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(checkpoint)
            ],
            blobs: [
                "blobs/replacement-1": [
                    Self.message(role: "user", text: "tampered replacement")
                ]
            ]
        )

        XCTAssertThrowsError(try MSPChatCompactionReplay.rebuildModelContext(from: package)) { error in
            XCTAssertEqual(error as? MSPChatCompactionReplayError, .replacementHistoryHashMismatch(
                checkpointID: "checkpoint-1"
            ))
        }
    }

    func testChatReplayComposesCheckpointSuffixWorldStateAndReferenceContext() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "summary")
        ]
        let checkpoint = try Self.chatCheckpoint(
            replacementHistory: replacementHistory
        )
        let snapshot = Self.turnContext(
            turnID: "turn-1",
            model: "gpt-5.4",
            compHash: "hash-a",
            realtimeActive: true
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .referenceContext(.turnStarted(id: "turn-1")),
                .referenceContext(.userMessage),
                .referenceContext(.turnContext(snapshot)),
                .worldState(.fullSnapshot(.object([
                    "environment": .object([
                        "status": .string("old")
                    ])
                ]))),
                .durableCompactionCheckpoint(checkpoint),
                .worldState(.fullSnapshot(.object([
                    "environment": .object([
                        "status": .string("fresh")
                    ])
                ]))),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "follow-up"))
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory + [
            Self.message(role: "user", text: "follow-up")
        ])
        XCTAssertEqual(replay.worldState.baseline, .object([
            "environment": .object([
                "status": .string("fresh")
            ])
        ]))
        XCTAssertEqual(replay.referenceContext.previousTurnSettings, MSPCompactionPreviousTurnSettings(
            model: "gpt-5.4",
            compHash: "hash-a",
            realtimeActive: true
        ))
        XCTAssertEqual(replay.referenceContext.referenceContextState, .cleared)
    }

    func testChatReplayRollbackDropsCheckpointInsideRolledBackUserTurn() throws {
        let survivingReplacement = [
            Self.message(role: "user", text: "surviving compacted base")
        ]
        let rolledBackReplacement = [
            Self.message(role: "user", text: "rolled-back compacted base")
        ]
        let survivingCheckpoint = try Self.chatCheckpoint(
            checkpointID: "checkpoint-surviving",
            replacementHistory: survivingReplacement
        )
        let rolledBackCheckpoint = try Self.chatCheckpoint(
            checkpointID: "checkpoint-rolled-back",
            replacementHistory: rolledBackReplacement
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .referenceContext(.turnStarted(id: "turn-1")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(survivingCheckpoint),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "surviving suffix")),
                .referenceContext(.turnComplete(id: "turn-1")),
                .referenceContext(.turnStarted(id: "turn-2")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(rolledBackCheckpoint),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "rolled-back suffix")),
                .rollback(userTurns: 1)
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.checkpointID, "checkpoint-surviving")
        XCTAssertEqual(replay.modelVisibleHistory, survivingReplacement + [
            Self.message(role: "user", text: "surviving suffix")
        ])
    }

    func testChatReplayRollbackSkipsNonUserSegmentsWithoutConsumingRollbackCount() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "base")
        ]
        let checkpoint = try Self.chatCheckpoint(
            checkpointID: "checkpoint-surviving",
            replacementHistory: replacementHistory
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(checkpoint),
                .referenceContext(.turnStarted(id: "rolled-back-user")),
                .referenceContext(.userMessage),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "rolled-back user")),
                .referenceContext(.turnComplete(id: "rolled-back-user")),
                .referenceContext(.turnStarted(id: "standalone")),
                .modelVisibleSuffixItem(Self.message(
                    role: "assistant",
                    text: "standalone assistant",
                    contentType: "output_text"
                )),
                .referenceContext(.turnComplete(id: "standalone")),
                .rollback(userTurns: 1)
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.checkpointID, "checkpoint-surviving")
        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory)
    }

    func testChatReplayLegacyCheckpointRebuildsAndClearsLaterReferenceContext() throws {
        let snapshot = Self.turnContext(
            turnID: "turn-after-legacy",
            model: "gpt-5.4",
            compHash: "hash-after",
            realtimeActive: true
        )
        let checkpoint = try Self.chatCheckpoint(
            checkpointID: "legacy-checkpoint",
            summaryText: "legacy summary",
            replayMode: .rebuildLegacy
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .modelVisibleSuffixItem(Self.message(role: "user", text: "before compact")),
                .modelVisibleSuffixItem(Self.message(
                    role: "assistant",
                    text: "assistant reply",
                    contentType: "output_text"
                )),
                .durableCompactionCheckpoint(checkpoint),
                .referenceContext(.turnStarted(id: "turn-after-legacy")),
                .referenceContext(.userMessage),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "after legacy compact")),
                .referenceContext(.turnContext(snapshot)),
                .referenceContext(.turnComplete(id: "turn-after-legacy"))
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection")
            ]
        )

        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: package)

        XCTAssertEqual(replay.checkpointID, "legacy-checkpoint")
        XCTAssertEqual(replay.replayMode, .rebuildLegacy)
        XCTAssertEqual(Self.messageTexts(from: replay.modelVisibleHistory), [
            "before compact",
            "legacy summary",
            "after legacy compact"
        ])
        XCTAssertEqual(replay.referenceContext.previousTurnSettings, MSPCompactionPreviousTurnSettings(
            model: "gpt-5.4",
            compHash: "hash-after",
            realtimeActive: true
        ))
        XCTAssertEqual(replay.referenceContext.referenceContextState, .cleared)
        XCTAssertNil(replay.referenceContext.referenceContextItem)
        XCTAssertFalse(replay.usedModelContextProjection)
    }
}

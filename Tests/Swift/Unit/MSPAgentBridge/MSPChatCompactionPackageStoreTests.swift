import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPChatCompactionPackageStoreTests: XCTestCase {
    func testOnDiskPackageReplayRebuildsBlobBackedCheckpointAndIgnoresProjection() throws {
        let replacementHistory = [
            Self.message(role: "developer", text: "fresh context"),
            Self.message(role: "user", text: "checkpoint summary")
        ]
        let suffix = Self.message(role: "user", text: "surviving suffix")
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(try Self.checkpoint(
                    replacementHistoryRef: "blobs/replacement-history.json",
                    replacementHistoryHash: MSPCompactionCheckpointBuilder.fingerprint(replacementHistory)
                )),
                .modelVisibleSuffixItem(suffix)
            ],
            blobs: [
                "blobs/replacement-history.json": replacementHistory
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection must not be canonical")
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory + [suffix])
        XCTAssertEqual(replay.lineage, Self.lineage())
        XCTAssertFalse(replay.usedModelContextProjection)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("timeline.ndjson").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("journal.ndjson").path
        ))
        XCTAssertNotNil(loaded.modelContextProjection)
    }

    func testOnDiskPackageReplayUsesJournalReplacementHistoryBeforeProjection() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "journal replacement")
        ]
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(try Self.checkpoint(
                    replacementHistoryRef: "journal/replacement-history",
                    replacementHistoryHash: MSPCompactionCheckpointBuilder.fingerprint(replacementHistory)
                ))
            ],
            journal: [
                MSPChatCompactionJournalEntry(
                    ref: "journal/replacement-history",
                    sourceTransport: .object(["schema": .string("source_transport")]),
                    replacementHistory: replacementHistory
                )
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection")
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory)
        XCTAssertFalse(replay.usedModelContextProjection)
    }

    func testOnDiskPackageReplayFailsWhenReplacementBlobIsMissing() throws {
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(try Self.checkpoint(
                    replacementHistoryRef: "blobs/missing-replacement.json",
                    replacementHistoryHash: nil
                ))
            ],
            blobs: [
                "blobs/missing-replacement.json": [
                    Self.message(role: "user", text: "will be removed")
                ]
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "projection cannot repair missing blob")
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try FileManager.default.removeItem(
            at: packageURL.appendingPathComponent("blobs/missing-replacement.json")
        )

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)

        XCTAssertThrowsError(try MSPChatCompactionReplay.rebuildModelContext(from: loaded)) { error in
            XCTAssertEqual(error as? MSPChatCompactionReplayError, .missingReplacementHistory(
                checkpointID: "checkpoint-1",
                ref: "blobs/missing-replacement.json"
            ))
        }
    }

    func testModelContextProjectionRepairsFromTimelineWithoutBecomingCanonical() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "replacement baseline")
        ]
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .durableCompactionCheckpoint(try Self.checkpoint(
                    replacementHistory: replacementHistory
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "follow-up"))
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale projection")
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try MSPChatCompactionPackageStore.rebuildModelContextProjection(at: packageURL)

        let projectionText = try String(
            contentsOf: packageURL.appendingPathComponent("projections/model-context.ndjson"),
            encoding: .utf8
        )
        XCTAssertFalse(projectionText.contains("stale projection"))
        XCTAssertTrue(projectionText.contains("\"not_canonical\":true"))
        XCTAssertTrue(projectionText.contains("durable_compaction_checkpoint"))

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)
        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory + [
            Self.message(role: "user", text: "follow-up")
        ])
        XCTAssertFalse(replay.usedModelContextProjection)
    }

    func testOnDiskPackageReplayAppliesTimelineRollbackBeforeCheckpointSelection() throws {
        let survivingReplacement = [
            Self.message(role: "user", text: "surviving base")
        ]
        let rolledBackReplacement = [
            Self.message(role: "user", text: "rolled-back base")
        ]
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .referenceContext(.turnStarted(id: "turn-1")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "checkpoint-surviving",
                    replacementHistory: survivingReplacement
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "surviving suffix")),
                .referenceContext(.turnComplete(id: "turn-1")),
                .referenceContext(.turnStarted(id: "turn-2")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "checkpoint-rolled-back",
                    replacementHistory: rolledBackReplacement
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "rolled-back suffix")),
                .rollback(userTurns: 1)
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let timelineText = try String(
            contentsOf: packageURL.appendingPathComponent("timeline.ndjson"),
            encoding: .utf8
        )
        XCTAssertTrue(timelineText.contains("\"type\":\"timeline_rollback\""))

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.checkpointID, "checkpoint-surviving")
        XCTAssertEqual(replay.modelVisibleHistory, survivingReplacement + [
            Self.message(role: "user", text: "surviving suffix")
        ])
    }

    func testOnDiskPackageReplayForkPrefixCarriesCompactedBaseAndSuffix() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "hello world"),
            Self.message(role: "user", text: "compaction summary")
        ]
        let original = MSPChatCompactionPackageSnapshot(
            timeline: [
                .referenceContext(.turnStarted(id: "turn-after-compact")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "checkpoint-after-compact",
                    replacementHistory: replacementHistory
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "AFTER_COMPACT")),
                .referenceContext(.turnComplete(id: "turn-after-compact")),
                .referenceContext(.turnStarted(id: "turn-after-resume")),
                .referenceContext(.userMessage),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "AFTER_RESUME")),
                .referenceContext(.turnComplete(id: "turn-after-resume"))
            ],
            modelContextProjection: [
                Self.message(role: "user", text: "stale original projection AFTER_RESUME")
            ]
        )
        var forked = original.forkedPrefix(throughTimelineIndex: 4)
        forked.timeline.append(contentsOf: [
            .referenceContext(.turnStarted(id: "turn-after-fork")),
            .referenceContext(.userMessage),
            .modelVisibleSuffixItem(Self.message(role: "user", text: "AFTER_FORK")),
            .referenceContext(.turnComplete(id: "turn-after-fork"))
        ])
        let packageURL = try Self.writeTemporaryPackage(forked)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let timelineText = try String(
            contentsOf: packageURL.appendingPathComponent("timeline.ndjson"),
            encoding: .utf8
        )
        XCTAssertTrue(timelineText.contains("AFTER_COMPACT"))
        XCTAssertTrue(timelineText.contains("AFTER_FORK"))
        XCTAssertFalse(timelineText.contains("AFTER_RESUME"))

        let projectionText = try String(
            contentsOf: packageURL.appendingPathComponent("projections/model-context.ndjson"),
            encoding: .utf8
        )
        XCTAssertFalse(projectionText.contains("stale original projection"))
        XCTAssertFalse(projectionText.contains("AFTER_RESUME"))

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.checkpointID, "checkpoint-after-compact")
        XCTAssertEqual(Self.messageTexts(from: replay.modelVisibleHistory), [
            "hello world",
            "compaction summary",
            "AFTER_COMPACT",
            "AFTER_FORK"
        ])
        XCTAssertFalse(replay.usedModelContextProjection)
    }

    func testOnDiskPackageReplayRebuildsLegacyCheckpointAndClearsReferenceContext() throws {
        let snapshot = MSPCompactionTurnContextSnapshot(
            turnID: "turn-after-legacy",
            cwd: "/workspace",
            workspaceRoots: ["/workspace"],
            currentDate: "2026-07-01",
            timezone: "Asia/Shanghai",
            approvalPolicy: "never",
            sandboxPolicy: "danger-full-access",
            model: "gpt-5.4",
            compHash: "hash-after",
            realtimeActive: true
        )
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .modelVisibleSuffixItem(Self.message(role: "user", text: "before compact")),
                .modelVisibleSuffixItem(Self.message(
                    role: "assistant",
                    text: "assistant reply",
                    contentType: "output_text"
                )),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "legacy-checkpoint",
                    summaryText: "legacy summary",
                    replayMode: .rebuildLegacy
                )),
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
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

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
        XCTAssertFalse(replay.usedModelContextProjection)
    }

    func testStaleIndexDoesNotAffectCheckpointSelection() throws {
        let survivingReplacement = [
            Self.message(role: "user", text: "surviving base")
        ]
        let rolledBackReplacement = [
            Self.message(role: "user", text: "rolled-back base from stale index")
        ]
        let package = MSPChatCompactionPackageSnapshot(
            timeline: [
                .referenceContext(.turnStarted(id: "turn-1")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "checkpoint-surviving",
                    replacementHistory: survivingReplacement
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "surviving suffix")),
                .referenceContext(.turnComplete(id: "turn-1")),
                .referenceContext(.turnStarted(id: "turn-2")),
                .referenceContext(.userMessage),
                .durableCompactionCheckpoint(try Self.checkpoint(
                    checkpointID: "checkpoint-rolled-back",
                    replacementHistory: rolledBackReplacement
                )),
                .modelVisibleSuffixItem(Self.message(role: "user", text: "rolled-back suffix")),
                .rollback(userTurns: 1)
            ]
        )
        let packageURL = try Self.writeTemporaryPackage(package)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try Self.writeStaleCompactionIndex(
            checkpointID: "checkpoint-rolled-back",
            to: packageURL
        )

        let indexText = try String(
            contentsOf: packageURL.appendingPathComponent("indexes/compaction-checkpoints.ndjson"),
            encoding: .utf8
        )
        XCTAssertTrue(indexText.contains("checkpoint-rolled-back"))

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.checkpointID, "checkpoint-surviving")
        XCTAssertEqual(replay.modelVisibleHistory, survivingReplacement + [
            Self.message(role: "user", text: "surviving suffix")
        ])
    }

    func testOnDiskPackageMigratesLegacyNumericWindowIDToWindowNumber() throws {
        let replacementHistory = [
            Self.message(role: "user", text: "legacy numeric window id base")
        ]
        var checkpointValue = try MSPAgentJSONValue(encoding: Self.checkpoint(
            replacementHistory: replacementHistory
        ))
        guard var checkpointObject = checkpointValue.objectValue else {
            XCTFail("checkpoint should encode as an object")
            return
        }
        checkpointObject["lineage"] = .object([
            "window_id": .number(3)
        ])
        checkpointValue = .object(checkpointObject)
        let legacyTimelineRecord: MSPAgentJSONValue = .object([
            "id": .string("evt-legacy-compact"),
            "type": .string("durable_compaction_checkpoint"),
            "seq": .number(1),
            "commit_seq": .number(1),
            "actor": .string("msp-agent"),
            "durability": .string("durable_replay"),
            "body": .object([
                "checkpoint": checkpointValue
            ])
        ])
        let packageURL = try Self.writeTemporaryLegacyPackage(timeline: [legacyTimelineRecord])
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let loaded = try MSPChatCompactionPackageStore.loadPackage(at: packageURL)
        let replay = try MSPChatCompactionReplay.rebuildModelContext(from: loaded)

        XCTAssertEqual(replay.modelVisibleHistory, replacementHistory)
        XCTAssertEqual(replay.lineage.windowNumber, 3)
        XCTAssertNil(replay.lineage.currentWindowID)
    }

    private static func writeTemporaryPackage(
        _ package: MSPChatCompactionPackageSnapshot
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatCompactionPackageStoreTests-\(UUID().uuidString).chat")
        try MSPChatCompactionPackageStore.writePackage(package, to: url)
        return url
    }

    private static func writeTemporaryLegacyPackage(
        timeline: [MSPAgentJSONValue]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatCompactionPackageStoreTests-\(UUID().uuidString).chat")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try timeline
            .map(jsonLine)
            .joined(separator: "\n")
            .appending("\n")
            .write(
                to: url.appendingPathComponent("timeline.ndjson"),
                atomically: true,
                encoding: .utf8
            )
        return url
    }

    private static func writeStaleCompactionIndex(
        checkpointID: String,
        to packageURL: URL
    ) throws {
        let indexesURL = packageURL.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: indexesURL,
            withIntermediateDirectories: true
        )
        let staleRecord = """
        {"record_type":"derived_index","index_kind":"compaction-checkpoints","checkpoint_id":"\(checkpointID)","stale":true}

        """
        try staleRecord.write(
            to: indexesURL.appendingPathComponent("compaction-checkpoints.ndjson"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func checkpoint(
        checkpointID: String = "checkpoint-1",
        replacementHistory: [MSPAgentJSONValue]? = nil,
        replacementHistoryRef: String? = nil,
        replacementHistoryHash: String? = nil,
        summaryText: String? = nil,
        replayMode: MSPCompactionReplayMode = .exact
    ) throws -> MSPCompactionCheckpoint {
        let historyHash: String?
        if let replacementHistoryHash {
            historyHash = replacementHistoryHash
        } else if let replacementHistory {
            historyHash = try MSPCompactionCheckpointBuilder.fingerprint(replacementHistory)
        } else {
            historyHash = nil
        }
        return MSPCompactionCheckpoint(
            checkpointID: checkpointID,
            sourceRange: MSPCompactionSourceRange(sourceHash: "source-hash"),
            replacementHistory: replacementHistory,
            replacementHistoryRef: replacementHistoryRef,
            replacementHistoryHash: historyHash,
            summaryText: summaryText,
            lineage: lineage(),
            replayMode: replayMode
        )
    }

    private static func lineage() -> MSPCompactionWindowLineage {
        MSPCompactionWindowLineage(
            windowNumber: 1,
            firstWindowID: "window-0",
            previousWindowID: "window-0",
            currentWindowID: "window-1"
        )
    }

    private static func message(
        role: String,
        text: String,
        contentType: String = "input_text"
    ) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(contentType),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private static func messageTexts(from items: [MSPAgentJSONValue]) -> [String] {
        items.map { item in
            guard let content = item.objectValue?["content"]?.arrayValue else {
                return ""
            }
            return content.compactMap { $0.objectValue?["text"]?.stringValue }
                .joined(separator: "\n")
        }
    }

    private static func jsonLine(_ value: MSPAgentJSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

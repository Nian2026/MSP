import Foundation
import XCTest
import MSPAgentBridge
import MSPChat
@testable import MSPAgentChatStore

final class MSPAgentChatStoreTests: XCTestCase {
    func testCreatesPackageAndRestoresModelVisibleHistoryInOrder() throws {
        let packageURL = try makeTemporaryPackageURL(named: "ordered.chat")
        let store = MSPAgentChatStore()
        let userItem = messageItem(role: "user", text: "整理截图")
        let assistantItem = messageItem(role: "assistant", text: "我先看缓存。")
        let toolCallItem: MSPAgentJSONValue = .object([
            "type": .string("function_call"),
            "call_id": .string("call-1"),
            "name": .string("exec_command"),
            "arguments": .string("{\"cmd\":\"media status\"}")
        ])

        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_ordered",
            createdAt: "2026-07-02T01:00:00Z",
            initialModelVisibleHistory: [userItem]
        )
        try session.appendModelVisibleItems(
            [assistantItem, toolCallItem],
            createdAt: "2026-07-02T01:00:01Z",
            turnID: "turn-1"
        )

        let reopened = try store.openPackage(at: packageURL)
        XCTAssertEqual(try reopened.modelVisibleHistory(), [userItem, assistantItem, toolCallItem])

        let package = try reopened.packageSnapshot()
        XCTAssertEqual(package.manifest.profiles, ["core-timeline", "agent-timeline"])
        XCTAssertEqual(package.manifest.capabilities, ["read_core", "write_core", "preserve_unknown_events"])
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "conversation_lifecycle",
            MSPAgentChatSession.modelContextSnapshotEventType,
            MSPAgentChatSession.modelContextItemEventType,
            MSPAgentChatSession.modelContextItemEventType
        ])
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2, 3, 4])

        assertValidPackage(at: packageURL)
    }

    func testSnapshotReplacementBecomesRestoreBoundaryForLaterContinuation() throws {
        let packageURL = try makeTemporaryPackageURL(named: "snapshot.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_snapshot",
            createdAt: "2026-07-02T01:05:00Z"
        )
        let originalUser = messageItem(role: "user", text: "第一轮")
        let originalAssistant = messageItem(role: "assistant", text: "第一轮回答")
        let compacted = messageItem(role: "user", text: "此前对话已压缩：用户要整理截图。")
        let continuation = messageItem(role: "assistant", text: "继续处理下一批。")

        try session.appendModelVisibleItems(
            [originalUser, originalAssistant],
            createdAt: "2026-07-02T01:05:01Z"
        )
        let snapshot = try session.replaceModelVisibleHistory(
            [compacted],
            reason: .compacted,
            createdAt: "2026-07-02T01:05:02Z"
        )
        try session.appendModelVisibleItems(
            [continuation],
            createdAt: "2026-07-02T01:05:03Z"
        )

        XCTAssertEqual(snapshot.payload["reason"]?.stringValue, "compacted")
        XCTAssertEqual(try session.modelVisibleHistory(), [compacted, continuation])
        assertValidPackage(at: packageURL)
    }

    func testMarksOpenTurnsAbortedWithoutTouchingClosedTurns() throws {
        let packageURL = try makeTemporaryPackageURL(named: "open-turn.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_open_turn",
            createdAt: "2026-07-02T01:10:00Z"
        )

        try session.appendTurnStarted(turnID: "turn-open", createdAt: "2026-07-02T01:10:01Z")
        try session.appendTurnStarted(turnID: "turn-closed", createdAt: "2026-07-02T01:10:02Z")
        try session.appendTurnCompleted(turnID: "turn-closed", createdAt: "2026-07-02T01:10:03Z")

        let aborted = try session.markOpenTurnsAborted(
            reason: "interrupted",
            createdAt: "2026-07-02T01:10:04Z"
        )

        XCTAssertEqual(aborted.count, 1)
        XCTAssertEqual(aborted.first?.turnID, "turn-open")
        XCTAssertEqual(aborted.first?.payload["reason"]?.stringValue, "interrupted")
        XCTAssertTrue(try session.markOpenTurnsAborted().isEmpty)

        let package = try session.packageSnapshot()
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "conversation_lifecycle",
            "turn_started",
            "turn_started",
            "turn_completed",
            "turn_aborted"
        ])
        assertValidPackage(at: packageURL)
    }

    func testApplicationStateSnapshotsRoundTripByType() throws {
        let packageURL = try makeTemporaryPackageURL(named: "application-state.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_application_state",
            createdAt: "2026-07-02T01:15:00Z"
        )

        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "items": .array([
                    .object([
                        "kind": .string("user"),
                        "body": .string("清理截图")
                    ])
                ])
            ]),
            createdAt: "2026-07-02T01:15:01Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "other.app.state",
            snapshot: .object(["ignored": .bool(true)]),
            createdAt: "2026-07-02T01:15:02Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "items": .array([
                    .object([
                        "kind": .string("assistantFinal"),
                        "body": .string("已完成")
                    ])
                ])
            ]),
            createdAt: "2026-07-02T01:15:03Z"
        )

        let snapshots = try session.applicationStateSnapshots(type: "photosorter.transcript.v1")
        XCTAssertEqual(snapshots.count, 2)
        let latest = try XCTUnwrap(
            session.latestApplicationStateSnapshot(type: "photosorter.transcript.v1")?.objectValue
        )
        XCTAssertEqual(
            latest["items"]?.arrayValue?.first?.objectValue?["body"]?.stringValue,
            "已完成"
        )

        let package = try session.packageSnapshot()
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "conversation_lifecycle",
            MSPAgentChatSession.applicationStateSnapshotEventType,
            MSPAgentChatSession.applicationStateSnapshotEventType,
            MSPAgentChatSession.applicationStateSnapshotEventType
        ])
        assertValidPackage(at: packageURL)
    }

    func testOpenPackageResultRestoresModelHistoryAndLatestApplicationSnapshotInOneCall() throws {
        let packageURL = try makeTemporaryPackageURL(named: "open-result.chat")
        let store = MSPAgentChatStore()
        let userItem = messageItem(role: "user", text: "整理截图")
        let assistantItem = messageItem(role: "assistant", text: "我先看缓存。")
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_open_result",
            createdAt: "2026-07-02T01:18:00Z",
            initialModelVisibleHistory: [userItem]
        )
        try session.appendModelVisibleItems(
            [assistantItem],
            createdAt: "2026-07-02T01:18:01Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "version": .number(1),
                "body": .string("旧快照")
            ]),
            createdAt: "2026-07-02T01:18:02Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "version": .number(2),
                "body": .string("最新快照")
            ]),
            createdAt: "2026-07-02T01:18:03Z"
        )

        let opened = try store.openPackage(
            at: packageURL,
            latestApplicationStateSnapshotType: "photosorter.transcript.v1"
        )

        XCTAssertEqual(opened.session.packageURL, packageURL.standardizedFileURL)
        XCTAssertEqual(opened.modelVisibleHistory, [userItem, assistantItem])
        let latest = try XCTUnwrap(opened.latestApplicationStateSnapshot?.objectValue)
        XCTAssertEqual(latest["body"]?.stringValue, "最新快照")
        XCTAssertEqual(latest["version"]?.intValue, 2)
        assertValidPackage(at: packageURL)
    }

    func testLatestStateIndexTracksCachedOpenState() throws {
        let packageURL = try makeTemporaryPackageURL(named: "latest-index.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_latest_index",
            createdAt: "2026-07-02T01:19:00Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendModelVisibleItems(
            [messageItem(role: "assistant", text: "继续")],
            createdAt: "2026-07-02T01:19:01Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "body": .string("旧 UI")
            ]),
            createdAt: "2026-07-02T01:19:02Z"
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object([
                "body": .string("最新 UI")
            ]),
            createdAt: "2026-07-02T01:19:03Z"
        )

        let index = try readLatestStateIndex(at: packageURL)
        XCTAssertEqual(index["index_kind"] as? String, "msp.agent.latest-state")
        let timeline = try XCTUnwrap(index["timeline"] as? [String: Any])
        XCTAssertEqual(timeline["next_seq"] as? Int, 6)
        let modelHistory = try XCTUnwrap(index["model_visible_history"] as? [[String: Any]])
        XCTAssertEqual(modelHistory.count, 2)
        let snapshots = try XCTUnwrap(index["latest_application_snapshots"] as? [String: Any])
        let photoSorterEntry = try XCTUnwrap(snapshots["photosorter.transcript.v1"] as? [String: Any])
        let snapshot = try XCTUnwrap(photoSorterEntry["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["body"] as? String, "最新 UI")

        let opened = try store.openPackage(
            at: packageURL,
            latestApplicationStateSnapshotType: "photosorter.transcript.v1"
        )
        XCTAssertEqual(opened.modelVisibleHistory.count, 2)
        XCTAssertEqual(opened.latestApplicationStateSnapshot?.objectValue?["body"]?.stringValue, "最新 UI")
        assertValidPackage(at: packageURL)
    }

    func testOpenPackageUsesFreshLatestStateIndexWithoutScanningTimeline() throws {
        let packageURL = try makeTemporaryPackageURL(named: "fresh-index-open.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_fresh_index_open",
            createdAt: "2026-07-02T01:19:05Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("缓存看起来有效")]),
            createdAt: "2026-07-02T01:19:06Z"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestStateIndexURL(for: packageURL).path))
        try duplicateSecondTimelineEventID(at: packageURL)

        let reopened = try store.openPackage(at: packageURL)
        XCTAssertEqual(try reopened.modelVisibleHistory().count, 1)

        let opened = try store.openPackage(
            at: packageURL,
            latestApplicationStateSnapshotType: "photosorter.transcript.v1"
        )
        XCTAssertEqual(opened.modelVisibleHistory.count, 1)
        XCTAssertEqual(opened.latestApplicationStateSnapshot?.objectValue?["body"]?.stringValue, "缓存看起来有效")

        let report = MSPChatValidator().validate(packageAt: packageURL)
        XCTAssertFalse(report.isValid, "test fixture should still contain a corrupt historical timeline")
    }

    func testSessionReadsUseFreshLatestStateIndexWithoutScanningTimeline() throws {
        let packageURL = try makeTemporaryPackageURL(named: "fresh-index-read.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_fresh_index_read",
            createdAt: "2026-07-02T01:19:07Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("缓存看起来有效")]),
            createdAt: "2026-07-02T01:19:08Z"
        )
        try duplicateSecondTimelineEventID(at: packageURL)

        XCTAssertEqual(try session.modelVisibleHistory().count, 1)
        XCTAssertEqual(
            try session.latestApplicationStateSnapshot(type: "photosorter.transcript.v1")?
                .objectValue?["body"]?.stringValue,
            "缓存看起来有效"
        )
    }

    func testAppendUsesFreshLatestStateIndexWithoutScanningTimeline() throws {
        let packageURL = try makeTemporaryPackageURL(named: "fresh-index-append.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_fresh_index_append",
            createdAt: "2026-07-02T01:19:09Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendModelVisibleItems(
            [messageItem(role: "assistant", text: "已有回复")],
            createdAt: "2026-07-02T01:19:10Z"
        )
        try duplicateSecondTimelineEventID(at: packageURL)

        try session.appendModelVisibleItems(
            [messageItem(role: "assistant", text: "继续写入")],
            createdAt: "2026-07-02T01:19:11Z"
        )

        XCTAssertEqual(try session.modelVisibleHistory().count, 3)
        let index = try readLatestStateIndex(at: packageURL)
        let timeline = try XCTUnwrap(index["timeline"] as? [String: Any])
        XCTAssertEqual(timeline["next_seq"] as? Int, 5)
    }

    func testOpenPackageRebuildsMissingLatestStateIndexAndDetectsTimelineCorruption() throws {
        let packageURL = try makeTemporaryPackageURL(named: "missing-index-corrupt-open.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_missing_index_corrupt_open",
            createdAt: "2026-07-02T01:19:12Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("缓存看起来有效")]),
            createdAt: "2026-07-02T01:19:13Z"
        )
        try FileManager.default.removeItem(at: latestStateIndexURL(for: packageURL))
        try duplicateSecondTimelineEventID(at: packageURL)

        XCTAssertThrowsError(try store.openPackage(at: packageURL)) { error in
            assertDuplicateTimelineEventError(error)
        }
        XCTAssertThrowsError(
            try store.openPackage(
                at: packageURL,
                latestApplicationStateSnapshotType: "photosorter.transcript.v1"
            )
        ) { error in
            assertDuplicateTimelineEventError(error)
        }
    }

    func testSessionReadsRebuildMissingLatestStateIndexAndDetectTimelineCorruption() throws {
        let packageURL = try makeTemporaryPackageURL(named: "missing-index-corrupt-read.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_missing_index_corrupt_read",
            createdAt: "2026-07-02T01:19:14Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("缓存看起来有效")]),
            createdAt: "2026-07-02T01:19:15Z"
        )
        try FileManager.default.removeItem(at: latestStateIndexURL(for: packageURL))
        try duplicateSecondTimelineEventID(at: packageURL)

        XCTAssertThrowsError(try session.modelVisibleHistory()) { error in
            assertDuplicateTimelineEventError(error)
        }
        XCTAssertThrowsError(
            try session.latestApplicationStateSnapshot(type: "photosorter.transcript.v1")
        ) { error in
            assertDuplicateTimelineEventError(error)
        }
    }

    func testAppendRebuildsMissingLatestStateIndexAndDetectsTimelineCorruption() throws {
        let packageURL = try makeTemporaryPackageURL(named: "missing-index-corrupt-append.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_missing_index_corrupt_append",
            createdAt: "2026-07-02T01:19:16Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendModelVisibleItems(
            [messageItem(role: "assistant", text: "已有回复")],
            createdAt: "2026-07-02T01:19:17Z"
        )
        try FileManager.default.removeItem(at: latestStateIndexURL(for: packageURL))
        try duplicateSecondTimelineEventID(at: packageURL)
        let timelineBeforeAppend = try Data(contentsOf: timelineURL(for: packageURL))

        XCTAssertThrowsError(
            try session.appendModelVisibleItems(
                [messageItem(role: "assistant", text: "不应写入")],
                createdAt: "2026-07-02T01:19:18Z"
            )
        ) { error in
            assertDuplicateTimelineEventError(error)
        }
        XCTAssertEqual(try Data(contentsOf: timelineURL(for: packageURL)), timelineBeforeAppend)
    }

    func testOpenPackageRebuildsMissingLatestStateIndexForLegacyPackages() throws {
        let packageURL = try makeTemporaryPackageURL(named: "legacy-no-index.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_legacy_no_index",
            createdAt: "2026-07-02T01:19:10Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "开始")]
        )
        try session.appendApplicationStateSnapshot(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("可恢复 UI")]),
            createdAt: "2026-07-02T01:19:11Z"
        )
        try FileManager.default.removeItem(at: latestStateIndexURL(for: packageURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latestStateIndexURL(for: packageURL).path))

        let opened = try store.openPackage(
            at: packageURL,
            latestApplicationStateSnapshotType: "photosorter.transcript.v1"
        )

        XCTAssertEqual(opened.modelVisibleHistory.count, 1)
        XCTAssertEqual(opened.latestApplicationStateSnapshot?.objectValue?["body"]?.stringValue, "可恢复 UI")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestStateIndexURL(for: packageURL).path))
        assertValidPackage(at: packageURL)
    }

    func testConcurrentSessionWritesKeepTimelineSequenceStrictlyIncreasing() throws {
        let packageURL = try makeTemporaryPackageURL(named: "concurrent-writes.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_concurrent_writes",
            createdAt: "2026-07-02T01:20:00Z"
        )
        let iterations = 80
        let errorsLock = NSLock()
        var errors: [String] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                let timestamp = String(format: "2026-07-02T01:20:00.%03dZ", index)
                switch index % 4 {
                case 0:
                    try session.appendApplicationStateSnapshot(
                        type: "photosorter.transcript.v1",
                        snapshot: .object([
                            "index": .number(Double(index)),
                            "body": .string("snapshot-\(index)")
                        ]),
                        createdAt: timestamp
                    )
                case 1:
                    try session.appendModelVisibleItems(
                        [messageItem(role: "assistant", text: "item-\(index)")],
                        createdAt: timestamp,
                        turnID: "turn-\(index)"
                    )
                case 2:
                    try session.replaceModelVisibleHistory(
                        [messageItem(role: "user", text: "history-\(index)")],
                        reason: .replaced,
                        createdAt: timestamp
                    )
                default:
                    let turnID = "turn-\(index)"
                    try session.appendTurnStarted(turnID: turnID, createdAt: timestamp)
                    try session.appendTurnCompleted(turnID: turnID, createdAt: timestamp)
                }
            } catch {
                errorsLock.lock()
                errors.append(String(describing: error))
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        let package = try session.packageSnapshot()
        XCTAssertEqual(package.timelineEvents.map(\.seq), Array(1...package.timelineEvents.count))
        XCTAssertEqual(package.timelineEvents.count, 101)
        assertValidPackage(at: packageURL)
    }

    func testTitleMetadataRoundTripsAndPreservesManifestExtensionsWithoutTimelineWrites() throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-round-trip.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_round_trip",
            createdAt: "2026-07-11T10:00:00Z"
        )
        try addManifestExtension(at: packageURL)
        let timelineBefore = try Data(contentsOf: timelineURL(for: packageURL))
        let pathBefore = session.packageURL
        let updatedAt = try XCTUnwrap(iso8601Date("2026-07-11T10:00:01Z"))

        let result = try session.setTitle(
            "  复刻 Codex 自动标题  ",
            searchDescription: "  为 MSP 提供可搜索的 Chat 标题摘要  ",
            source: .model,
            condition: .onlyIfUntitled,
            updatedAt: updatedAt
        )

        XCTAssertTrue(result.didUpdate)
        XCTAssertEqual(result.disposition, .updated)
        XCTAssertEqual(result.metadata.title, "复刻 Codex 自动标题")
        XCTAssertEqual(result.metadata.searchDescription, "为 MSP 提供可搜索的 Chat 标题摘要")
        XCTAssertEqual(result.metadata.revision, "1")
        XCTAssertEqual(result.metadata.record?.source, .model)
        XCTAssertEqual(result.metadata.record?.updatedAt, updatedAt)
        XCTAssertEqual(session.packageURL, pathBefore)
        XCTAssertEqual(try Data(contentsOf: timelineURL(for: packageURL)), timelineBefore)

        let manifest = try MSPChatCoreReader().readManifest(at: packageURL)
        XCTAssertEqual(manifest.title, "复刻 Codex 自动标题")
        XCTAssertEqual(manifest.searchDescription, "为 MSP 提供可搜索的 Chat 标题摘要")
        XCTAssertEqual(manifest.titleRevision, 1)
        XCTAssertEqual(manifest.titleSource, "model")
        XCTAssertEqual(manifest.rawJSON["x-store-test"]?.objectValue?["preserved"], .bool(true))
        XCTAssertEqual(
            manifest.rawJSON["timeline"]?.objectValue?["x-timeline-metadata"],
            .string("preserved")
        )

        let reopened = try store.openPackage(at: packageURL)
        XCTAssertEqual(try reopened.titleMetadata(), result.metadata)
        assertValidPackage(at: packageURL)
    }

    func testManualTitleWinsOverLateAutomaticWriteAndRevisionIsCompareAndSet() throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-manual-wins.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_manual_wins",
            createdAt: "2026-07-11T10:01:00Z"
        )
        let modelDate = try XCTUnwrap(iso8601Date("2026-07-11T10:01:01Z"))
        let manualDate = try XCTUnwrap(iso8601Date("2026-07-11T10:01:02Z"))

        let generated = try session.setTitle(
            "自动标题",
            searchDescription: "自动摘要",
            source: .model,
            condition: .onlyIfUntitled,
            updatedAt: modelDate
        )
        let generatedRevision = try XCTUnwrap(generated.metadata.revision)
        let manual = try session.setTitle(
            "开发者手动标题",
            searchDescription: nil,
            source: .manual,
            condition: .always,
            updatedAt: manualDate
        )

        let lateGenerated = try session.setTitle(
            "迟到的自动标题",
            searchDescription: "不应写入",
            source: .model,
            condition: .onlyIfUntitled,
            updatedAt: manualDate.addingTimeInterval(1)
        )
        let staleRevisionWrite = try session.setTitle(
            "使用旧 revision 的标题",
            source: .fallback,
            condition: .ifRevision(generatedRevision),
            updatedAt: manualDate.addingTimeInterval(2)
        )

        XCTAssertTrue(generated.didUpdate)
        XCTAssertTrue(manual.didUpdate)
        XCTAssertEqual(manual.metadata.revision, "2")
        XCTAssertFalse(lateGenerated.didUpdate)
        XCTAssertFalse(staleRevisionWrite.didUpdate)
        XCTAssertEqual(lateGenerated.metadata, manual.metadata)
        XCTAssertEqual(staleRevisionWrite.metadata, manual.metadata)
        XCTAssertEqual(try session.titleMetadata().title, "开发者手动标题")
        XCTAssertNil(try session.titleMetadata().searchDescription)

        let currentRevision = try XCTUnwrap(manual.metadata.revision)
        let compareAndSet = try session.setTitle(
            "条件更新后的标题",
            searchDescription: "新的摘要",
            source: .inherited,
            condition: .ifRevision(currentRevision),
            updatedAt: manualDate.addingTimeInterval(3)
        )
        XCTAssertTrue(compareAndSet.didUpdate)
        XCTAssertEqual(compareAndSet.metadata.revision, "3")
        XCTAssertEqual(compareAndSet.metadata.title, "条件更新后的标题")
        XCTAssertEqual(compareAndSet.metadata.record?.source, .inherited)
    }

    func testConcurrentOnlyIfUntitledWritesCommitExactlyOneTitle() throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-concurrent.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_concurrent",
            createdAt: "2026-07-11T10:02:00Z"
        )
        let timelineBefore = try Data(contentsOf: timelineURL(for: packageURL))
        let resultLock = NSLock()
        var results: [MSPChatTitleWriteResult] = []
        var errors: [String] = []

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            do {
                let result = try session.setTitle(
                    "自动标题 \(index)",
                    searchDescription: "候选摘要 \(index)",
                    source: .model,
                    condition: .onlyIfUntitled,
                    updatedAt: Date(timeIntervalSince1970: 1_783_765_400 + Double(index))
                )
                resultLock.lock()
                results.append(result)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                errors.append(String(describing: error))
                resultLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(results.count, 64)
        XCTAssertEqual(results.filter(\.didUpdate).count, 1)
        XCTAssertEqual(Set(results.compactMap(\.metadata.title)).count, 1)
        XCTAssertEqual(try session.titleMetadata().revision, "1")
        XCTAssertEqual(try Data(contentsOf: timelineURL(for: packageURL)), timelineBefore)
        assertValidPackage(at: packageURL)
    }

    func testSessionImplementsAsyncTitlePersistenceContract() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-persistence-contract.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_protocol",
            createdAt: "2026-07-11T10:03:00Z"
        )
        let persistence: any MSPChatTitlePersisting = session
        let updatedAt = try XCTUnwrap(iso8601Date("2026-07-11T10:03:01Z"))
        let write = try await persistence.writeTitle(
            MSPChatTitleRecord(
                chatID: "chatpkg_agent_store_title_protocol",
                title: "异步持久化标题",
                searchDescription: "协议接入测试",
                source: .model,
                updatedAt: updatedAt
            ),
            condition: .onlyIfUntitled
        )
        let loaded = try await persistence.titleMetadata(
            for: "chatpkg_agent_store_title_protocol"
        )

        XCTAssertTrue(write.didUpdate)
        XCTAssertEqual(loaded, write.metadata)
    }

    func testChatNamingIntegrationWiresGeneratorToPersistedSession() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-integration.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_integration",
            createdAt: "2026-07-11T10:04:00Z"
        )
        let integration = try session.makeChatNamingIntegration(
            titleGenerator: MSPAgentChatStoreTestTitleGenerator()
        )

        let outcome = try await integration.generateTitleIfNeeded(
            input: MSPChatNamingInput(text: "给 MSP 增加自动标题 SDK"),
            source: .initialUserInput
        )

        XCTAssertEqual(integration.chatID, "chatpkg_agent_store_title_integration")
        XCTAssertEqual(outcome.metadata.title, "增加 ChatNaming SDK")
        XCTAssertEqual(outcome.metadata.searchDescription, "MSP 自动标题开发者接入")
        XCTAssertEqual(try session.titleMetadata(), outcome.metadata)
    }

    func testChatNamingIntegrationAutomaticallyBackfillsHistoricalUntitledChat() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-backfill.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_backfill",
            createdAt: "2026-07-11T10:05:00Z",
            initialModelVisibleHistory: [
                messageItem(
                    role: "user",
                    text: "prefix\n## My request for Codex: 补全历史标题"
                )
            ]
        )
        let generator = MSPAgentChatStoreRecordingTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "补全历史标题")
        )
        let updated = expectation(description: "Historical title updated")

        _ = try session.makeChatNamingIntegration(
            titleGenerator: generator,
            onEvent: { event in
                if case .titleUpdated = event {
                    updated.fulfill()
                }
            }
        )
        await fulfillment(of: [updated], timeout: 2)

        let metadata = try session.titleMetadata()
        let requests = await generator.snapshot()
        XCTAssertEqual(metadata.title, "补全历史标题")
        XCTAssertEqual(requests.map(\.prompt), ["补全历史标题"])
        XCTAssertEqual(requests.map(\.source), [.historicalBackfill])
    }

    func testHistoricalBackfillUsesFirstCanonicalUserMessageAfterCompaction() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-backfill-compacted.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_backfill_compacted",
            createdAt: "2026-07-11T10:05:30Z",
            initialModelVisibleHistory: [
                messageItem(
                    role: "user",
                    text: "## My request for Codex: 最初的持久化请求"
                ),
                messageItem(role: "assistant", text: "处理中")
            ]
        )
        _ = try session.replaceModelVisibleHistory([
            messageItem(role: "assistant", text: "压缩摘要"),
            messageItem(role: "user", text: "压缩后的后续问题")
        ])
        let generator = MSPAgentChatStoreRecordingTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "最初请求标题")
        )
        let updated = expectation(description: "Compacted history title updated")

        _ = try session.makeChatNamingIntegration(
            titleGenerator: generator,
            onEvent: { event in
                if case .titleUpdated = event {
                    updated.fulfill()
                }
            }
        )
        await fulfillment(of: [updated], timeout: 2)

        let requests = await generator.snapshot()
        XCTAssertEqual(requests.map(\.prompt), ["最初的持久化请求"])
        XCTAssertEqual(try session.titleMetadata().title, "最初请求标题")
    }

    func testHistoricalBackfillUsesEarlierGoalWhenNoUserPreviewExistsYet() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-backfill-goal.chat")
        let createdAt = "2026-07-11T10:05:35Z"
        try MSPChatCoreWriter().createMinimalPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_backfill_goal",
            createdAt: createdAt,
            initialEvents: [
                MSPChatTimelineEvent(
                    id: "conversation-created",
                    type: "conversation_lifecycle",
                    seq: 1,
                    createdAt: createdAt,
                    payload: ["operation": .string("create")]
                ),
                MSPChatTimelineEvent(
                    id: "goal-created",
                    type: MSPGoalChatMapping.threadGoalUpdatedTimelineType,
                    seq: 2,
                    createdAt: createdAt,
                    payload: ["objective": .string("先完成 ChatNaming SDK")]
                ),
                MSPChatTimelineEvent.message(
                    id: "later-user-message",
                    seq: 3,
                    createdAt: createdAt,
                    role: "user",
                    content: "稍后的用户消息"
                )
            ],
            profiles: ["core-timeline", "agent-timeline"],
            capabilities: [
                "read_core",
                "write_core",
                "preserve_unknown_events"
            ]
        )
        let session = MSPAgentChatSession(packageURL: packageURL)
        let generator = MSPAgentChatStoreRecordingTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "ChatNaming SDK")
        )
        let updated = expectation(description: "Goal preview title updated")

        _ = try session.makeChatNamingIntegration(
            titleGenerator: generator,
            onEvent: { event in
                if case .titleUpdated = event {
                    updated.fulfill()
                }
            }
        )
        await fulfillment(of: [updated], timeout: 2)

        let requests = await generator.snapshot()
        XCTAssertEqual(requests.map(\.prompt), ["先完成 ChatNaming SDK"])
        XCTAssertEqual(requests.map(\.source), [.historicalBackfill])
    }

    func testHistoricalBackfillOwnsInitialNamingWhenChatImmediatelySends() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-backfill-send-race.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_backfill_send_race",
            createdAt: "2026-07-11T10:05:40Z",
            initialModelVisibleHistory: [
                messageItem(role: "user", text: "历史首条请求")
            ]
        )
        let generator = MSPAgentChatStoreRecordingTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "历史标题")
        )
        let updated = expectation(description: "Historical race title updated")
        let integration = try session.makeChatNamingIntegration(
            titleGenerator: generator,
            onEvent: { event in
                if case .titleUpdated = event {
                    updated.fulfill()
                }
            }
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPAgentChatStoreTestModelClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                compactionPolicy: .disabled
            ),
            chatNaming: integration
        )

        _ = try await conversation.send("刚发送的后续问题")
        await fulfillment(of: [updated], timeout: 2)

        let requests = await generator.snapshot()
        XCTAssertEqual(requests.map(\.prompt), ["历史首条请求"])
        XCTAssertEqual(requests.map(\.source), [.historicalBackfill])
    }

    func testBoundDescriptionRefreshUsesRecentPersistedUserContextFirst() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-current-context.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_current_context",
            createdAt: "2026-07-11T10:05:50Z",
            initialModelVisibleHistory: [
                messageItem(role: "user", text: "旧目的 Alpha"),
                messageItem(role: "assistant", text: "旧回复"),
                messageItem(role: "user", text: "最新目的 Beta")
            ]
        )
        _ = try session.setTitle("手动标题", source: .manual)
        let generator = MSPAgentChatStoreRecordingCombinedGenerator()
        let integration = try session.makeChatNamingIntegration(
            titleGenerator: generator,
            searchDescriptionGenerator: generator
        )

        let refreshed = try await integration.refreshSearchDescription()

        XCTAssertEqual(refreshed.metadata.searchDescription, "最新目的 Beta Alpha")
        let requests = await generator.descriptionSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].prompt, "最新目的 Beta\n\n旧目的 Alpha")
        XCTAssertTrue(requests[0].instructions.contains("most recent active purpose"))
    }

    func testDerivedChatNamingIntegrationInheritsBeforeReturning() async throws {
        let parentURL = try makeTemporaryPackageURL(named: "title-parent.chat")
        let childURL = try makeTemporaryPackageURL(named: "title-child.chat")
        let store = MSPAgentChatStore()
        let parent = try store.createPackage(
            at: parentURL,
            packageID: "chatpkg_agent_store_title_parent",
            createdAt: "2026-07-11T10:06:00Z"
        )
        _ = try parent.setTitle(
            "父 Chat 标题",
            searchDescription: "父 Chat 搜索摘要",
            source: .manual
        )
        let child = try store.createPackage(
            at: childURL,
            packageID: "chatpkg_agent_store_title_child",
            createdAt: "2026-07-11T10:06:01Z",
            initialModelVisibleHistory: [messageItem(role: "user", text: "fork preview")]
        )
        let generator = MSPAgentChatStoreRecordingTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "Should not run")
        )

        let integration = try await child.makeDerivedChatNamingIntegration(
            inheritingTitleFrom: parent,
            titleGenerator: generator
        )

        let metadata = try child.titleMetadata()
        let requests = await generator.snapshot()
        XCTAssertEqual(integration.chatID, "chatpkg_agent_store_title_child")
        XCTAssertEqual(metadata.title, "父 Chat 标题")
        XCTAssertEqual(metadata.searchDescription, "父 Chat 搜索摘要")
        XCTAssertEqual(metadata.record?.source, .inherited)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRuntimeAcceptsChatNamingIntegrationAsOneValue() throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-runtime.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_runtime",
            createdAt: "2026-07-11T10:07:00Z"
        )
        let integration = try session.makeChatNamingIntegration(
            titleGenerator: MSPAgentChatStoreTestTitleGenerator()
        )
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in MSPAgentChatStoreTestModelClient() },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            })
        )

        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(
                model: "main-model",
                compactionPolicy: .disabled
            ),
            chatNaming: integration
        )

        XCTAssertEqual(conversation.chatID, integration.chatID)
    }

    func testTitlePersistenceContractRejectsManifestWithoutPackageID() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "title-missing-package-id.chat")
        let session = try MSPAgentChatStore().createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_title_missing_package_id",
            createdAt: "2026-07-11T10:04:00Z"
        )
        try removePackageIDFromManifest(at: packageURL)
        let persistence: any MSPChatTitlePersisting = session

        do {
            _ = try await persistence.titleMetadata(
                for: "chatpkg_agent_store_title_missing_package_id"
            )
            XCTFail("Expected title metadata read to reject a manifest without package_id.")
        } catch {
            XCTAssertEqual(error as? MSPAgentChatStoreError, .missingPackageID)
        }

        do {
            _ = try await persistence.writeTitle(
                MSPChatTitleRecord(
                    chatID: "chatpkg_agent_store_title_missing_package_id",
                    title: "不应写入",
                    source: .model,
                    updatedAt: Date()
                ),
                condition: .onlyIfUntitled
            )
            XCTFail("Expected title write to reject a manifest without package_id.")
        } catch {
            XCTAssertEqual(error as? MSPAgentChatStoreError, .missingPackageID)
        }
    }

    func testAsyncSessionWritesPreserveSubmissionOrder() async throws {
        let packageURL = try makeTemporaryPackageURL(named: "async-writes.chat")
        let store = MSPAgentChatStore()
        let session = try store.createPackage(
            at: packageURL,
            packageID: "chatpkg_agent_store_async_writes",
            createdAt: "2026-07-02T01:25:00Z"
        )

        try await session.appendTurnStartedAsync(
            turnID: "turn-async",
            createdAt: "2026-07-02T01:25:01Z"
        )
        try await session.appendModelVisibleItemsAsync(
            [messageItem(role: "user", text: "第一条")],
            createdAt: "2026-07-02T01:25:02Z",
            turnID: "turn-async"
        )
        try await session.appendApplicationStateSnapshotAsync(
            type: "photosorter.transcript.v1",
            snapshot: .object(["body": .string("快照")]),
            createdAt: "2026-07-02T01:25:03Z"
        )
        try await session.appendTurnCompletedAsync(
            turnID: "turn-async",
            createdAt: "2026-07-02T01:25:04Z"
        )

        let package = try session.packageSnapshot()
        XCTAssertEqual(package.manifest.timelineNextSeq, 6)
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "conversation_lifecycle",
            "turn_started",
            MSPAgentChatSession.modelContextItemEventType,
            MSPAgentChatSession.applicationStateSnapshotEventType,
            "turn_completed"
        ])
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2, 3, 4, 5])
        assertValidPackage(at: packageURL)
    }

    private func messageItem(role: String, text: String) -> MSPAgentJSONValue {
        .object([
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(role == "user" ? "input_text" : "output_text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private func assertValidPackage(at packageURL: URL) {
        let report = MSPChatValidator().validate(packageAt: packageURL)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    private func latestStateIndexURL(for packageURL: URL) -> URL {
        packageURL
            .appendingPathComponent("indexes", isDirectory: true)
            .appendingPathComponent("latest-agent-state.json")
    }

    private func timelineURL(for packageURL: URL) -> URL {
        packageURL.appendingPathComponent(MSPChat.defaultTimelinePath)
    }

    private func readLatestStateIndex(at packageURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: latestStateIndexURL(for: packageURL))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func addManifestExtension(at packageURL: URL) throws {
        let url = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["x-store-test"] = ["preserved": true]
        var timeline = try XCTUnwrap(object["timeline"] as? [String: Any])
        timeline["x-timeline-metadata"] = "preserved"
        object["timeline"] = timeline
        let updated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: url, options: .atomic)
    }

    private func removePackageIDFromManifest(at packageURL: URL) throws {
        let url = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["package_id"] = nil
        let updated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: url, options: .atomic)
    }

    private func iso8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func duplicateSecondTimelineEventID(at packageURL: URL) throws {
        let url = timelineURL(for: packageURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        guard lines.count >= 2 else {
            return
        }

        let firstData = try XCTUnwrap(lines[0].data(using: .utf8))
        let secondData = try XCTUnwrap(lines[1].data(using: .utf8))
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        var secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        secondObject["id"] = firstObject["id"]
        let rewrittenSecond = try JSONSerialization.data(
            withJSONObject: secondObject,
            options: [.sortedKeys]
        )
        lines[1] = String(decoding: rewrittenSecond, as: UTF8.self)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertDuplicateTimelineEventError(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            error.localizedDescription.contains("duplicate event id"),
            "unexpected error: \(error)",
            file: file,
            line: line
        )
    }

    private func makeTemporaryPackageURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPAgentChatStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }
}

private struct MSPAgentChatStoreTestTitleGenerator: MSPChatTitleGenerating {
    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        MSPChatTitleSuggestion(
            title: "增加 ChatNaming SDK",
            searchDescription: "MSP 自动标题开发者接入"
        )
    }
}

private actor MSPAgentChatStoreRecordingTitleGenerator: MSPChatTitleGenerating {
    private var requests: [MSPChatTitleGenerationRequest] = []
    private let suggestion: MSPChatTitleSuggestion

    init(suggestion: MSPChatTitleSuggestion) {
        self.suggestion = suggestion
    }

    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        requests.append(request)
        return suggestion
    }

    func snapshot() -> [MSPChatTitleGenerationRequest] {
        requests
    }
}

private actor MSPAgentChatStoreRecordingCombinedGenerator:
    MSPChatTitleGenerating,
    MSPChatSearchDescriptionGenerating
{
    private var descriptionRequests:
        [MSPChatSearchDescriptionGenerationRequest] = []

    func generateTitle(
        request: MSPChatTitleGenerationRequest
    ) async throws -> MSPChatTitleSuggestion {
        MSPChatTitleSuggestion(
            title: "Generated title",
            searchDescription: "Generated description"
        )
    }

    func generateSearchDescription(
        request: MSPChatSearchDescriptionGenerationRequest
    ) async throws -> String? {
        descriptionRequests.append(request)
        return "最新目的 Beta Alpha"
    }

    func descriptionSnapshot() -> [MSPChatSearchDescriptionGenerationRequest] {
        descriptionRequests
    }
}

private struct MSPAgentChatStoreTestModelClient: MSPAgentModelTurnClient {
    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        MSPAgentModelTurnOutput(finalAnswer: "ok")
    }
}

import XCTest
@testable import MSPChat

final class MSPChatTests: XCTestCase {
    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(MSPChat.schemaVersion, 0)
    }

    func testPackageManifestsDeclareMSPChatOwnerSourceFiles() throws {
        let root = repositoryRoot()
        let rootManifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let implementationManifest = try String(
            contentsOf: root.appendingPathComponent("Implementations/Swift/Package.swift"),
            encoding: .utf8
        )
        let requiredSources = [
            "MSPChat.swift",
            "MSPChatError.swift",
            "JSON/MSPChatJSONIO.swift",
            "JSON/MSPChatJSONValue.swift",
            "Manifest/MSPChatManifest.swift",
            "Package/MSPChatCoreReader.swift",
            "Package/MSPChatCoreWriter.swift",
            "Package/MSPChatPackage.swift",
            "Timeline/MSPChatTimelineEvent.swift",
            "Timeline/MSPChatTimelineRecords.swift",
            "MSPChatValidator.swift"
        ]

        for source in requiredSources {
            XCTAssertTrue(rootManifest.contains("\"\(source)\""), "Root manifest should include \(source).")
            XCTAssertTrue(implementationManifest.contains("\"\(source)\""), "Implementation manifest should include \(source).")
        }

        let facadeSource = try String(
            contentsOf: root.appendingPathComponent("Implementations/Swift/Sources/MSPChat/MSPChat.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(facadeSource.contains("MSPChatJSONValue"))
        XCTAssertFalse(facadeSource.contains("MSPChatManifest"))
        XCTAssertFalse(facadeSource.contains("MSPChatTimelineEvent"))
        XCTAssertFalse(facadeSource.contains("MSPChatCoreReader"))
        XCTAssertFalse(facadeSource.contains("MSPChatCoreWriter"))
    }

    func testCoreReaderReadsMinimalPureChatPackage() throws {
        let package = try MSPChatCoreReader().readPackage(at: samplesRoot().appendingPathComponent("good/pure-chat.chat"))

        XCTAssertEqual(package.manifest.format, "msp.chat")
        XCTAssertEqual(package.manifest.packageID, "chatpkg_good_pure_chat")
        XCTAssertEqual(package.manifest.profiles, ["core-timeline"])
        XCTAssertEqual(package.manifest.capabilities, ["read_core"])
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2])
        XCTAssertEqual(package.timelineEvents.first?.payload["role"]?.stringValue, "user")
        XCTAssertEqual(package.timelineEvents.first?.payload["content"]?.stringValue, "Explain what this conversation is for.")
        XCTAssertEqual(package.nextSeq, 3)
    }

    func testCoreReaderPreservesInterleavedTimelineOrder() throws {
        let package = try MSPChatCoreReader().readPackage(at: samplesRoot().appendingPathComponent("good/interleaved-command.chat"))

        XCTAssertEqual(
            package.timelineEvents.map(\.type),
            [
                "turn_started",
                "message",
                "message",
                "command_call",
                "command_stage_started",
                "command_output",
                "message",
                "command_output",
                "command_stage_completed",
                "command_complete",
                "artifact_ref",
                "message",
                "turn_completed"
            ]
        )
        XCTAssertEqual(package.timelineEvents[5].payload["stream"]?.stringValue, "stdout")
        XCTAssertEqual(package.timelineEvents[6].payload["phase"]?.stringValue, "intermediate")
        XCTAssertEqual(package.timelineEvents[7].payload["stream"]?.stringValue, "stderr")
    }

    func testCoreReaderPreservesUnknownEventShape() throws {
        let package = try MSPChatCoreReader().readPackage(at: samplesRoot().appendingPathComponent("good/unknown-preserved.chat"))
        let unknown = try XCTUnwrap(package.timelineEvents.first { $0.type == "x-example-extension" })
        let extensionPayload = try XCTUnwrap(unknown.payload["x-example"]?.objectValue)

        XCTAssertEqual(extensionPayload["meaning"]?.stringValue, "unknown data preserved by capability claim")
        XCTAssertEqual(unknown.rawJSON["type"]?.stringValue, "x-example-extension")
    }

    func testCoreWriterCreatesPackageThatPassesValidator() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "created.chat")
        let writer = MSPChatCoreWriter()
        let events = [
            MSPChatTimelineEvent.message(
                id: "evt_created_001",
                seq: 1,
                createdAt: "2026-06-30T01:00:00Z",
                role: "user",
                content: "Create a minimal package."
            ),
            MSPChatTimelineEvent.message(
                id: "evt_created_002",
                seq: 2,
                createdAt: "2026-06-30T01:00:01Z",
                role: "assistant",
                content: "The package was written with only core capabilities.",
                phase: "final"
            )
        ]

        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_created",
            createdAt: "2026-06-30T01:00:00Z",
            initialEvents: events
        )

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.manifest.capabilities, ["read_core", "write_core"])
        XCTAssertEqual(package.manifest.timelineNextSeq, 3)
        XCTAssertFalse(package.manifest.capabilities.contains("execute_msp_commands"))
        XCTAssertEqual(package.timelineEvents.map(\.id), ["evt_created_001", "evt_created_002"])

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterAppendEventsAdvancesManifestNextSeqWithoutFullPackageRewrite() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "append-state.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_append_state",
            createdAt: "2026-06-30T01:04:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_append_state_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:04:00Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )

        var appendState = try writer.appendState(at: temporaryPackage)
        XCTAssertEqual(appendState.nextSeq, 2)
        try writer.appendEvents(
            [
                MSPChatTimelineEvent.message(
                    id: "evt_append_state_002",
                    seq: appendState.nextSeq,
                    createdAt: "2026-06-30T01:04:01Z",
                    role: "assistant",
                    content: "Done.",
                    phase: "final"
                )
            ],
            to: temporaryPackage,
            state: &appendState,
            updatedAt: "2026-06-30T01:04:01Z"
        )

        XCTAssertEqual(appendState.nextSeq, 3)
        XCTAssertEqual(try writer.appendState(at: temporaryPackage).nextSeq, 3)
        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.manifest.timelineNextSeq, 3)
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2])

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterAppendStateUsesValidatedTimelineWhenManifestNextSeqIsStale() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "stale-manifest-next-seq.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_stale_manifest_next_seq",
            createdAt: "2026-06-30T01:04:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_stale_manifest_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:04:00Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )
        try appendRawEvent(
            MSPChatTimelineEvent.message(
                id: "evt_stale_manifest_002",
                seq: 2,
                createdAt: "2026-06-30T01:04:01Z",
                role: "assistant",
                content: "Written before manifest recovery."
            ),
            to: temporaryPackage
        )

        XCTAssertEqual(try writer.appendState(at: temporaryPackage).nextSeq, 3)
        let appended = try writer.appendMessage(
            to: temporaryPackage,
            id: "evt_stale_manifest_003",
            role: "assistant",
            content: "Recovered append.",
            phase: "final",
            createdAt: "2026-06-30T01:04:02Z"
        )

        XCTAssertEqual(appended.seq, 3)
        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.manifest.timelineNextSeq, 4)
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2, 3])
    }

    func testCoreWriterAppendStateRejectsCorruptTimelineWhenManifestNextSeqIsMissing() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "corrupt-no-next-seq.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_corrupt_no_next_seq",
            createdAt: "2026-06-30T01:05:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_corrupt_no_next_seq_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:05:00Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )
        try removeManifestNextSeq(from: temporaryPackage)
        try appendRawEvent(
            MSPChatTimelineEvent.message(
                id: "evt_corrupt_no_next_seq_001",
                seq: 2,
                createdAt: "2026-06-30T01:05:01Z",
                role: "assistant",
                content: "Duplicate id."
            ),
            to: temporaryPackage
        )

        XCTAssertThrowsError(try writer.appendState(at: temporaryPackage)) { error in
            guard case let MSPChatError.invalidTimelineEvent(message) = error else {
                return XCTFail("Expected invalidTimelineEvent, got \(error).")
            }
            XCTAssertTrue(message.contains("duplicate event id"))
        }
    }

    func testCoreWriterRejectsAppendStateFromDifferentPackage() throws {
        let firstPackage = try makeTemporaryPackageURL(named: "append-state-first.chat")
        let secondPackage = try makeTemporaryPackageURL(named: "append-state-second.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: firstPackage,
            packageID: "chatpkg_test_append_state_first",
            createdAt: "2026-06-30T01:06:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_append_state_first_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:06:00Z",
                    role: "user",
                    content: "First."
                )
            ]
        )
        try writer.createMinimalPackage(
            at: secondPackage,
            packageID: "chatpkg_test_append_state_second",
            createdAt: "2026-06-30T01:06:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_append_state_second_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:06:00Z",
                    role: "user",
                    content: "Second."
                )
            ]
        )

        var appendState = try writer.appendState(at: firstPackage)
        XCTAssertThrowsError(
            try writer.appendEvents(
                [
                    MSPChatTimelineEvent.message(
                        id: "evt_append_state_second_002",
                        seq: appendState.nextSeq,
                        createdAt: "2026-06-30T01:06:01Z",
                        role: "assistant",
                        content: "Should not be written."
                    )
                ],
                to: secondPackage,
                state: &appendState,
                updatedAt: "2026-06-30T01:06:01Z"
            )
        ) { error in
            guard case let MSPChatError.invalidAppendState(message) = error else {
                return XCTFail("Expected invalidAppendState, got \(error).")
            }
            XCTAssertTrue(message.contains("does not match target package"))
        }

        let package = try MSPChatCoreReader().readPackage(at: secondPackage)
        XCTAssertEqual(package.manifest.packageID, "chatpkg_test_append_state_second")
        XCTAssertEqual(package.timelineEvents.map(\.id), ["evt_append_state_second_001"])
    }

    func testCoreWriterPreservesTurnAbortedTimelineEvent() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "turn-aborted.chat")
        let writer = MSPChatCoreWriter()
        let events = [
            MSPChatTimelineEvent(
                id: "evt_turn_started",
                type: "turn_started",
                seq: 1,
                createdAt: "2026-06-30T01:05:00Z",
                turnID: "turn-1",
                payload: ["turn_id": .string("turn-1")]
            ),
            MSPChatTimelineEvent.message(
                id: "evt_user",
                seq: 2,
                createdAt: "2026-06-30T01:05:01Z",
                role: "user",
                content: "Stop this turn.",
                turnID: "turn-1"
            ),
            MSPChatTimelineEvent(
                id: "evt_turn_aborted",
                type: "turn_aborted",
                seq: 3,
                createdAt: "2026-06-30T01:05:02Z",
                turnID: "turn-1",
                payload: [
                    "turn_id": .string("turn-1"),
                    "reason": .string("interrupted")
                ]
            )
        ]

        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_turn_aborted",
            createdAt: "2026-06-30T01:05:00Z",
            initialEvents: events
        )

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "turn_started",
            "message",
            "turn_aborted"
        ])
        XCTAssertEqual(package.timelineEvents.last?.payload["reason"]?.stringValue, "interrupted")

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterPreservesTurnSteeredTimelineEvent() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "turn-steered.chat")
        let writer = MSPChatCoreWriter()
        let events = [
            MSPChatTimelineEvent(
                id: "evt_turn_started",
                type: "turn_started",
                seq: 1,
                createdAt: "2026-06-30T01:06:00Z",
                turnID: "turn-1",
                payload: ["turn_id": .string("turn-1")]
            ),
            MSPChatTimelineEvent.message(
                id: "evt_user",
                seq: 2,
                createdAt: "2026-06-30T01:06:01Z",
                role: "user",
                content: "Start.",
                turnID: "turn-1"
            ),
            MSPChatTimelineEvent(
                id: "evt_turn_steered",
                type: "turn_steered",
                seq: 3,
                createdAt: "2026-06-30T01:06:02Z",
                turnID: "turn-1",
                payload: [
                    "turn_id": .string("turn-1"),
                    "sequence": .int(1),
                    "content": .string("Steer."),
                    "boundary": .string("model_input")
                ]
            ),
            MSPChatTimelineEvent.message(
                id: "evt_steer_user",
                seq: 4,
                createdAt: "2026-06-30T01:06:02Z",
                role: "user",
                content: "Steer.",
                turnID: "turn-1"
            )
        ]

        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_turn_steered",
            createdAt: "2026-06-30T01:06:00Z",
            initialEvents: events
        )

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "turn_started",
            "message",
            "turn_steered",
            "message"
        ])
        XCTAssertEqual(package.timelineEvents[2].payload["sequence"]?.intValue, 1)

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterPreservesGoalTimelineEvents() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "thread-goal.chat")
        let writer = MSPChatCoreWriter()
        let events = [
            MSPChatTimelineEvent(
                id: "evt_goal_updated",
                type: "thread_goal_updated",
                seq: 1,
                createdAt: "2026-06-30T01:07:00Z",
                payload: [
                    "thread_id": .string("thread-1"),
                    "goal_id": .string("goal-1"),
                    "objective": .string("ship Goal"),
                    "status": .string("active"),
                    "tokens_used": .int(0),
                    "time_used_seconds": .int(0)
                ]
            ),
            MSPChatTimelineEvent(
                id: "evt_goal_accounted",
                type: "thread_goal_accounted",
                seq: 2,
                createdAt: "2026-06-30T01:07:01Z",
                turnID: "turn-1",
                payload: [
                    "thread_id": .string("thread-1"),
                    "turn_id": .string("turn-1"),
                    "goal_id": .string("goal-1"),
                    "token_delta": .int(12),
                    "time_delta_seconds": .int(3),
                    "tokens_used": .int(12),
                    "time_used_seconds": .int(3),
                    "status": .string("active")
                ]
            ),
            MSPChatTimelineEvent(
                id: "evt_goal_cleared",
                type: "thread_goal_cleared",
                seq: 3,
                createdAt: "2026-06-30T01:07:02Z",
                payload: [
                    "thread_id": .string("thread-1"),
                    "goal_id": .string("goal-1"),
                    "cleared": .bool(true)
                ]
            )
        ]

        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_thread_goal",
            createdAt: "2026-06-30T01:07:00Z",
            initialEvents: events
        )

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "thread_goal_updated",
            "thread_goal_accounted",
            "thread_goal_cleared"
        ])
        XCTAssertEqual(package.timelineEvents[1].payload["token_delta"]?.intValue, 12)

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterPreservesPlanModeTimelineEvents() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "plan-mode.chat")
        let writer = MSPChatCoreWriter()
        let events = [
            MSPChatTimelineEvent(
                id: "evt_plan_proposed",
                type: "plan_mode_proposed",
                seq: 1,
                createdAt: "2026-06-30T01:08:00Z",
                turnID: "turn-plan",
                payload: [
                    "thread_id": .string("thread-1"),
                    "planning_turn_id": .string("turn-plan"),
                    "proposal_id": .string("proposal-1"),
                    "proposal_version": .int(1),
                    "content": .string("- Step"),
                    "source": .string("model")
                ]
            ),
            MSPChatTimelineEvent(
                id: "evt_plan_approved",
                type: "plan_mode_approved",
                seq: 2,
                createdAt: "2026-06-30T01:08:01Z",
                payload: [
                    "thread_id": .string("thread-1"),
                    "proposal_id": .string("proposal-1"),
                    "proposal_version": .int(1),
                    "decision": .string("approved"),
                    "source": .string("user")
                ]
            ),
            MSPChatTimelineEvent(
                id: "evt_plan_handoff",
                type: "plan_mode_handoff",
                seq: 3,
                createdAt: "2026-06-30T01:08:02Z",
                payload: [
                    "thread_id": .string("thread-1"),
                    "proposal_id": .string("proposal-1"),
                    "proposal_version": .int(1),
                    "implementation_prompt": .string("Implement the plan."),
                    "model_input_item_count": .int(2)
                ]
            )
        ]

        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_plan_mode",
            createdAt: "2026-06-30T01:08:00Z",
            initialEvents: events
        )

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.timelineEvents.map(\.type), [
            "plan_mode_proposed",
            "plan_mode_approved",
            "plan_mode_handoff"
        ])
        XCTAssertEqual(package.timelineEvents[0].payload["proposal_version"]?.intValue, 1)

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    func testCoreWriterAppendsMessageWithNextSeqAndUpdatesManifest() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "append.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_append",
            createdAt: "2026-06-30T01:10:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_append_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:10:00Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )

        let appended = try writer.appendMessage(
            to: temporaryPackage,
            id: "evt_append_002",
            role: "assistant",
            content: "Continued.",
            phase: "final",
            createdAt: "2026-06-30T01:10:01Z"
        )

        XCTAssertEqual(appended.seq, 2)

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.manifest.updatedAt, "2026-06-30T01:10:01Z")
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2])
        XCTAssertEqual(package.timelineEvents.last?.payload["content"]?.stringValue, "Continued.")

        let report = MSPChatValidator().validate(packageAt: temporaryPackage)
        XCTAssertTrue(report.isValid, report.renderedText())
    }

    private func samplesRoot() -> URL {
        repositoryRoot().appendingPathComponent("Spec/Chat/Samples")
    }

    private func repositoryRoot() -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("Implementations/Swift/Sources/MSPChat/MSPChat.swift")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        XCTFail("Could not locate repository root from \(#filePath)")
        return URL(fileURLWithPath: "/")
    }

    private func makeTemporaryPackageURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func appendRawEvent(_ event: MSPChatTimelineEvent, to packageURL: URL) throws {
        let timelineURL = packageURL.appendingPathComponent(MSPChat.defaultTimelinePath)
        let handle = try FileHandle(forWritingTo: timelineURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: event.jsonLineData())
    }

    private func removeManifestNextSeq(from packageURL: URL) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        var manifest = try MSPChatJSON.readObject(from: manifestURL)
        var timeline = manifest["timeline"]?.objectValue ?? [:]
        timeline["next_seq"] = nil
        manifest["timeline"] = .object(timeline)
        try MSPChatJSON.writeObject(manifest, to: manifestURL)
    }
}

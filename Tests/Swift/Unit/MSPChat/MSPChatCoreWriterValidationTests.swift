import XCTest
@testable import MSPChat

final class MSPChatCoreWriterValidationTests: XCTestCase {
    func testStatefulAppendRejectsSamePackageStaleAppendState() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "same-package-stale-state.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_same_package_stale_state",
            createdAt: "2026-06-30T01:05:00Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_same_package_stale_state_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:05:00Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )

        var staleState = try writer.appendState(at: temporaryPackage)
        _ = try writer.appendMessage(
            to: temporaryPackage,
            id: "evt_same_package_stale_state_002",
            role: "assistant",
            content: "Advanced by another append.",
            createdAt: "2026-06-30T01:05:01Z"
        )

        XCTAssertThrowsError(
            try writer.appendEvents(
                [
                    MSPChatTimelineEvent.message(
                        id: "evt_same_package_stale_state_003",
                        seq: staleState.nextSeq,
                        createdAt: "2026-06-30T01:05:02Z",
                        role: "assistant",
                        content: "Should not duplicate seq 2."
                    )
                ],
                to: temporaryPackage,
                state: &staleState,
                updatedAt: "2026-06-30T01:05:02Z"
            )
        ) { error in
            guard case let MSPChatError.invalidAppendState(message) = error else {
                return XCTFail("Expected invalidAppendState, got \(error).")
            }
            XCTAssertTrue(message.contains("is stale"), message)
        }

        let package = try MSPChatCoreReader().readPackage(at: temporaryPackage)
        XCTAssertEqual(package.timelineEvents.map(\.seq), [1, 2])
        XCTAssertEqual(try writer.appendState(at: temporaryPackage).nextSeq, 3)
    }

    func testAppendStateRejectsCorruptTimelineWhenManifestNextSeqIsPresent() throws {
        let temporaryPackage = try makeTemporaryPackageURL(named: "corrupt-with-next-seq.chat")
        let writer = MSPChatCoreWriter()
        try writer.createMinimalPackage(
            at: temporaryPackage,
            packageID: "chatpkg_test_corrupt_with_next_seq",
            createdAt: "2026-06-30T01:05:10Z",
            initialEvents: [
                MSPChatTimelineEvent.message(
                    id: "evt_corrupt_with_next_seq_001",
                    seq: 1,
                    createdAt: "2026-06-30T01:05:10Z",
                    role: "user",
                    content: "Start."
                )
            ]
        )
        try appendRawEvent(
            MSPChatTimelineEvent.message(
                id: "evt_corrupt_with_next_seq_001",
                seq: 2,
                createdAt: "2026-06-30T01:05:11Z",
                role: "assistant",
                content: "Duplicate id even though manifest next_seq is present."
            ),
            to: temporaryPackage
        )

        XCTAssertThrowsError(try writer.appendState(at: temporaryPackage)) { error in
            assertDuplicateEventError(error)
        }
        XCTAssertThrowsError(
            try writer.appendMessage(
                to: temporaryPackage,
                id: "evt_corrupt_with_next_seq_003",
                role: "assistant",
                content: "Should not append over a corrupt timeline.",
                createdAt: "2026-06-30T01:05:12Z"
            )
        ) { error in
            assertDuplicateEventError(error)
        }
    }

    private func makeTemporaryPackageURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatCoreWriterValidationTests-\(UUID().uuidString)", isDirectory: true)
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

    private func assertDuplicateEventError(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let MSPChatError.invalidTimelineEvent(message) = error else {
            return XCTFail("Expected invalidTimelineEvent, got \(error).", file: file, line: line)
        }
        XCTAssertTrue(message.contains("duplicate event id"), file: file, line: line)
    }
}

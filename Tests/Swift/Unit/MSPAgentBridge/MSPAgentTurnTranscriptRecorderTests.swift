import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPAgentTurnTranscriptRecorderTests: XCTestCase {
    func testStreamedSnapshotsAreCoalescedWithoutLosingLatestText() async {
        let capture = TranscriptSnapshotCapture()
        let recorder = MSPAgentTurnTranscriptRecorder(
            initialItems: [
                Self.message(role: "user", text: "写一句问候")
            ],
            onSnapshotUpdated: { items in
                await capture.append(items)
            }
        )

        await recorder.emitSnapshotUpdated()
        await recorder.updateStreamedMessage(text: "你", phase: "final_answer")
        await recorder.updateStreamedMessage(text: "你好", phase: "final_answer")

        let snapshotCountBeforeFlush = await capture.count()
        let liveSnapshot = await recorder.transcriptAppendItemsSnapshot()
        XCTAssertEqual(snapshotCountBeforeFlush, 1)
        XCTAssertEqual(Self.signatures(from: liveSnapshot), [
            "message:user:写一句问候",
            "message:assistant:你好"
        ])

        await recorder.flushPendingStreamedSnapshot()

        let snapshots = await capture.snapshots()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(Self.signatures(from: snapshots.last ?? []), [
            "message:user:写一句问候",
            "message:assistant:你好"
        ])
    }

    func testInterruptedSnapshotIncludesUnflushedStreamedText() async {
        let recorder = MSPAgentTurnTranscriptRecorder(
            initialItems: [
                Self.message(role: "user", text: "继续")
            ]
        )

        await recorder.updateStreamedMessage(text: "部分回复", phase: "final_answer")

        let interrupted = await recorder.interruptedTranscriptAppendItems()
        XCTAssertEqual(Self.signatures(from: interrupted), [
            "message:user:继续",
            "message:assistant:部分回复",
            "message:user:\(MSPAgentInterruptedTurnMarker.text)"
        ])
    }

    private static func message(role: String, text: String) -> MSPAgentJSONValue {
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

    private static func signatures(from input: [MSPAgentJSONValue]) -> [String] {
        input.map { item in
            guard let object = item.objectValue else {
                return ""
            }
            let role = object["role"]?.stringValue ?? ""
            let text = messageText(object)
            return [
                "message",
                role,
                text
            ].joined(separator: ":")
        }
    }

    private static func messageText(_ object: [String: MSPAgentJSONValue]) -> String {
        guard let content = object["content"]?.arrayValue else {
            return ""
        }
        return content.compactMap { item in
            item.objectValue?["text"]?.stringValue
        }.joined(separator: "\n")
    }
}

private actor TranscriptSnapshotCapture {
    private var values: [[MSPAgentJSONValue]] = []

    func append(_ items: [MSPAgentJSONValue]) {
        values.append(items)
    }

    func count() -> Int {
        values.count
    }

    func snapshots() -> [[MSPAgentJSONValue]] {
        values
    }
}

import XCTest
import MSPAgentBridge
@testable import PhotoSorter

final class MSPTerminalOutputPreviewTests: XCTestCase {
    func testPreviewKeepsTailWithinByteBudget() {
        var preview = MSPTerminalOutputPreview(maximumVisibleBytes: 12)

        XCTAssertEqual(preview.append("abcdef"), "abcdef")
        let display = preview.append("ghijklmnop")

        XCTAssertTrue(display.hasPrefix("...4 bytes truncated...\n"))
        XCTAssertTrue(display.hasSuffix("efghijklmnop"))
        XCTAssertFalse(display.contains("abcd"))
    }

    func testPreviewHandlesFinalTextLargerThanBudget() {
        let preview = MSPTerminalOutputPreview(
            text: "line-1\nline-2\nline-3\n",
            maximumVisibleBytes: 14
        )

        XCTAssertTrue(preview.displayText.hasPrefix("...7 bytes truncated...\n"))
        XCTAssertTrue(preview.displayText.hasSuffix("line-2\nline-3\n"))
    }

    func testPreviewAppliesTerminalBackspaceAcrossAppends() {
        var preview = MSPTerminalOutputPreview()

        XCTAssertEqual(preview.append(">>> subprocess.check_output(['printenv "), ">>> subprocess.check_output(['printenv ")
        XCTAssertEqual(preview.append("\u{8}'], text=True)\r\n"), ">>> subprocess.check_output(['printenv'], text=True)\n")
    }

    func testPreviewAppliesCarriageReturnLineOverwriteAcrossAppends() {
        var preview = MSPTerminalOutputPreview()

        XCTAssertEqual(preview.append("progress 10%"), "progress 10%")
        XCTAssertEqual(preview.append("\rprogress 20%\nabcdef\rxy\n"), "progress 20%\nxycdef\n")
    }

    func testShellOutputCoalescerBatchesCompleteLinesUntilFlush() async {
        let capture = MSPExecCommandOutputEventCapture()
        let coalescer = MSPPlaygroundShellOutputCoalescer(stream: .stdout) { event in
            await capture.append(event)
        }

        await coalescer.append(Data("tick 1\n".utf8))
        let textsBeforeFlush = await capture.texts()

        XCTAssertEqual(textsBeforeFlush, [])

        await coalescer.flush()
        let textsAfterFlush = await capture.texts()

        XCTAssertEqual(textsAfterFlush, ["tick 1\n"])
    }
}

private actor MSPExecCommandOutputEventCapture {
    private var events: [MSPExecCommandOutputEvent] = []

    func append(_ event: MSPExecCommandOutputEvent) {
        events.append(event)
    }

    func texts() -> [String] {
        events.map(\.text)
    }
}

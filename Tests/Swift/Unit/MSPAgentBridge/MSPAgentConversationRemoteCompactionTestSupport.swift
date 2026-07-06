import XCTest


extension MSPAgentConversationRequestTestCase {
    static func remoteCompactResponse(encryptedContent: String) -> String {
        """
        {"output":[{"type":"compaction","encrypted_content":"\(encryptedContent)"}]}
        """
    }

    static func remoteV2CompactionCompletedStream(encryptedContent: String) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_remote_v2_ignored","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"IGNORED_REMOTE_V2_REPLY"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"compaction","encrypted_content":"\(encryptedContent)"}}

        data: {"type":"response.completed","response":{"id":"resp_remote_v2_compact","output":[{"type":"message","id":"msg_remote_v2_ignored","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"IGNORED_REMOTE_V2_REPLY"}]},{"type":"compaction","encrypted_content":"\(encryptedContent)"}],"usage":{"input_tokens":123,"cached_input_tokens":7,"output_tokens":11,"total_tokens":134}}}

        data: [DONE]

        """
    }

    static func remoteV2CompactionClosedBeforeCompletedStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"compaction","encrypted_content":"PARTIAL_REMOTE_V2_SUMMARY"}}

        data: [DONE]

        """
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        // Expected.
    }
}

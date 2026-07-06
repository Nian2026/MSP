import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


extension MSPAgentConversationRequestTestCase {
    static func applyPatchAddFileBody(path: String, line: String) -> String {
        """
        *** Begin Patch
        *** Add File: \(path)
        +\(line)
        *** End Patch
        """
    }

    static func applyPatchToolCallStream(callID: String, patch: String) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"custom_tool_call","id":"ctc_patch","call_id":"\(callID)","name":"apply_patch","input":\(jsonStringLiteral(patch))}}

        data: {"type":"response.completed","response":{"id":"resp_patch","output":[{"type":"custom_tool_call","id":"ctc_patch","call_id":"\(callID)","name":"apply_patch","input":\(jsonStringLiteral(patch))}]}}

        data: [DONE]

        """
    }

    static func firstTurnToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先看一下工作区。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_1","output":[{"type":"message","id":"msg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先看一下工作区。"}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"}]}}

        data: [DONE]

        """
    }

    private static func jsonStringLiteral(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(data: data, encoding: .utf8)!
    }

    static func firstTurnToolCallStreamWithUsage(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先看一下工作区。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_1","output":[{"type":"message","id":"msg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先看一下工作区。"}]},{"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"}],"usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"total_tokens":\(totalTokens)}}}

        data: [DONE]

        """
    }

    static func yieldingExecToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_slow_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"这个命令可能需要等待。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_slow","call_id":"call_slow","name":"exec_command","arguments":"{\\"cmd\\":\\"slow-output\\",\\"yield_time_ms\\":100}"}}

        data: {"type":"response.completed","response":{"id":"resp_slow_1","output":[{"type":"message","id":"msg_slow_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"这个命令可能需要等待。"}]},{"type":"function_call","id":"fc_slow","call_id":"call_slow","name":"exec_command","arguments":"{\\"cmd\\":\\"slow-output\\",\\"yield_time_ms\\":100}"}]}}

        data: [DONE]

        """
    }

    static func writeStdinPollToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_poll_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我再等一轮。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_poll","call_id":"call_poll","name":"write_stdin","arguments":"{\\"session_id\\":1,\\"chars\\":\\"\\",\\"yield_time_ms\\":1000}"}}

        data: {"type":"response.completed","response":{"id":"resp_poll_1","output":[{"type":"message","id":"msg_poll_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我再等一轮。"}]},{"type":"function_call","id":"fc_poll","call_id":"call_poll","name":"write_stdin","arguments":"{\\"session_id\\":1,\\"chars\\":\\"\\",\\"yield_time_ms\\":1000}"}]}}

        data: [DONE]

        """
    }

    static func unexpectedWriteStdinArgumentToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_bad_stdin_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会写入输入。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_bad_stdin","call_id":"call_bad_stdin","name":"write_stdin","arguments":"{\\"session_id\\":1,\\"stdin\\":\\"hello\\\\n\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_bad_stdin_1","output":[{"type":"message","id":"msg_bad_stdin_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会写入输入。"}]},{"type":"function_call","id":"fc_bad_stdin","call_id":"call_bad_stdin","name":"write_stdin","arguments":"{\\"session_id\\":1,\\"stdin\\":\\"hello\\\\n\\"}"}]}}

        data: [DONE]

        """
    }

    static func multipleToolCallsStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_multi_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会先确认当前位置，再列出文件。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_pwd","call_id":"call_pwd","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"}}

        data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_ls","call_id":"call_ls","name":"exec_command","arguments":"{\\"cmd\\":\\"ls\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_multi_1","output":[{"type":"message","id":"msg_multi_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会先确认当前位置，再列出文件。"}]},{"type":"function_call","id":"fc_pwd","call_id":"call_pwd","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\"}"},{"type":"function_call","id":"fc_ls","call_id":"call_ls","name":"exec_command","arguments":"{\\"cmd\\":\\"ls\\"}"}]}}

        data: [DONE]

        """
    }

    static func manyToolCallsStream(count: Int) -> String {
        let messageItem = #"{"type":"message","id":"msg_many_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会连续执行这些命令。"}]}"#
        let callItems = (1...count).map { index in
            #"{"type":"function_call","id":"fc_\#(index)","call_id":"call_\#(index)","name":"exec_command","arguments":"{\"cmd\":\"cmd-\#(index)\"}"}"#
        }
        let outputItems = ([messageItem] + callItems).joined(separator: ",")
        let events = ([messageItem] + callItems).enumerated().map { index, item in
            #"data: {"type":"response.output_item.done","output_index":\#(index),"item":\#(item)}"#
        }.joined(separator: "\n\n")
        return """
        \(events)

        data: {"type":"response.completed","response":{"id":"resp_many_1","output":[\(outputItems)]}}

        data: [DONE]

        """
    }

    static func missingCommandToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_missing_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先尝试执行这个工作区命令。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_missing","call_id":"call_missing","name":"exec_command","arguments":"{\\"cmd\\":\\"missing\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_missing_1","output":[{"type":"message","id":"msg_missing_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我先尝试执行这个工作区命令。"}]},{"type":"function_call","id":"fc_missing","call_id":"call_missing","name":"exec_command","arguments":"{\\"cmd\\":\\"missing\\"}"}]}}

        data: [DONE]

        """
    }

    static func mediaViewToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_media_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我看一下原图。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_media","call_id":"call_media","name":"exec_command","arguments":"{\\"cmd\\":\\"media view /图库/a.png\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_media_1","output":[{"type":"message","id":"msg_media_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我看一下原图。"}]},{"type":"function_call","id":"fc_media","call_id":"call_media","name":"exec_command","arguments":"{\\"cmd\\":\\"media view /图库/a.png\\"}"}]}}

        data: [DONE]

        """
    }

    static func budgetedToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_truncated_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会按预算执行。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_truncated","call_id":"call_truncated","name":"exec_command","arguments":"{\\"cmd\\":\\"long-output\\",\\"max_output_tokens\\":1}"}}

        data: {"type":"response.completed","response":{"id":"resp_truncated_1","output":[{"type":"message","id":"msg_truncated_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会按预算执行。"}]},{"type":"function_call","id":"fc_truncated","call_id":"call_truncated","name":"exec_command","arguments":"{\\"cmd\\":\\"long-output\\",\\"max_output_tokens\\":1}"}]}}

        data: [DONE]

        """
    }

    static func fractionalBudgetToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_bad_budget_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会按预算执行。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_bad_budget","call_id":"call_bad_budget","name":"exec_command","arguments":"{\\"cmd\\":\\"long-output\\",\\"max_output_tokens\\":1.5}"}}

        data: {"type":"response.completed","response":{"id":"resp_bad_budget_1","output":[{"type":"message","id":"msg_bad_budget_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会按预算执行。"}]},{"type":"function_call","id":"fc_bad_budget","call_id":"call_bad_budget","name":"exec_command","arguments":"{\\"cmd\\":\\"long-output\\",\\"max_output_tokens\\":1.5}"}]}}

        data: [DONE]

        """
    }

    static func unexpectedArgumentToolCallStream() -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_unexpected_arg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会执行。"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_unexpected_arg","call_id":"call_unexpected_arg","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\",\\"cwd\\":\\"/\\"}"}}

        data: {"type":"response.completed","response":{"id":"resp_unexpected_arg_1","output":[{"type":"message","id":"msg_unexpected_arg_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"我会执行。"}]},{"type":"function_call","id":"fc_unexpected_arg","call_id":"call_unexpected_arg","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\",\\"cwd\\":\\"/\\"}"}]}}

        data: [DONE]

        """
    }

    static func firstTurnFinalAnswerStream() -> String {
        finalAnswerStream(id: "resp_2", messageID: "msg_2", text: "第一轮完成。")
    }

    static func secondTurnFinalAnswerStream() -> String {
        finalAnswerStream(id: "resp_3", messageID: "msg_3", text: "第二轮回答。")
    }

    static func thirdTurnFinalAnswerStream() -> String {
        finalAnswerStream(id: "resp_4", messageID: "msg_4", text: "第三轮回答。")
    }

    static func fourthTurnFinalAnswerStream() -> String {
        finalAnswerStream(id: "resp_5", messageID: "msg_5", text: "第四轮回答。")
    }

    static func finalAnswerStream(id: String, messageID: String, text: String) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"\(messageID)","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\(text)"}]}}

        data: {"type":"response.completed","response":{"id":"\(id)","output":[{"type":"message","id":"\(messageID)","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\(text)"}]}]}}

        data: [DONE]

        """
    }

    static func finalAnswerStreamWithUsage(
        id: String,
        messageID: String,
        text: String,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int
    ) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"\(messageID)","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\(text)"}]}}

        data: {"type":"response.completed","response":{"id":"\(id)","output":[{"type":"message","id":"\(messageID)","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\(text)"}]}],"usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"total_tokens":\(totalTokens)}}}

        data: [DONE]

        """
    }

    static func compactSummaryStream(text: String) -> String {
        """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_compact_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"\(text)"}]}}

        data: {"type":"response.completed","response":{"id":"resp_compact_1","output":[{"type":"message","id":"msg_compact_1","role":"assistant","phase":"assistant_message","content":[{"type":"output_text","text":"\(text)"}]}]}}

        data: [DONE]

        """
    }

    static func compactFailureStream(message: String) -> String {
        """
        data: {"type":"error","error":{"message":"\(message)"}}

        data: [DONE]

        """
    }

    static func compactContextWindowExceededStream() -> String {
        """
        data: {"type":"response.failed","response":{"id":"resp_compact_context_limit","status":"failed","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model. Please adjust your input and try again."}}}

        data: [DONE]

        """
    }
}

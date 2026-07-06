import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationToolOutputTests: MSPAgentConversationRequestTestCase {
    func testApplyPatchWithoutRuntimeReturnsCustomToolCallOutput() async throws {
        let patch = Self.applyPatchAddFileBody(path: "todo.txt", line: "hello")
        let harness = try RequestCaptureHarness(
            streams: [
                Self.applyPatchToolCallStream(callID: "call_patch", patch: patch),
                Self.finalAnswerStream(id: "resp_patch_final", messageID: "msg_patch_final", text: "没有配置补丁运行时。")
            ]
        )
        let conversation = harness.makeConversation(
            tools: MSPAgentRequestBuilder.codexToolDefinitions
        )

        _ = try await conversation.send("新建 todo")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:新建 todo",
            "custom_tool_call:apply_patch:call_patch:\(patch)",
            "custom_tool_call_output:call_patch:apply_patch runtime is not configured"
        ])
    }

    func testApplyPatchRuntimeExecutorReceivesRawPatchAndReturnsCustomOutput() async throws {
        let patch = Self.applyPatchAddFileBody(path: "done.txt", line: "hello")
        let executor = RecordingApplyPatchExecutor(
            result: MSPApplyPatchExecutionResult(
                ok: true,
                output: "Success. Updated the following files:\nA done.txt\n",
                changedPaths: ["done.txt"],
                exactDelta: true
            )
        )
        let harness = try RequestCaptureHarness(
            streams: [
                Self.applyPatchToolCallStream(callID: "call_patch", patch: patch),
                Self.finalAnswerStream(id: "resp_patch_final", messageID: "msg_patch_final", text: "补丁已应用。")
            ],
            applyPatchExecutor: executor
        )
        let conversation = harness.makeConversation(
            tools: MSPAgentRequestBuilder.codexToolDefinitions
        )

        _ = try await conversation.send("新建 done")

        let calls = await executor.calls
        XCTAssertEqual(calls.map(\.patch), [patch])
        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let customOutput = try XCTUnwrap(input.first { $0["type"] as? String == "custom_tool_call_output" })
        XCTAssertEqual(customOutput["call_id"] as? String, "call_patch")
        XCTAssertEqual(customOutput["output"] as? String, "Success. Updated the following files:\nA done.txt\n")
    }

    func testMultipleToolCallsAreWrittenBackInModelOutputOrderAtHTTPBoundary() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.multipleToolCallsStream(),
                Self.finalAnswerStream(id: "resp_multi_final", messageID: "msg_multi_final", text: "工具执行完成。")
            ],
            commandRunner: { cmd in
                switch cmd {
                case "pwd":
                    return .success(stdout: "/\n")
                case "ls":
                    return .success(stdout: "a.txt\n")
                default:
                    XCTFail("unexpected command: \(cmd)")
                    return .failure(exitCode: 127, stderr: "\(cmd): command not found\n")
                }
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("列一下工作区")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:列一下工作区",
            "message:assistant:commentary:我会先确认当前位置，再列出文件。",
            "function_call:exec_command:call_pwd",
            "function_call:exec_command:call_ls",
            "function_call_output:call_pwd:exec_output;exit=0;output=/\n",
            "function_call_output:call_ls:exec_output;exit=0;output=a.txt\n"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testExecCommandModelContentItemsAreWrittenAsMixedFunctionCallOutput() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.mediaViewToolCallStream(),
                Self.finalAnswerStream(id: "resp_media_final", messageID: "msg_media_final", text: "已查看原图。")
            ],
            commandRunner: { cmd in
                XCTAssertEqual(cmd, "media view /图库/a.png")
                return .success(
                    stdout: "Viewed original image: /图库/a.png\nSize: 1179x2556\n",
                    modelContentItems: [
                        .inputImage(data: Data([0x01, 0x02, 0x03]), mimeType: "image/png", detail: "original")
                    ]
                )
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("看这张图")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let functionOutput = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" })
        let output = try XCTUnwrap(functionOutput["output"] as? [[String: Any]])

        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0]["type"] as? String, "input_text")
        XCTAssertTrue((output[0]["text"] as? String ?? "").contains("Viewed original image: /图库/a.png"))
        XCTAssertEqual(output[1]["type"] as? String, "input_image")
        XCTAssertEqual(output[1]["image_url"] as? String, "data:image/png;base64,AQID")
        XCTAssertEqual(output[1]["detail"] as? String, "original")
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testFailedExecCommandOutputIsPlainTextAndPersistedInNextTurnHTTPBody() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.missingCommandToolCallStream(),
                Self.finalAnswerStream(id: "resp_missing_final", messageID: "msg_missing_final", text: "命令失败了。"),
                Self.secondTurnFinalAnswerStream()
            ],
            commandRunner: { cmd in
                XCTAssertEqual(cmd, "missing")
                return .failure(exitCode: 127, stderr: "missing: command not found\n")
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行一个不存在的命令")
        _ = try await conversation.send("刚才失败原因是什么？")

        let body = try await harness.capturedBody(at: 2)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:运行一个不存在的命令",
            "message:assistant:commentary:我先尝试执行这个工作区命令。",
            "function_call:exec_command:call_missing",
            "function_call_output:call_missing:exec_output;exit=127;output=missing: command not found\n",
            "message:assistant:final_answer:命令失败了。",
            "message:user:刚才失败原因是什么？"
        ])
        XCTAssertFalse(signatures.joined(separator: "\n").contains(#""stderr""#))
        XCTAssertFalse(signatures.joined(separator: "\n").contains(#""exit_code""#))
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testToolBudgetExhaustionIsReturnedAsOrderedPlainTextToolOutput() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.multipleToolCallsStream(),
                Self.finalAnswerStream(id: "resp_budget_final", messageID: "msg_budget_final", text: "预算已用完。")
            ],
            commandRunner: { cmd in
                XCTAssertEqual(cmd, "pwd")
                return .success(stdout: "/\n")
            }
        )
        let conversation = harness.makeConversation(toolCallLimit: .limited(to: 1))

        _ = try await conversation.send("预算内执行工具")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:预算内执行工具",
            "message:assistant:commentary:我会先确认当前位置，再列出文件。",
            "function_call:exec_command:call_pwd",
            "function_call:exec_command:call_ls",
            "function_call_output:call_pwd:exec_output;exit=0;output=/\n",
            "function_call_output:call_ls:tool-call budget exhausted"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testDefaultToolCallLimitAllowsMoreThanFormerEightCallCap() async throws {
        let commands = RecordedCommands()
        let harness = try RequestCaptureHarness(
            streams: [
                Self.manyToolCallsStream(count: 9),
                Self.finalAnswerStream(id: "resp_many_final", messageID: "msg_many_final", text: "全部完成。")
            ],
            commandRunner: { cmd in
                await commands.append(cmd)
                return .success(stdout: "\(cmd)\n")
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("连续执行九个命令")

        let executedCommands = await commands.all()
        XCTAssertEqual(executedCommands, (1...9).map { "cmd-\($0)" })
        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let outputs = input.compactMap { item -> (String, String)? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return (
                item["call_id"] as? String ?? "",
                item["output"] as? String ?? ""
            )
        }

        XCTAssertEqual(outputs.map(\.0), (1...9).map { "call_\($0)" })
        XCTAssertTrue(outputs.last?.1.contains("cmd-9\n") == true)
        XCTAssertFalse(outputs.map(\.1).joined(separator: "\n").contains("tool-call budget exhausted"))
        Self.assertDeveloperPromptIsWorkspaceNative(input)
    }

    func testModelRequestedOutputBudgetTruncatesCapturedToolOutput() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.budgetedToolCallStream(),
                Self.finalAnswerStream(id: "resp_truncated_final", messageID: "msg_truncated_final", text: "已截断。")
            ],
            commandRunner: { cmd in
                XCTAssertEqual(cmd, "long-output")
                return .success(stdout: "example output")
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行一个有预算的命令")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return item["output"] as? String
        }.last)

        XCTAssertFalse(output.contains("Original token count:"))
        XCTAssertTrue(output.contains("Total output lines: 1\n\nex…3 tokens truncated…ut"))
        XCTAssertFalse(output.contains("Warning: truncated output"))
    }

    func testFractionalOutputBudgetIsRejectedBeforeRunningCommand() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.fractionalBudgetToolCallStream(),
                Self.finalAnswerStream(id: "resp_bad_budget_final", messageID: "msg_bad_budget_final", text: "参数无效。")
            ],
            commandRunner: { cmd in
                XCTFail("command should not run with invalid max_output_tokens: \(cmd)")
                return .success(stdout: "unexpected\n")
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行一个小数预算的命令")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return item["output"] as? String
        }.last)

        XCTAssertEqual(output, "exec_command max_output_tokens must be a non-negative integer")
    }

    func testUnexpectedExecCommandArgumentIsRejectedBeforeRunningCommand() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.unexpectedArgumentToolCallStream(),
                Self.finalAnswerStream(id: "resp_unexpected_arg_final", messageID: "msg_unexpected_arg_final", text: "参数无效。")
            ],
            commandRunner: { cmd in
                XCTFail("command should not run with unsupported argument: \(cmd)")
                return .success(stdout: "unexpected\n")
            }
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行一个带额外参数的命令")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return item["output"] as? String
        }.last)

        XCTAssertEqual(output, #"exec_command arguments contain unsupported keys, got ["cmd", "cwd"]"#)
    }

    func testUnexpectedWriteStdinArgumentIsRejectedBeforeWritingToSession() async throws {
        let harness = try RequestCaptureHarness(
            streams: [
                Self.unexpectedWriteStdinArgumentToolCallStream(),
                Self.finalAnswerStream(id: "resp_bad_stdin_final", messageID: "msg_bad_stdin_final", text: "参数无效。")
            ]
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("写入一个带额外参数的输入")

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let output = try XCTUnwrap(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return item["output"] as? String
        }.last)

        XCTAssertEqual(output, #"write_stdin arguments contain unsupported keys, got ["session_id", "stdin"]"#)
    }

}

private actor RecordingApplyPatchExecutor: MSPApplyPatchExecuting {
    private(set) var calls: [MSPApplyPatchCall] = []
    private let result: MSPApplyPatchExecutionResult

    init(result: MSPApplyPatchExecutionResult) {
        self.result = result
    }

    func execute(_ call: MSPApplyPatchCall) async -> MSPApplyPatchExecutionResult {
        calls.append(call)
        return result
    }
}

import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


final class MSPAgentConversationExecSessionRequestTests: MSPAgentConversationRequestTestCase {
    func testConversationEmitsExecCommandOutputDeltasBeforeToolCompletion() async throws {
        let events = RecordedAgentEvents()
        let bridge = MSPExecCommandBridge { call, outputHandler in
            XCTAssertEqual(call.cmd, "pwd")
            await outputHandler?(MSPExecCommandOutputEvent(stream: .stdout, text: "/"))
            await outputHandler?(MSPExecCommandOutputEvent(stream: .stdout, text: "\n"))
            return .success(stdout: "/\n")
        }
        let harness = try RequestCaptureHarness(
            streams: [
                Self.firstTurnToolCallStream(),
                Self.firstTurnFinalAnswerStream()
            ],
            execCommandBridge: bridge
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("第一轮：看看当前目录", onEvent: { event in
            await events.append(event)
        })

        let signatures = await events.toolSignatures()
        XCTAssertEqual(signatures, [
            "toolStarted:call_1",
            "toolOutputDelta:call_1:stdout:/",
            "toolOutputDelta:call_1:stdout:\n",
            "toolCompleted:call_1:true"
        ])

        let body = try await harness.capturedBody(at: 1)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let functionOutput = try XCTUnwrap(input.compactMap { item -> String? in
            guard item["type"] as? String == "function_call_output" else {
                return nil
            }
            return item["output"] as? String
        }.last)
        XCTAssertTrue(functionOutput.contains("Output:\n/\n"))
        XCTAssertFalse(functionOutput.contains(#""stdout""#))
        XCTAssertFalse(functionOutput.contains(#""exit_code""#))
    }

    func testConversationCanPollYieldedExecSessionWithWriteStdinTool() async throws {
        let events = RecordedAgentEvents()
        let transport = PollingSessionTransport()
        let bridge = MSPExecCommandBridge(sessionCoordinator: MSPExecCommandSessionCoordinator(
            transport: transport
        ))
        let harness = try RequestCaptureHarness(
            streams: [
                Self.yieldingExecToolCallStream(),
                Self.writeStdinPollToolCallStream(),
                Self.finalAnswerStream(id: "resp_poll_final", messageID: "msg_poll_final", text: "慢命令完成。")
            ],
            execCommandBridge: bridge
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行一个会 yield 的命令", onEvent: { event in
            await events.append(event)
        })

        let firstBody = try await harness.capturedBody(at: 0)
        let toolNames = try XCTUnwrap(firstBody["tools"] as? [[String: Any]])
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(toolNames, ["exec_command", "write_stdin"])

        let continuationBody = try await harness.capturedBody(at: 2)
        let input = try XCTUnwrap(continuationBody["input"] as? [[String: Any]])
        let signatures = Self.signatures(from: input)

        XCTAssertEqual(signatures, [
            "message:developer",
            "message:user:运行一个会 yield 的命令",
            "message:assistant:commentary:这个命令可能需要等待。",
            "function_call:exec_command:call_slow",
            "function_call_output:call_slow:exec_output;running=1;output=first\n",
            "message:assistant:commentary:我再等一轮。",
            "function_call:write_stdin:call_poll",
            "function_call_output:call_poll:exec_output;exit=0;output=second\n"
        ])
        Self.assertProviderMessagePhasesAreSafe(input)
        let startedCommands = await transport.startedCommands()
        let writes = await transport.writes()
        let readWaits = await transport.readWaits()
        XCTAssertEqual(startedCommands, ["slow-output"])
        XCTAssertEqual(writes, [])
        XCTAssertEqual(readWaits, [5_000])

        let writeProbes = await events.probeFields(
            named: "probe_agent_runtime_bridge_write_stdin_before"
        )
        XCTAssertEqual(writeProbes.count, 1)
        XCTAssertEqual(writeProbes.first?["session_id"], "1")
        XCTAssertEqual(writeProbes.first?["chars_kind"], "empty_poll")
        XCTAssertEqual(writeProbes.first?["chars_length"], "0")
        XCTAssertEqual(writeProbes.first?["yield_time_ms"], "1000")

        let runAfterProbes = await events.probeFields(
            named: "probe_agent_runtime_bridge_run_after"
        )
        XCTAssertEqual(runAfterProbes.count, 1)
        XCTAssertEqual(runAfterProbes.first?["session_id"], "1")
        XCTAssertEqual(runAfterProbes.first?["running_session_id"], "1")
        XCTAssertEqual(runAfterProbes.first?["exit_code"], "")
        XCTAssertEqual(runAfterProbes.first?["yield_time_ms"], "100")
        XCTAssertEqual(runAfterProbes.first?["signal"], "")
        XCTAssertEqual(runAfterProbes.first?["stderr_preview"], "")

        let writeAfterProbes = await events.probeFields(
            named: "probe_agent_runtime_bridge_write_stdin_after"
        )
        XCTAssertEqual(writeAfterProbes.count, 1)
        XCTAssertEqual(writeAfterProbes.first?["session_id"], "1")
        XCTAssertEqual(writeAfterProbes.first?["running_session_id"], "")
        XCTAssertEqual(writeAfterProbes.first?["exit_code"], "0")
        XCTAssertEqual(writeAfterProbes.first?["chars_kind"], "empty_poll")
        XCTAssertEqual(writeAfterProbes.first?["chars_length"], "0")
        XCTAssertEqual(writeAfterProbes.first?["yield_time_ms"], "1000")
        XCTAssertEqual(writeAfterProbes.first?["signal"], "")
        XCTAssertEqual(writeAfterProbes.first?["stderr_preview"], "")
    }

    func testConversationProbeCapturesExecCommandSignalAndStderrPreview() async throws {
        let events = RecordedAgentEvents()
        let bridge = MSPExecCommandBridge(sessionCoordinator: MSPExecCommandSessionCoordinator(
            transport: SignalFailureSessionTransport()
        ))
        let harness = try RequestCaptureHarness(
            streams: [
                Self.firstTurnToolCallStream(),
                Self.finalAnswerStream(id: "resp_signal_final", messageID: "msg_signal_final", text: "命令被信号终止。")
            ],
            execCommandBridge: bridge
        )
        let conversation = harness.makeConversation()

        _ = try await conversation.send("运行会被 signal 终止的命令", onEvent: { event in
            await events.append(event)
        })

        let runAfterProbes = await events.probeFields(
            named: "probe_agent_runtime_bridge_run_after"
        )
        XCTAssertEqual(runAfterProbes.count, 1)
        XCTAssertEqual(runAfterProbes.first?["call_id"], "call_1")
        XCTAssertEqual(runAfterProbes.first?["name"], "exec_command")
        XCTAssertEqual(runAfterProbes.first?["cmd"], "pwd")
        XCTAssertEqual(runAfterProbes.first?["exit_code"], "137")
        XCTAssertEqual(runAfterProbes.first?["signal"], "9")
        XCTAssertEqual(runAfterProbes.first?["session_id"], "")
        XCTAssertEqual(runAfterProbes.first?["stderr_bytes"], "17")
        XCTAssertEqual(runAfterProbes.first?["stderr_preview"], "killed by signal\n")
    }

}

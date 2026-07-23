import Foundation
import XCTest
import MSPAgentBridge
import MSPApple
import MSPExternalRunner
import ModelShellProxy

final class ModelShellProxyExecCommandPipelineTests: ModelShellProxyIntegrationTestCase {
    func testExecCommandBridgeForwardsForLoopStreamingOutputBeforeCompletionWhenObserved() async throws {
        let gate = GatedStreamingCommandGate()
        let events = ExecCommandOutputEventCapture()
        let registry = try MSPCommandRegistry(commands: [
            GatedStreamingCommand(gate: gate)
        ])
        let shell = ModelShellProxy(registry: registry)
        let bridge = shell.execCommandBridge()

        let task = Task {
            await bridge.run(
                MSPExecCommandCall(cmd: "for item in only; do gated-stream; done"),
                onOutput: { event in
                    await events.append(event)
                }
            )
        }

        let didStreamFirstOutput = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await events.stdoutText() == "first\n"
        }

        let firstOutput = await events.stdoutText()
        let wasReleasedBeforeCompletion = await gate.isReleased()
        XCTAssertTrue(didStreamFirstOutput)
        XCTAssertEqual(firstOutput, "first\n")
        XCTAssertFalse(wasReleasedBeforeCompletion)

        await gate.release()
        let result = await task.value

        XCTAssertEqual(result.stdout, "first\nsecond\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let finalOutput = await events.stdoutText()
        XCTAssertEqual(finalOutput, "first\nsecond\n")
        let wasReleasedAfterCompletion = await gate.isReleased()
        XCTAssertTrue(wasReleasedAfterCompletion)
    }

    func testExecCommandBridgeYieldsPipeSessionAndPollsIncrementalOutput() async throws {
        let gate = GatedStreamingCommandGate()
        let events = ExecCommandOutputEventCapture()
        let registry = try MSPCommandRegistry(commands: [
            GatedStreamingCommand(gate: gate)
        ])
        let shell = ModelShellProxy(registry: registry)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(
            MSPExecCommandCall(
                cmd: "for item in only; do gated-stream; done",
                yieldTimeMilliseconds: 500
            ),
            onOutput: { event in
                await events.append(event)
            }
        )

        let sessionID = try XCTUnwrap(start.runningSessionID)
        let firstEventOutput = await events.stdoutText()
        let wasReleasedBeforePoll = await gate.isReleased()
        XCTAssertEqual(sessionID, 1)
        XCTAssertEqual(start.result.stdout, "first\n")
        XCTAssertEqual(start.result.stderr, "")
        XCTAssertEqual(firstEventOutput, "first\n")
        XCTAssertFalse(wasReleasedBeforePoll)

        await gate.release()
        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertEqual(poll.result.stdout, "second\n")
        XCTAssertEqual(poll.result.stderr, "")
        let finalEventOutput = await events.stdoutText()
        let wasReleasedAfterPoll = await gate.isReleased()
        XCTAssertEqual(finalEventOutput, "first\nsecond\n")
        XCTAssertTrue(wasReleasedAfterPoll)
    }

    func testExecCommandBridgeBufferedPipelineSortDoesNotReadLiveSessionStdin() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'b\\na\\n' | sort; echo done",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stdout, "a\nb\ndone\n")
        XCTAssertEqual(read.result.stderr, "")
    }

    func testExecCommandBridgeBufferedFindSortPipelineDoesNotReadLiveSessionStdin() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: """
            mkdir -p /tmp/pressure-check
            printf 'beta\\n' > /tmp/pressure-check/b.txt
            printf 'alpha\\n' > /tmp/pressure-check/a.txt
            find /tmp/pressure-check -maxdepth 1 -type f | sort
            """,
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(
            read.result.stdout,
            "/tmp/pressure-check/a.txt\n/tmp/pressure-check/b.txt\n"
        )
        XCTAssertEqual(read.result.stderr, "")
    }

    func testExecCommandBridgeRgSearchesPipelineInputInsteadOfWorkspace() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("git status --short --branch\n".utf8).write(
            to: rootURL.appendingPathComponent("commands.txt")
        )
        try Data([0x25, 0x50, 0x44, 0x46, 0x2d, 0x00, 0x50, 0x49, 0x44]).write(
            to: rootURL.appendingPathComponent("lecture.pdf")
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'PID PPID STAT COMMAND ARGS\\n123 0 S bash bash\\n' | rg 'git status --short --branch|PID'",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stdout, "PID PPID STAT COMMAND ARGS\n")
        XCTAssertEqual(read.result.stderr, "")

        let emptyRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf '' | rg PID",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(emptyRead.runningSessionID)
        XCTAssertEqual(emptyRead.exitCode, 1)
        XCTAssertEqual(emptyRead.result.stdout, "")
        XCTAssertEqual(emptyRead.result.stderr, "")

        let explicitFileRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'PIPE PID\\n' | rg 'git status' commands.txt",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(explicitFileRead.runningSessionID)
        XCTAssertEqual(explicitFileRead.exitCode, 0)
        XCTAssertEqual(explicitFileRead.result.stdout, "git status --short --branch\n")
        XCTAssertEqual(explicitFileRead.result.stderr, "")
    }

    func testExecCommandBridgeStartsInProcessExternalCommandWithoutWaitingForSessionEOF() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        try shell.registerExternalCommand(
            "inprocess-probe",
            runner: MSPInProcessExternalCommandRunner(
                executableURL: URL(fileURLWithPath: "/runtime/bin/inprocess-probe"),
                executor: ImmediateInProcessExternalExecutor()
            )
        )
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "inprocess-probe",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stdout, "started with 0 stdin bytes\n")
        XCTAssertEqual(read.result.stderr, "")
    }

    #if os(macOS)
    func testExecCommandBridgeYieldsPTYSessionAndWritesInteractiveStdin() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let command = """
        printf 'READY\\n'; while IFS= read -r line; do [ "$line" = DONE ] && break; printf 'got:%s\\n' "$line"; done; echo FINISHED
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 300
        ))

        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "READY\r\n")
        XCTAssertEqual(start.result.stderr, "")

        let firstWrite = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "alpha\n",
            yieldTimeMilliseconds: 300
        ))

        XCTAssertEqual(firstWrite.runningSessionID, sessionID)
        XCTAssertEqual(firstWrite.result.stdout, "alpha\r\ngot:alpha\r\n")
        XCTAssertEqual(firstWrite.result.stderr, "")

        let finalWrite = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "beta\nDONE\n",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(finalWrite.runningSessionID)
        XCTAssertEqual(finalWrite.exitCode, 0)
        XCTAssertEqual(finalWrite.signal, nil)
        XCTAssertEqual(finalWrite.result.stdout, "beta\r\nDONE\r\ngot:beta\r\nFINISHED\r\n")
        XCTAssertEqual(finalWrite.result.stderr, "")
    }

    func testExecCommandBridgePTYLateWriteAfterExitReturnsCompletedResult() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'READY\\n'; sleep 0.6; printf 'after-pty\\n'",
            tty: true,
            yieldTimeMilliseconds: 300
        ))

        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "READY\r\n")
        XCTAssertEqual(start.result.stderr, "")

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let lateWrite = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "too late\n",
            yieldTimeMilliseconds: 300
        ))

        XCTAssertNil(lateWrite.runningSessionID)
        XCTAssertEqual(lateWrite.exitCode, 0)
        XCTAssertEqual(lateWrite.signal, nil)
        XCTAssertEqual(lateWrite.result.stdout, "after-pty\r\n")
        XCTAssertEqual(lateWrite.result.stderr, "")
    }

    func testExecCommandBridgePTYMergesStderrAndPreservesExitCode() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'OUT1\\n'; printf 'ERR1\\n' >&2; printf 'OUT2\\n'; exit 7",
            tty: true,
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 7)
        XCTAssertEqual(read.signal, nil)
        XCTAssertEqual(read.result.stdout, "OUT1\r\nERR1\r\nOUT2\r\n")
        XCTAssertEqual(read.result.stderr, "")
    }

    func testExecCommandBridgePTYCtrlCClosesRunawaySession() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let command = "trap 'printf INT\\\\n; exit 130' INT; printf READY\\\\n; while :; do sleep 5; done"

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "READY\r\n")

        let interrupted = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{3}",
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(interrupted.runningSessionID)
        XCTAssertTrue(
            interrupted.exitCode == 130 || interrupted.signal == 2,
            "expected shell trap exit 130 or SIGINT signal 2, got exit=\(String(describing: interrupted.exitCode)) signal=\(String(describing: interrupted.signal))"
        )
        XCTAssertTrue(
            interrupted.result.stdout.contains("INT\r\n")
                || interrupted.result.stdout.contains("^C"),
            "expected PTY interrupt output, got \(String(reflecting: interrupted.result.stdout))"
        )
    }

    func testExecCommandBridgePTYWritesRawInvalidUTF8Bytes() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "od -An -tx1",
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            stdinData: Data([0x6f, 0x6b, 0xff, 0x0a, 0x04]),
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(write.runningSessionID)
        XCTAssertEqual(write.exitCode, 0)
        let output = write.result.stdoutData
        XCTAssertTrue(
            output.contains(Data([0x6f, 0x6b, 0xff, 0x0d, 0x0a])),
            String(describing: output as NSData)
        )
        XCTAssertTrue(
            String(decoding: output, as: UTF8.self).contains("ff"),
            String(decoding: output, as: UTF8.self)
        )
    }
    #endif

}

private struct ImmediateInProcessExternalExecutor: MSPInProcessExternalCommandExecutor {
    func execute(
        _ invocation: MSPInProcessExternalCommandInvocation
    ) async throws -> MSPCommandResult {
        .success(stdout: "started with \(invocation.standardInput.count) stdin bytes\n")
    }
}

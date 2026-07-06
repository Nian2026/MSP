import Foundation
import XCTest
import MSPCore
import MSPApple
@testable import MSPPythonRuntime

final class MSPPythonSubprocessBrokerTests: XCTestCase {
    func testRunDelegatesToBaseCommandLineRunnerWithVirtualPolicyContext() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPPythonSubprocessBrokerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let capture = CapturedSubprocessInvocation()
        let broker = try brokerWithBaseContext(MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/docs",
            environment: ["BASE": "1"],
            commandLineRunner: { commandLine, context in
                capture.record(commandLine: commandLine, context: context)
                guard commandLine == "sha256sum --version" else {
                    return MSPCommandResult.failure(exitCode: 125, stderr: "unexpected command\n")
                }
                return MSPCommandResult.failure(exitCode: 127, stderr: "sha256sum: command not found\n")
            }
        ))

        let response = broker.run(subprocessRequest(
            commandLine: "sha256sum --version",
            stdinData: Data("payload".utf8),
            cwd: "/tmp",
            environment: ["BASE": "2", "CUSTOM": "value"]
        ))

        XCTAssertEqual(response.exitCode, 127)
        XCTAssertEqual(decoded(response.stdoutB64), "")
        XCTAssertEqual(decoded(response.stderrB64), "sha256sum: command not found\n")
        XCTAssertEqual(capture.commandLine, "sha256sum --version")
        let context = try XCTUnwrap(capture.context)
        XCTAssertEqual(context.currentDirectory, "/tmp")
        XCTAssertEqual(context.environment, ["BASE": "2", "CUSTOM": "value"])
        XCTAssertEqual(context.standardInput, Data("payload".utf8))
        XCTAssertFalse(context.standardInputClosed)
        XCTAssertNotNil(context.workspace)
        XCTAssertTrue(context.workspace is MSPPythonCancellableWorkspace)
    }

    func testSessionStdinWritesCompleteBeforeClose() throws {
        let request = subprocessRequest(action: "start", commandLine: "cat", stdinPipe: true)
        let session = MSPPythonSubprocessSession(
            id: "session",
            request: request,
            baseContext: MSPCommandContext(),
            runner: { _, context in
                var received = Data()
                if let inputStream = context.standardInputStream {
                    while true {
                        guard let chunk = try? await inputStream.read(maxBytes: 4096) else {
                            break
                        }
                        received.append(chunk)
                    }
                }
                try? await context.standardOutputStream?.write(received)
                return MSPCommandResult(stdoutData: Data(), exitCode: 0)
            },
            runnerGate: MSPPythonSubprocessRunnerGate(),
            cancellationToken: MSPPythonSubprocessCancellationToken()
        )

        session.start()
        var expected = ""
        for index in 0..<256 {
            let line = "chunk-\(index)\n"
            expected += line
            session.writeStdin(Data(line.utf8))
        }
        session.closeStdin()

        XCTAssertTrue(session.wait(timeout: 5))
        let output = String(data: session.read(stream: "stdout", maxBytes: -1), encoding: .utf8)
        XCTAssertEqual(output, expected)
        XCTAssertEqual(session.returnCode, 0)
    }

    func testWaitUsesRemainingDeadline() throws {
        let broker = try brokerWithRunner { _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return MSPCommandResult(stdoutData: Data(), exitCode: 0)
        }
        let start = broker.startSession(subprocessRequest(action: "start", commandLine: "sleep"))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let expired = broker.wait(subprocessRequest(
            action: "wait",
            timeout: 1,
            deadlineUnix: Date().timeIntervalSince1970 - 0.01,
            sessionID: sessionID
        ))

        XCTAssertEqual(expired.timedOut, true)
        XCTAssertEqual(expired.running, true)
    }

    func testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt() throws {
        let broker = try brokerWithRunner { _, context in
            try? await context.standardOutputStream?.write(Data("out".utf8))
            try? await context.standardErrorStream?.write(Data("err".utf8))
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await context.standardOutputStream?.write(Data("-done".utf8))
            return MSPCommandResult(stdoutData: Data(), exitCode: 0)
        }
        let start = broker.startSession(subprocessRequest(action: "start", commandLine: "slow"))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let expired = broker.wait(subprocessRequest(
            action: "wait",
            timeout: 0.2,
            sessionID: sessionID
        ))
        let final = broker.wait(subprocessRequest(action: "wait", timeout: 1, sessionID: sessionID))

        XCTAssertEqual(expired.timedOut, true)
        XCTAssertEqual(expired.running, true)
        XCTAssertEqual(decoded(expired.stdoutB64), "out")
        XCTAssertEqual(decoded(expired.stderrB64), "err")
        XCTAssertEqual(final.timedOut, nil)
        XCTAssertEqual(decoded(final.stdoutB64), "out-done")
        XCTAssertEqual(decoded(final.stderrB64), "err")
    }

    func testWaitReturnsUnreadMergedOutputAfterRead() throws {
        let broker = try brokerWithRunner { _, context in
            try? await context.standardOutputStream?.write(Data("out".utf8))
            try? await context.standardErrorStream?.write(Data("err".utf8))
            return MSPCommandResult(stdoutData: Data(), exitCode: 7)
        }
        let start = broker.startSession(subprocessRequest(
            action: "start",
            commandLine: "printf",
            mergeStderrToStdout: true
        ))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let firstByte = broker.read(subprocessRequest(
            action: "read",
            sessionID: sessionID,
            stream: "stdout",
            maxBytes: 1
        ))
        let wait = broker.wait(subprocessRequest(action: "wait", sessionID: sessionID))

        XCTAssertEqual(decoded(firstByte.dataB64), "o")
        XCTAssertEqual(decoded(wait.stdoutB64), "uterr")
        XCTAssertEqual(decoded(wait.stderrB64), "")
        XCTAssertEqual(wait.exitCode, 7)
        XCTAssertEqual(wait.running, false)
    }

    func testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream() throws {
        let broker = try brokerWithRunner { _, _ in
            MSPCommandResult(
                stdoutData: Data("returned-out".utf8),
                stderrData: Data("returned-err".utf8),
                exitCode: 9
            )
        }
        let start = broker.startSession(subprocessRequest(
            action: "start",
            commandLine: "printf"
        ))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let wait = broker.wait(subprocessRequest(action: "wait", sessionID: sessionID))

        XCTAssertEqual(decoded(wait.stdoutB64), "returned-out")
        XCTAssertEqual(decoded(wait.stderrB64), "returned-err")
        XCTAssertEqual(wait.exitCode, 9)
        XCTAssertEqual(wait.running, false)
    }

    func testSessionMergesReturnedStderrWhenRunnerDoesNotStream() throws {
        let broker = try brokerWithRunner { _, _ in
            MSPCommandResult(
                stdoutData: Data("returned-out".utf8),
                stderrData: Data("returned-err".utf8),
                exitCode: 9
            )
        }
        let start = broker.startSession(subprocessRequest(
            action: "start",
            commandLine: "printf",
            mergeStderrToStdout: true
        ))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let wait = broker.wait(subprocessRequest(action: "wait", sessionID: sessionID))

        XCTAssertEqual(decoded(wait.stdoutB64), "returned-outreturned-err")
        XCTAssertEqual(decoded(wait.stderrB64), "")
        XCTAssertEqual(wait.exitCode, 9)
        XCTAssertEqual(wait.running, false)
    }

    func testClosingOutputReadEndTurnsReturnedOutputIntoBrokenPipe() throws {
        let broker = try brokerWithRunner { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return MSPCommandResult(stdoutData: Data("late".utf8), exitCode: 0)
        }
        let start = broker.startSession(subprocessRequest(
            action: "start",
            commandLine: "sleep 0.1; printf late"
        ))
        let sessionID = try XCTUnwrap(start.sessionID)
        defer {
            _ = broker.close(subprocessRequest(action: "close", sessionID: sessionID))
        }

        let close = broker.closeOutput(subprocessRequest(
            action: "closeOutput",
            sessionID: sessionID,
            stream: "stdout"
        ))
        let wait = broker.wait(subprocessRequest(action: "wait", sessionID: sessionID))

        XCTAssertEqual(close.running, true)
        XCTAssertEqual(wait.exitCode, -13)
        XCTAssertEqual(decoded(wait.stdoutB64), "")
        XCTAssertEqual(decoded(wait.stderrB64), "")
        XCTAssertEqual(wait.running, false)
    }

    private func brokerWithRunner(
        _ runner: @escaping MSPCommandLineRunner
    ) throws -> MSPPythonSubprocessBroker {
        try brokerWithBaseContext(MSPCommandContext(commandLineRunner: runner))
    }

    private func brokerWithBaseContext(
        _ context: MSPCommandContext
    ) throws -> MSPPythonSubprocessBroker {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPPythonSubprocessBrokerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try MSPPythonSubprocessBroker(
            directoryURL: directory,
            baseContext: context
        )
    }

    private func subprocessRequest(
        id: String = UUID().uuidString,
        action: String? = nil,
        commandLine: String? = nil,
        stdinData: Data = Data(),
        stdinPipe: Bool? = nil,
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        deadlineUnix: TimeInterval? = nil,
        sessionID: String? = nil,
        stream: String? = nil,
        maxBytes: Int? = nil,
        mergeStderrToStdout: Bool? = nil
    ) -> MSPPythonSubprocessRequest {
        MSPPythonSubprocessRequest(
            id: id,
            action: action,
            commandLine: commandLine,
            stdinB64: stdinData.isEmpty ? nil : stdinData.base64EncodedString(),
            stdinPipe: stdinPipe,
            cwd: cwd,
            environment: environment,
            timeout: timeout,
            deadlineUnix: deadlineUnix,
            sessionID: sessionID,
            stream: stream,
            maxBytes: maxBytes,
            mergeStderrToStdout: mergeStderrToStdout
        )
    }

    private func decoded(_ value: String?) -> String {
        let data = Data(base64Encoded: value ?? "") ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class CapturedSubprocessInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommandLine: String?
    private var storedContext: MSPCommandContext?

    var commandLine: String? {
        lock.withLock { storedCommandLine }
    }

    var context: MSPCommandContext? {
        lock.withLock { storedContext }
    }

    func record(commandLine: String, context: MSPCommandContext) {
        lock.withLock {
            storedCommandLine = commandLine
            storedContext = context
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

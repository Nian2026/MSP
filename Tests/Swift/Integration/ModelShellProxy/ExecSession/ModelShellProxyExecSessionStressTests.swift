import Foundation
import XCTest
import MSPAgentBridge
@testable import ModelShellProxy
import MSPPythonRuntime

final class ModelShellProxyExecSessionStressTests: ModelShellProxyIntegrationTestCase {
    func testExecSessionStressRunsConcurrentYieldedPipeSessions() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let sessionCount = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_CONCURRENCY",
            defaultValue: 12
        )

        let results = await withTaskGroup(of: PipeStressResult.self) { group in
            for index in 0..<sessionCount {
                group.addTask {
                    let start = await bridge.runSession(MSPExecCommandCall(
                        cmd: "printf 'start-\(index)\\n'; sleep 0.35; printf 'end-\(index)\\n'",
                        yieldTimeMilliseconds: 250
                    ))
                    var output = start.result.stdout
                    var stderr = start.result.stderr
                    var runningSessionID = start.runningSessionID
                    var exitCode = start.exitCode
                    var pollCount = 0

                    while let sessionID = runningSessionID, pollCount < 8 {
                        let poll = await bridge.writeStdin(MSPWriteStdinCall(
                            sessionID: sessionID,
                            chars: "",
                            yieldTimeMilliseconds: 250
                        ))
                        output += poll.result.stdout
                        stderr += poll.result.stderr
                        runningSessionID = poll.runningSessionID
                        exitCode = poll.exitCode
                        pollCount += 1
                    }

                    return PipeStressResult(
                        index: index,
                        output: output,
                        stderr: stderr,
                        exitCode: exitCode,
                        runningSessionID: runningSessionID
                    )
                }
            }

            var collected: [PipeStressResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, sessionCount)
        for result in results {
            XCTAssertNil(result.runningSessionID, "pipe session \(result.index) did not complete")
            XCTAssertEqual(result.exitCode, 0, "pipe session \(result.index) exit")
            XCTAssertEqual(result.stderr, "", "pipe session \(result.index) stderr")
            XCTAssertTrue(result.output.contains("start-\(result.index)\n"), result.output)
            XCTAssertTrue(result.output.contains("end-\(result.index)\n"), result.output)
        }
    }

    func testExecSessionStressSilentPipeProcessYieldsAndEmptyPollCompletes() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "sleep 0.4; printf 'silent-done\\n'",
            yieldTimeMilliseconds: 250
        ))

        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "")
        XCTAssertEqual(start.result.stderr, "")

        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 1
        ))

        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertEqual(poll.result.stdout, "silent-done\n")
        XCTAssertEqual(poll.result.stderr, "")
    }

    func testExecSessionStressFileRedirectionInsideForLoopDoesNotWaitForLiveStdin() async throws {
        let rootURL = makeTemporaryURL("file-redirection-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: """
            mkdir -p /tmp
            printf 'one\\ntwo\\n' > /tmp/lines.txt
            printf 'counts if present:\\n'
            for f in /tmp/lines.txt; do
              [ -f "$f" ] && printf '%s ' "$f" && wc -l < "$f" || true
            done
            """,
            yieldTimeMilliseconds: 250
        ))

        XCTAssertNil(read.runningSessionID, read.result.stdout + read.result.stderr)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stderr, "")
        XCTAssertTrue(read.result.stdout.contains("counts if present:\n"), read.result.stdout)
        XCTAssertTrue(read.result.stdout.contains("/tmp/lines.txt"), read.result.stdout)
        XCTAssertTrue(read.result.stdout.contains("2"), read.result.stdout)
    }

    func testExecSessionStressTmpCandidateCountCommandCompletesWithoutPolling() async throws {
        let rootURL = makeTemporaryURL("tmp-candidate-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let command = """
        set -e
        mkdir -p /tmp
        for f in cleanup_round3_pool3.txt cleanup_round3_refined.txt cleanup_round3_candidates.txt cleanup_round3_candidates.jsonl cleanup_round3_ask_selected.txt cleanup_round3_ask_excluded.txt; do
          for i in 1 2 3 4 5 6 7 8 9 10; do printf '/相册/系统/截图/%s_%s.png\\n' "$f" "$i"; done > "/tmp/$f"
        done
        printf 'candidate/jsonl files:\\n'
        ls -1 /tmp | grep -E 'cleanup_.*(refined|candidate|jsonl|ask_selected|ask_excluded|pool)' | tail -80 || true
        printf '\\ncounts if present:\\n'
        for f in /tmp/cleanup_round3_pool3.txt /tmp/cleanup_round3_refined.txt /tmp/cleanup_round3_candidates.txt /tmp/cleanup_round3_candidates.jsonl /tmp/cleanup_round3_ask_selected.txt /tmp/cleanup_round3_ask_excluded.txt; do
          [ -f "$f" ] && printf '%s ' "$f" && wc -l < "$f" || true
        done
        """.trimmingCharacters(in: .newlines)

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID, read.result.stdout + read.result.stderr)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stderr, "")
        XCTAssertTrue(read.result.stdout.contains("candidate/jsonl files:\n"), read.result.stdout)
        XCTAssertTrue(read.result.stdout.contains("counts if present:\n"), read.result.stdout)
        XCTAssertTrue(read.result.stdout.contains("/tmp/cleanup_round3_pool3.txt 10\n"), read.result.stdout)
        XCTAssertTrue(read.result.stdout.contains("/tmp/cleanup_round3_ask_excluded.txt 10\n"), read.result.stdout)
    }

    func testExecSessionStressAppLifecycleGapPreservesRunningPipeSessionState() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'lifecycle-pipe-start\\n'; sleep 0.45; printf 'lifecycle-pipe-end\\n'",
            yieldTimeMilliseconds: 250
        ))

        let sessionID = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.result.stdout, "lifecycle-pipe-start\n")

        try? await Task.sleep(nanoseconds: 200_000_000)
        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 1
        ))

        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertEqual(poll.result.stdout, "lifecycle-pipe-end\n")
        XCTAssertEqual(poll.result.stderr, "")
    }

    #if os(macOS)
    func testExecSessionStressHostPythonPipeSessionWaitsForLiveStdin() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for host-process Python exec-session tests.")
        }
        let rootURL = makeTemporaryURL("host-python-live-stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL,
                temporaryDirectoryURL: rootURL.appendingPathComponent(".msp-python", isDirectory: true)
            )))
        let bridge = shell.execCommandBridge()
        let command = """
        python3 -u -c 'import sys,time; print("READY", flush=True); line=sys.stdin.readline().strip(); print("GOT:" + line, flush=True); time.sleep(0.1); print("DONE", flush=True)'
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            yieldTimeMilliseconds: 250
        ))
        var sessionID: Int? = try XCTUnwrap(start.runningSessionID)
        var transcript = start.result.stdout
        XCTAssertEqual(start.exitCode, nil)
        XCTAssertEqual(start.result.stderr, "")
        for _ in 0..<8 where !Self.containsLine("READY", in: transcript) {
            let activeSessionID = try XCTUnwrap(sessionID, transcript)
            let poll = await bridge.readSession(
                sessionID: activeSessionID,
                waitMilliseconds: 250
            )
            transcript += poll.result.stdout
            XCTAssertEqual(poll.result.stderr, "")
            sessionID = poll.runningSessionID
        }
        XCTAssertTrue(Self.containsLine("READY", in: transcript), transcript)
        XCTAssertFalse(transcript.contains("GOT:"), transcript)
        let activeSessionID = try XCTUnwrap(sessionID, transcript)

        let final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: activeSessionID,
            chars: "hello from exec session\n",
            yieldTimeMilliseconds: 1_000
        ))
        transcript += final.result.stdout

        XCTAssertNil(final.runningSessionID)
        XCTAssertEqual(final.exitCode, 0, transcript + final.result.stderr)
        XCTAssertEqual(final.result.stderr, "")
        XCTAssertTrue(Self.containsLine("GOT:hello from exec session", in: transcript), transcript)
        XCTAssertTrue(Self.containsLine("DONE", in: transcript), transcript)
    }

    func testExecSessionTTYFallbackUsesPipeSessionWhenNativePTYUnavailable() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for host-process Python exec-session tests.")
        }
        let rootURL = makeTemporaryURL("tty-pipe-fallback-python-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL,
                temporaryDirectoryURL: rootURL.appendingPathComponent(".msp-python", isDirectory: true)
            )))
        let transport = ModelShellProxyExecSessionTransport(
            shell: shell,
            nativePTYAvailable: { false }
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: MSPExecCommandSessionCoordinator(
            transport: transport
        ))

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -i -q",
            tty: true,
            yieldTimeMilliseconds: 250
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID, start.result.stderr)
        XCTAssertEqual(start.exitCode, nil)
        XCTAssertEqual(start.result.stderr, "")

        let final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "print(\"TTY_PIPE_FALLBACK_READY\")\nprint(6 * 7)\nexit()\n",
            yieldTimeMilliseconds: 1_000
        ))
        var transcript = start.result.stdout + final.result.stdout
        var stderr = final.result.stderr
        var runningSessionID = final.runningSessionID
        var exitCode = final.exitCode

        for _ in 0..<20 where runningSessionID != nil {
            let activeSessionID = try XCTUnwrap(runningSessionID, transcript + stderr)
            let poll = await bridge.readSession(
                sessionID: activeSessionID,
                waitMilliseconds: 250
            )
            transcript += poll.result.stdout
            stderr += poll.result.stderr
            runningSessionID = poll.runningSessionID
            exitCode = poll.exitCode
        }
        if let runningSessionID {
            _ = await bridge.terminateSession(runningSessionID)
        }

        XCTAssertNil(runningSessionID)
        XCTAssertEqual(exitCode, 0, transcript + stderr)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(Self.containsLine("TTY_PIPE_FALLBACK_READY", in: transcript), transcript)
        XCTAssertTrue(Self.containsLine("42", in: transcript), transcript)
    }

    #endif

    private struct PipeStressResult {
        var index: Int
        var output: String
        var stderr: String
        var exitCode: Int32?
        var runningSessionID: Int?
    }

    private static func positiveEnvironmentInt(
        _ name: String,
        defaultValue: Int
    ) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let parsed = Int(rawValue),
              parsed > 0 else {
            return defaultValue
        }
        return parsed
    }

    #if os(macOS)
    private static func containsLine(_ line: String, in transcript: String) -> Bool {
        transcript.contains(line + "\n") || transcript.contains(line + "\r\n")
    }
    #endif
}

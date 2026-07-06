import Foundation
import XCTest
import MSPAgentBridge
@testable import ModelShellProxy

#if os(macOS)
import Darwin

final class ModelShellProxyExecSessionPTYStressTests: ModelShellProxyIntegrationTestCase {
    func testExecSessionStressAppLifecycleGapPreservesRunningPTYSessionState() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'lifecycle-pty-start\\n'; sleep 0.45; printf 'lifecycle-pty-end\\n'",
            tty: true,
            yieldTimeMilliseconds: 250
        ))

        let sessionID = try XCTUnwrap(start.runningSessionID)
        var transcript = start.result.stdout
        XCTAssertTrue(
            transcript.contains("lifecycle-pty-start\r\n")
                || transcript.contains("lifecycle-pty-start\n"),
            transcript
        )

        try? await Task.sleep(nanoseconds: 200_000_000)
        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 1
        ))
        transcript += poll.result.stdout

        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertTrue(
            transcript.contains("lifecycle-pty-end\r\n")
                || transcript.contains("lifecycle-pty-end\n"),
            transcript
        )
        XCTAssertEqual(poll.result.stderr, "")
    }

    func testExecSessionStressPTYLargeOutputTenMegabytes() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let byteCount = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_LARGE_OUTPUT_BYTES",
            defaultValue: 10 * 1024 * 1024
        )
        let command = """
        printf 'BEGIN\\n'
        if command -v python3 >/dev/null 2>&1; then
          python3 -c 'import sys; sys.stdout.write("X" * \(byteCount)); sys.stdout.flush()'
        else
          perl -e 'print "X" x \(byteCount)'
        fi
        printf '\\nEND\\n'
        """

        var read = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 1_000
        ))
        var output = read.result.stdoutData
        var pollCount = 0
        while let sessionID = read.runningSessionID, pollCount < 30 {
            read = await bridge.readSession(sessionID: sessionID, waitMilliseconds: 1_000)
            output.append(read.result.stdoutData)
            pollCount += 1
        }

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertGreaterThan(output.count, 0)
        let prefix = String(decoding: output.prefix(64), as: UTF8.self)
        let suffix = String(decoding: output.suffix(64), as: UTF8.self)
        XCTAssertTrue(prefix.contains("BEGIN\r\n") || prefix.contains("BEGIN\n"), prefix)
        XCTAssertTrue(suffix.contains("END\r\n") || suffix.contains("END\n"), suffix)
    }

    func testExecSessionStressPTYOutputRetentionCapDoesNotBreakSubsequentReads() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let retainedByteLimit = Self.nonNegativeEnvironmentInt(
            "MSP_EXEC_SESSION_OUTPUT_MAX_BYTES",
            defaultValue: 1024 * 1024
        )
        guard retainedByteLimit >= 64 else {
            throw XCTSkip("retained output cap must be at least 64 bytes for ring-retention sentinel assertions.")
        }
        let overflowByteCount = max(
            retainedByteLimit * 2,
            Self.positiveEnvironmentInt(
                "MSP_EXEC_SESSION_STRESS_RING_OUTPUT_BYTES",
                defaultValue: 2 * 1024 * 1024
            )
        )
        let command = """
        printf 'RING-BEGIN\\n'
        if command -v python3 >/dev/null 2>&1; then
          python3 -c 'import sys; sys.stdout.write("Y" * \(overflowByteCount)); sys.stdout.flush()'
        else
          perl -e 'print "Y" x \(overflowByteCount)'
        fi
        printf '\\nRING-AFTER-OVERFLOW\\n'
        sleep 0.45
        printf 'RING-LATE-SENTINEL\\n'
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 350
        ))
        _ = try XCTUnwrap(start.runningSessionID)
        XCTAssertLessThanOrEqual(
            start.result.stdoutData.count,
            max(retainedByteLimit, 1),
            "initial read should be bounded by the retained output cap"
        )
        let initialOutput = start.result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(initialOutput.contains("RING-BEGIN\n"), Self.shortDiagnostic(initialOutput))

        var read = start
        var transcript = initialOutput
        var sawSubsequentOutput = false
        var pollCount = 0
        while let runningSessionID = read.runningSessionID, pollCount < 8 {
            read = await bridge.readSession(sessionID: runningSessionID, waitMilliseconds: 1_000)
            XCTAssertLessThanOrEqual(
                read.result.stdoutData.count,
                retainedByteLimit,
                "poll read should be bounded by the retained output cap"
            )
            let output = read.result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
            sawSubsequentOutput = sawSubsequentOutput || !output.isEmpty
            transcript += output
            pollCount += 1
        }

        XCTAssertNil(read.runningSessionID, "session did not complete after \(pollCount) polls")
        XCTAssertEqual(read.exitCode, 0, Self.shortDiagnostic(transcript))
        XCTAssertTrue(sawSubsequentOutput, "expected at least one non-empty poll after the initial yield")
        XCTAssertTrue(
            transcript.contains("RING-LATE-SENTINEL\n"),
            Self.shortDiagnostic(transcript)
        )
    }

    func testExecSessionPTYScrubsHostPythonHomeFromNativeShellEnvironment() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for native PTY Python environment tests.")
        }

        let previousPythonHome = getenv("PYTHONHOME").map { String(cString: $0) }
        let poisonedPythonHome = "/definitely/not/a/python/home"
        Darwin.setenv("PYTHONHOME", poisonedPythonHome, 1)
        defer {
            if let previousPythonHome {
                Darwin.setenv("PYTHONHOME", previousPythonHome, 1)
            } else {
                Darwin.unsetenv("PYTHONHOME")
            }
        }

        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        var read = await bridge.runSession(MSPExecCommandCall(
            cmd: "/usr/bin/python3 -c 'import sys; print(\"PYTHON_OK\"); print(sys.executable)'",
            tty: true,
            yieldTimeMilliseconds: 1_000
        ))
        var transcript = read.result.stdout
        var pollCount = 0
        while let sessionID = read.runningSessionID, pollCount < 5 {
            read = await bridge.readSession(sessionID: sessionID, waitMilliseconds: 1_000)
            transcript += read.result.stdout
            pollCount += 1
        }

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0, transcript)
        XCTAssertTrue(transcript.contains("PYTHON_OK"), transcript)
        XCTAssertFalse(transcript.contains(poisonedPythonHome), transcript)
    }

    func testExecSessionPTYRequestsBasicPythonREPL() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'PYTHON_BASIC_REPL=%s\\n' \"$PYTHON_BASIC_REPL\"",
            tty: true,
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertTrue(read.result.stdout.contains("PYTHON_BASIC_REPL=1"), read.result.stdout)
    }

    func testExecSessionPTYUsesLinuxLikeEnvironmentAndHidesHostPaths() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printenv | sort",
            tty: true,
            yieldTimeMilliseconds: 1_000
        ))

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        let output = read.result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(output.contains("HOME=/tmp\n"), output)
        XCTAssertTrue(output.contains("PWD=/\n"), output)
        XCTAssertTrue(output.contains("PYTHON_HISTORY=/tmp/.python_history\n"), output)
        XCTAssertTrue(output.contains("TMPDIR=/tmp\n"), output)
        XCTAssertTrue(output.contains("PYTHON_BASIC_REPL=1\n"), output)
        XCTAssertFalse(output.contains("/Users/"), output)
        XCTAssertFalse(output.contains("/Volumes/"), output)
        XCTAssertFalse(output.contains("/private/var/"), output)
        XCTAssertFalse(output.contains("CoreSimulator"), output)
        XCTAssertFalse(output.contains("Containers/Data/Application"), output)
        XCTAssertFalse(output.contains("SIMULATOR_"), output)
        XCTAssertFalse(output.contains("IPHONE_"), output)
        XCTAssertFalse(output.contains("XPC_"), output)
        XCTAssertFalse(output.contains("MSP_PYTHON_"), output)
    }

    func testExecSessionPTYInteractivePythonExitDoesNotLeakReadOnlyHistoryError() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -i -q",
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        var exit = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "exit()\n",
            yieldTimeMilliseconds: 1_000
        ))
        var transcript = start.result.stdout + exit.result.stdout
        var pollCount = 0
        while let runningSessionID = exit.runningSessionID, pollCount < 5 {
            exit = await bridge.readSession(sessionID: runningSessionID, waitMilliseconds: 1_000)
            transcript += exit.result.stdout
            pollCount += 1
        }

        XCTAssertNil(exit.runningSessionID, transcript + exit.result.stderr)
        XCTAssertEqual(exit.exitCode, 0, transcript + exit.result.stderr)
        XCTAssertFalse(transcript.contains("Read-only file system"), transcript)
        XCTAssertFalse(transcript.contains("Traceback"), transcript)
        XCTAssertFalse(transcript.contains("Exception ignored in atexit callback"), transcript)
    }

    func testExecSessionStressPTYHighFrequencyStdinWrites() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let writeCount = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_STDIN_WRITES",
            defaultValue: 24
        )
        let command = """
        printf 'READY\\n'
        count=0
        while IFS= read -r line; do
          [ "$line" = END ] && break
          count=$((count + 1))
        done
        printf 'COUNT:%s\\n' "$count"
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        var transcript = start.result.stdout
        XCTAssertTrue(transcript.contains("READY\r\n") || transcript.contains("READY\n"), transcript)

        for index in 0..<writeCount {
            let write = await bridge.writeStdin(MSPWriteStdinCall(
                sessionID: sessionID,
                chars: "payload-\(index)\n",
                yieldTimeMilliseconds: 1
            ))
            transcript += write.result.stdout
            XCTAssertEqual(write.runningSessionID, sessionID)
        }

        let final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "END\n",
            yieldTimeMilliseconds: 1_000
        ))
        transcript += final.result.stdout

        XCTAssertNil(final.runningSessionID)
        XCTAssertEqual(final.exitCode, 0)
        XCTAssertTrue(
            transcript.contains("COUNT:\(writeCount)\r\n") || transcript.contains("COUNT:\(writeCount)\n"),
            transcript
        )
    }

    func testExecSessionPTYUsesLinuxCanonicalLimitForLongPaste() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let longLine = String(repeating: "a", count: 12_000)
        let command = """
        printf 'READY\\n'
        IFS= read -r line
        printf 'len=%s\\n' "${#line}"
        echo FINISHED
        """

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        var read = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: longLine + "\n",
            yieldTimeMilliseconds: 1_000
        ))
        var transcript = start.result.stdout + read.result.stdout
        var pollCount = 0
        while let runningSessionID = read.runningSessionID, pollCount < 10 {
            read = await bridge.readSession(sessionID: runningSessionID, waitMilliseconds: 1_000)
            transcript += read.result.stdout
            pollCount += 1
        }

        XCTAssertNil(read.runningSessionID, Self.shortDiagnostic(transcript))
        XCTAssertEqual(read.exitCode, 0, Self.shortDiagnostic(transcript))
        XCTAssertEqual(
            transcript.replacingOccurrences(of: "\r\n", with: "\n"),
            "READY\n\(longLine)\nlen=4095\nFINISHED\n"
        )
    }

    func testExecSessionStressPTYTerminateKillsProcessGroupAndClosesSession() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let command = """
        printf 'READY\\n'
        sh -c 'trap "" TERM; sleep 60' &
        child=$!
        printf 'CHILD:%s\\n' "$child"
        wait "$child"
        """

        var start = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 300
        ))
        let sessionID = try XCTUnwrap(start.runningSessionID)
        var transcript = start.result.stdout
        if Self.childPID(in: transcript) == nil {
            start = await bridge.readSession(sessionID: sessionID, waitMilliseconds: 500)
            transcript += start.result.stdout
        }
        let childPID = try XCTUnwrap(Self.childPID(in: transcript), transcript)

        let terminated = await bridge.terminateSession(sessionID)
        XCTAssertNil(terminated.runningSessionID)
        XCTAssertEqual(terminated.signal, SIGTERM)
        XCTAssertTrue(terminated.result.stderr.contains("terminated"))

        let childExited = await Self.waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !Self.processExists(childPID)
        }
        XCTAssertTrue(childExited, "child process \(childPID) survived terminate")

        let inactive = await bridge.readSession(sessionID: sessionID, waitMilliseconds: 0)
        XCTAssertNil(inactive.runningSessionID)
        XCTAssertEqual(inactive.exitCode, 1)
        XCTAssertTrue(inactive.result.stderr.contains("inactive session"))
    }

    func testExecSessionStressPTYResourceUseReturnsToIdleAfterRepeatedSessions() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        let iterationCount = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_RESOURCE_ITERATIONS",
            defaultValue: 24
        )
        let allowedFDGrowth = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_ALLOWED_FD_GROWTH",
            defaultValue: 4
        )
        let allowedResidentMemoryGrowthBytes = Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_ALLOWED_MEMORY_GROWTH_BYTES",
            defaultValue: 64 * 1024 * 1024
        )
        let allowedIdleCPUSeconds = Double(Self.positiveEnvironmentInt(
            "MSP_EXEC_SESSION_STRESS_ALLOWED_IDLE_CPU_MILLISECONDS",
            defaultValue: 250
        )) / 1_000

        _ = await Self.runPTYCommand(
            "printf 'resource-warmup\\n'",
            bridge: bridge
        )
        let baseline = Self.ResourceSnapshot.capture()

        for index in 0..<iterationCount {
            let transcript = await Self.runPTYCommand(
                "printf 'resource-\(index)-start\\n'; sleep 0.02; printf 'resource-\(index)-end\\n'",
                bridge: bridge
            )
            XCTAssertTrue(
                transcript.normalizedOutput.contains("resource-\(index)-start\n"),
                transcript.normalizedOutput
            )
            XCTAssertTrue(
                transcript.normalizedOutput.contains("resource-\(index)-end\n"),
                transcript.normalizedOutput
            )
            XCTAssertEqual(transcript.exitCode, 0, transcript.normalizedOutput)
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterWork = Self.ResourceSnapshot.capture()
        let idleStart = Self.ResourceSnapshot.capture()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let idleEnd = Self.ResourceSnapshot.capture()

        let fdGrowth = afterWork.openFileDescriptorCount - baseline.openFileDescriptorCount
        let residentMemoryGrowth = Int64(afterWork.residentMemoryBytes) - Int64(baseline.residentMemoryBytes)
        let idleCPUSeconds = idleEnd.cpuSeconds - idleStart.cpuSeconds

        XCTAssertLessThanOrEqual(
            fdGrowth,
            allowedFDGrowth,
            "fd leak budget exceeded: baseline=\(baseline.openFileDescriptorCount), after=\(afterWork.openFileDescriptorCount)"
        )
        XCTAssertLessThanOrEqual(
            max(0, residentMemoryGrowth),
            Int64(allowedResidentMemoryGrowthBytes),
            "resident memory growth exceeded: baseline=\(baseline.residentMemoryBytes), after=\(afterWork.residentMemoryBytes)"
        )
        XCTAssertLessThanOrEqual(
            idleCPUSeconds,
            allowedIdleCPUSeconds,
            "idle CPU did not return to budget after PTY sessions"
        )
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

    private static func nonNegativeEnvironmentInt(
        _ name: String,
        defaultValue: Int
    ) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let parsed = Int(rawValue),
              parsed >= 0 else {
            return defaultValue
        }
        return parsed
    }

    private static func shortDiagnostic(_ text: String, limit: Int = 512) -> String {
        guard text.count > limit * 2 else { return text }
        return String(text.prefix(limit)) + "\n...[diagnostic truncated]...\n" + String(text.suffix(limit))
    }

    private static func childPID(in text: String) -> pid_t? {
        guard let range = text.range(of: #"CHILD:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        guard let pid = Int32(match.dropFirst("CHILD:".count)) else {
            return nil
        }
        return pid_t(pid)
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private struct PTYTranscript {
        var normalizedOutput: String
        var exitCode: Int32?
    }

    private static func runPTYCommand(
        _ command: String,
        bridge: MSPExecCommandBridge
    ) async -> PTYTranscript {
        var read = await bridge.runSession(MSPExecCommandCall(
            cmd: command,
            tty: true,
            yieldTimeMilliseconds: 250
        ))
        var output = read.result.stdout
        var pollCount = 0
        while let sessionID = read.runningSessionID, pollCount < 20 {
            read = await bridge.readSession(sessionID: sessionID, waitMilliseconds: 500)
            output += read.result.stdout
            pollCount += 1
        }
        return PTYTranscript(
            normalizedOutput: output.replacingOccurrences(of: "\r\n", with: "\n"),
            exitCode: read.exitCode ?? read.result.exitCode
        )
    }

    private struct ResourceSnapshot {
        var openFileDescriptorCount: Int
        var residentMemoryBytes: UInt64
        var cpuSeconds: Double

        static func capture() -> ResourceSnapshot {
            ResourceSnapshot(
                openFileDescriptorCount: openFileDescriptorCount(),
                residentMemoryBytes: residentMemoryBytes(),
                cpuSeconds: cpuSeconds()
            )
        }

        private static func openFileDescriptorCount() -> Int {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
            return entries.filter { Int($0) != nil }.count
        }

        private static func residentMemoryBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        reboundPointer,
                        &count
                    )
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        }

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else {
                return 0
            }
            return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }

        private static func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
    }
}
#endif

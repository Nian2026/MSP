import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyDebian12PTYOracleConformanceTests: XCTestCase {
    func testMSPV1Debian12PTYOracleConformanceRunner() async throws {
        guard Debian12OracleTestSupport.environmentFlag("MSP_RUN_DEBIAN12_PTY_ORACLE") else {
            throw XCTSkip("Set MSP_RUN_DEBIAN12_PTY_ORACLE=1 to execute Debian 12 PTY oracle cases.")
        }

        let fixture = try Debian12OracleTestSupport.ptyFixture()
        let selectedCases = Self.selectedPTYCases(from: fixture.cases)
        XCTAssertFalse(selectedCases.isEmpty)

        switch Self.ptyOracleBackend() {
        case "linux-external":
            try Self.runExternalLinuxPTYOracleRunner()
            return
        case "macos-native", "":
            if Debian12OracleTestSupport.environmentFlag("MSP_DEBIAN12_PTY_ORACLE_REQUIRE_LINUX") {
                XCTFail("Debian 12 PTY oracle requires MSP_DEBIAN12_PTY_ORACLE_BACKEND=linux-external; macOS native PTY is a smoke backend only.")
                return
            }
        default:
            XCTFail("Unsupported MSP_DEBIAN12_PTY_ORACLE_BACKEND: \(Self.ptyOracleBackend())")
            return
        }

        var failures: [Debian12PTYOracleCaseFailure] = []
        for testCase in selectedCases {
            do {
                let actual = try await runPTYOracleCase(testCase)
                let expected = Debian12PTYOracleObservedResult(
                    streamB64: testCase.expected.streamB64,
                    exitCode: testCase.expected.exitCode,
                    signal: testCase.expected.signal
                )
                let mismatch = Debian12PTYOracleMismatch(
                    streamMatches: actual.streamB64 == expected.streamB64,
                    exitCodeMatches: actual.exitCode == expected.exitCode,
                    signalMatches: actual.signal == expected.signal
                )
                if !mismatch.isPassing {
                    failures.append(Debian12PTYOracleCaseFailure(
                        id: testCase.id,
                        command: testCase.commandLine,
                        mismatch: mismatch,
                        expected: expected,
                        actual: actual,
                        diagnostics: Debian12PTYOracleFailureDiagnostics(
                            stream: Debian12OracleTestSupport.byteComparison(
                                expected: testCase.expected.streamData,
                                actual: actual.streamData
                            )
                        )
                    ))
                }
            } catch {
                let errorData = Data(String(describing: error).utf8)
                failures.append(Debian12PTYOracleCaseFailure(
                    id: testCase.id,
                    command: testCase.commandLine,
                    mismatch: Debian12PTYOracleMismatch(
                        streamMatches: false,
                        exitCodeMatches: false,
                        signalMatches: false
                    ),
                    expected: Debian12PTYOracleObservedResult(
                        streamB64: testCase.expected.streamB64,
                        exitCode: testCase.expected.exitCode,
                        signal: testCase.expected.signal
                    ),
                    actual: Debian12PTYOracleObservedResult(
                        streamB64: errorData.base64EncodedString(),
                        exitCode: -1,
                        signal: nil
                    ),
                    diagnostics: Debian12PTYOracleFailureDiagnostics(
                        stream: Debian12OracleTestSupport.byteComparison(
                            expected: testCase.expected.streamData,
                            actual: errorData
                        )
                    )
                ))
            }
        }

        let reportURL = try writePTYReport(
            selectedCases: selectedCases,
            failures: failures
        )
        guard failures.isEmpty else {
            XCTFail(Self.ptyFailureSummary(failures: failures, reportURL: reportURL))
            return
        }
    }

    private static func selectedPTYCases(from cases: [Debian12PTYOracleCase]) -> [Debian12PTYOracleCase] {
        let environment = ProcessInfo.processInfo.environment
        var selected = cases
        if let caseList = environment["MSP_DEBIAN12_PTY_ORACLE_CASES"], !caseList.isEmpty {
            let ids = Debian12OracleTestSupport.commaSeparatedSet(caseList)
            selected = selected.filter { ids.contains($0.id) }
        } else if let singleCase = environment["MSP_DEBIAN12_PTY_ORACLE_CASE"], !singleCase.isEmpty {
            selected = selected.filter { $0.id == singleCase }
        }
        if let limitText = environment["MSP_DEBIAN12_PTY_ORACLE_LIMIT"],
           let limit = Int(limitText),
           limit >= 0 {
            selected = Array(selected.prefix(limit))
        }
        return selected
    }

    private static func ptyOracleBackend() -> String {
        ProcessInfo.processInfo.environment["MSP_DEBIAN12_PTY_ORACLE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "macos-native"
    }

    private static func runExternalLinuxPTYOracleRunner() throws {
        let packageRoot = try Debian12OracleTestSupport.packageRoot()
        let runnerPath = ProcessInfo.processInfo.environment["MSP_DEBIAN12_PTY_ORACLE_RUNNER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runnerURL = runnerPath.flatMap { value -> URL? in
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("/") {
                return URL(fileURLWithPath: value)
            }
            return packageRoot.appendingPathComponent(value)
        } ?? packageRoot
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_debian12_pty_oracle_container.sh")
        guard FileManager.default.isExecutableFile(atPath: runnerURL.path) else {
            throw Debian12OracleTestSupport.runnerError("Debian PTY oracle runner is not executable: \(runnerURL.path)")
        }

        let reportURL = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("msp-conformance")
            .appendingPathComponent("debian12-pty-linux-report.json")
        var environment = ProcessInfo.processInfo.environment
        environment["MSP_DEBIAN12_PTY_ORACLE_REPORT"] = reportURL.path

        let process = Process()
        process.executableURL = runnerURL
        process.currentDirectoryURL = packageRoot
        process.environment = environment
        process.arguments = ["--require-linux"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        guard process.terminationStatus == 0 else {
            throw Debian12OracleTestSupport.runnerError("""
            Debian PTY oracle external runner failed with exit code \(process.terminationStatus).
            Runner: \(runnerURL.path)
            Report: \(reportURL.path)
            STDOUT:
            \(stdout)
            STDERR:
            \(stderr)
            """)
        }
    }

    private func runPTYOracleCase(_ testCase: Debian12PTYOracleCase) async throws -> Debian12PTYOracleObservedResult {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        let bridge = shell.execCommandBridge()
        var stream = Data()
        var exitCode: Int32?
        var signal: Int32?

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: testCase.commandLine,
            tty: true,
            yieldTimeMilliseconds: 250
        ))
        Self.appendPTYOutput(from: start, to: &stream)
        var sessionID = start.runningSessionID
        if sessionID == nil {
            exitCode = start.exitCode
            signal = start.signal
        }

        for action in testCase.actions {
            guard let currentSessionID = sessionID else {
                break
            }
            if action.sleepBeforeMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(action.sleepBeforeMs) * 1_000_000)
            }
            let write = await bridge.writeStdin(MSPWriteStdinCall(
                sessionID: currentSessionID,
                stdinData: action.bytesData,
                yieldTimeMilliseconds: action.readTimeoutMilliseconds
            ))
            Self.appendPTYOutput(from: write, to: &stream)
            sessionID = write.runningSessionID
            if sessionID == nil {
                exitCode = write.exitCode
                signal = write.signal
            }
        }

        var remainingPolls = 10
        while let currentSessionID = sessionID, remainingPolls > 0 {
            remainingPolls -= 1
            let poll = await bridge.readSession(
                sessionID: currentSessionID,
                waitMilliseconds: 500
            )
            Self.appendPTYOutput(from: poll, to: &stream)
            sessionID = poll.runningSessionID
            if sessionID == nil {
                exitCode = poll.exitCode
                signal = poll.signal
            }
        }

        if let currentSessionID = sessionID {
            let terminated = await bridge.terminateSession(currentSessionID)
            Self.appendPTYOutput(from: terminated, to: &stream)
            exitCode = terminated.exitCode
            signal = terminated.signal
        }

        return Debian12PTYOracleObservedResult(
            streamB64: stream.base64EncodedString(),
            exitCode: exitCode,
            signal: signal
        )
    }

    private static func appendPTYOutput(
        from read: MSPExecCommandSessionRead,
        to stream: inout Data
    ) {
        stream.append(read.result.stdoutData)
        if !read.result.stderrData.isEmpty {
            stream.append(read.result.stderrData)
        }
    }

    private func writePTYReport(
        selectedCases: [Debian12PTYOracleCase],
        failures: [Debian12PTYOracleCaseFailure]
    ) throws -> URL {
        let packageRoot = try Debian12OracleTestSupport.packageRoot()
        let reportURL = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("msp-conformance")
            .appendingPathComponent("debian12-pty-report.json")
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let report = Debian12PTYOracleRunReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            runnerBackend: Self.ptyRunnerBackendDescription(),
            runnerPlatform: Self.runnerPlatformDescription(),
            selectedCaseCount: selectedCases.count,
            passedCaseCount: selectedCases.count - failures.count,
            failedCaseCount: failures.count,
            passedCaseIDs: selectedCases
                .filter { testCase in !failures.contains { $0.id == testCase.id } }
                .map(\.id),
            failedCaseIDs: failures.map(\.id),
            failures: failures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)
        return reportURL
    }

    private static func ptyRunnerBackendDescription() -> String {
        if ptyOracleBackend() == "linux-external" {
            return "External Linux/Debian PTY oracle runner"
        }
        #if os(macOS)
        return "ModelShellProxy native macOS PTY backend"
        #else
        return "ModelShellProxy native PTY backend unavailable"
        #endif
    }

    private static func runnerPlatformDescription() -> String {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let family = "macOS"
        #elseif os(Linux)
        let family = "Linux"
        #else
        let family = "unknown"
        #endif
        return "\(family) \(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
    }

    private static func ptyFailureSummary(
        failures: [Debian12PTYOracleCaseFailure],
        reportURL: URL
    ) -> String {
        let preview = failures.prefix(8).map { failure in
            let streamOffset = failure.diagnostics.stream.firstDifferentByteOffset
                .map(String.init) ?? "none"
            return "- \(failure.id) stream=\(!failure.mismatch.streamMatches)@\(streamOffset) exit=\(!failure.mismatch.exitCodeMatches) signal=\(!failure.mismatch.signalMatches)"
        }.joined(separator: "\n")
        return """
        Debian 12 PTY oracle conformance failed: \(failures.count) case(s).
        Report: \(reportURL.path)
        \(preview)
        """
    }
}

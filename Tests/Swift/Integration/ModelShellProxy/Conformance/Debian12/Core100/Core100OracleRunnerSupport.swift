import Foundation
import ModelShellProxy
import MSPApple
import MSPPythonRuntime

extension ModelShellProxyCore100OracleConformanceTests {
    static let oracleEnvironment: [String: String] = [
        "HOME": "/",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "TZ": "UTC"
    ]

    func collectFailures(for selectedCases: [Core100OracleCase]) async -> [Core100OracleCaseFailure] {
        var failures: [Core100OracleCaseFailure] = []
        for testCase in selectedCases {
            let rootURL = makeTemporaryURL(testCase.id)
            defer { removeTemporaryURL(rootURL) }
            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o777)],
                    ofItemAtPath: rootURL.path
                )
                try prepareFixture(testCase.fixture, rootURL: rootURL)

                let result = try await runOracleCase(testCase, rootURL: rootURL)
                let failure = try Self.failureIfMismatch(
                    testCase: testCase,
                    result: result,
                    actualFileTree: snapshotFileTree(rootURL: rootURL)
                )
                if let failure {
                    failures.append(failure)
                }
            } catch {
                failures.append(Self.failureForSetupError(testCase: testCase, error: error))
            }
        }
        return failures
    }

    func writeReport(
        selectedCases: [Core100OracleCase],
        failures: [Core100OracleCaseFailure]
    ) throws -> URL {
        let packageRoot = try Self.packageRoot()
        let reportURL = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("msp-conformance")
            .appendingPathComponent("core100-noninteractive-report.json")
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let failedIDs = Set(failures.map(\.id))
        let report = Core100OracleRunReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            selectedCaseCount: selectedCases.count,
            passedCaseCount: selectedCases.count - failures.count,
            failedCaseCount: failures.count,
            selectedCommandCounts: Self.commandCounts(for: selectedCases),
            failedCommandCounts: Self.commandCounts(for: failures),
            failedLikelyLayerCounts: Dictionary(grouping: failures, by: \.likelyLayer)
                .mapValues(\.count),
            passedCaseIDs: selectedCases.filter { !failedIDs.contains($0.id) }.map(\.id),
            failedCaseIDs: failures.map(\.id),
            failures: failures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)
        return reportURL
    }

    static func failureSummary(
        failures: [Core100OracleCaseFailure],
        reportURL: URL
    ) -> String {
        let preview = failures.prefix(12).map { failure in
            let stdoutOffset = failure.diagnostics.stdout.firstDifferentByteOffset
                .map(String.init) ?? "none"
            let stderrOffset = failure.diagnostics.stderr.firstDifferentByteOffset
                .map(String.init) ?? "none"
            return "- \(failure.id) [\(failure.likelyLayer)] commands=\(failure.commands.joined(separator: ",")) stdout=\(!failure.mismatch.stdoutMatches)@\(stdoutOffset) stderr=\(!failure.mismatch.stderrMatches)@\(stderrOffset) exit=\(!failure.mismatch.exitCodeMatches) tree=\(!failure.mismatch.fileTreeMatches)"
        }.joined(separator: "\n")
        return """
        Core100 oracle conformance failed: \(failures.count) case(s).
        Report: \(reportURL.path)
        \(preview)
        """
    }

    static func shellDiagnosticProfile(
        for shell: Core100OracleShell
    ) -> MSPShellDiagnosticProfile? {
        switch shell.dialect {
        case "bash":
            return .bash(scriptName: shell.argv.first ?? "/bin/bash")
        case "dash", "sh":
            return .dash(scriptName: shell.argv.first ?? "/bin/sh")
        default:
            return nil
        }
    }

    static func likelyLayer(for result: MSPCommandResult, mismatch: Core100OracleMismatch) -> String {
        let stderr = String(decoding: result.stderrData, as: UTF8.self)
        if stderr.contains("unsupported execution form")
            || stderr.contains("syntax error")
            || stderr.contains("bad substitution") {
            return "shell_parser_or_runtime"
        }
        if stderr.contains("command not found")
            || stderr.contains("not supported")
            || stderr.contains("not implemented") {
            return "command_registry_or_external_runner"
        }
        if !mismatch.fileTreeMatches {
            return "workspace_fs_or_side_effects"
        }
        if !mismatch.stdoutMatches || !mismatch.stderrMatches || !mismatch.exitCodeMatches {
            return "command_output_or_exit_semantics"
        }
        return "unknown"
    }

    private func runOracleCase(
        _ testCase: Core100OracleCase,
        rootURL: URL
    ) async throws -> MSPCommandResult {
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let configuration = MSPConfiguration(
            workspace: workspace,
            environment: Self.oracleEnvironment,
            standardInput: testCase.standardInputData,
            standardInputClosed: false,
            shellDiagnosticProfile: Self.shellDiagnosticProfile(for: testCase.shell)
        )
        var shell = try ModelShellProxy(configuration: configuration)
            .enable(.posixCore)
#if os(macOS)
        shell = try shell.enable(.python(
            runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL
            ),
            commandNames: ["python3"]
        ))
#endif
        return await shell.run(testCase.commandLine)
    }

    private static func failureIfMismatch(
        testCase: Core100OracleCase,
        result: MSPCommandResult,
        actualFileTree: [Core100OracleFileTreeEntry]
    ) throws -> Core100OracleCaseFailure? {
        let expectedTree = fileTreeForMSPComparison(
            testCase.expectedFileTree,
            testCase: testCase
        )
        let actualTree = fileTreeForMSPComparison(actualFileTree, testCase: testCase)
        let expectedStdoutData = outputDataForMSPComparison(
            testCase.expected.stdoutData,
            testCase: testCase
        )
        let expectedStderrData = outputDataForMSPComparison(
            testCase.expected.stderrData,
            testCase: testCase
        )
        let actualStdoutData = outputDataForMSPComparison(result.stdoutData, testCase: testCase)
        let actualStderrData = outputDataForMSPComparison(result.stderrData, testCase: testCase)
        let mismatch = Core100OracleMismatch(
            stdoutMatches: !testCase.compares("stdout") || actualStdoutData == expectedStdoutData,
            stderrMatches: !testCase.compares("stderr") || actualStderrData == expectedStderrData,
            exitCodeMatches: !testCase.compares("exit_code") || result.exitCode == testCase.expected.exitCode,
            fileTreeMatches: !testCase.compares("file_tree") || actualTree == expectedTree
        )
        guard !mismatch.isPassing else {
            return nil
        }
        return Core100OracleCaseFailure(
            id: testCase.id,
            title: testCase.title,
            category: testCase.category,
            evidenceLevel: testCase.evidenceLevel,
            shellDialect: testCase.shell.dialect,
            commands: testCase.commands,
            compareFields: testCase.compareFields,
            commandLine: testCase.commandLine,
            mismatch: mismatch,
            likelyLayer: likelyLayer(for: result, mismatch: mismatch),
            expected: Core100OracleObservedResult(
                stdoutB64: expectedStdoutData.base64EncodedString(),
                stderrB64: expectedStderrData.base64EncodedString(),
                exitCode: testCase.expected.exitCode,
                fileTree: expectedTree
            ),
            actual: Core100OracleObservedResult(
                stdoutB64: actualStdoutData.base64EncodedString(),
                stderrB64: actualStderrData.base64EncodedString(),
                exitCode: result.exitCode,
                fileTree: actualTree
            ),
            diagnostics: Core100OracleFailureDiagnostics(
                stdout: byteComparison(expected: expectedStdoutData, actual: actualStdoutData),
                stderr: byteComparison(expected: expectedStderrData, actual: actualStderrData)
            )
        )
    }

    private static func failureForSetupError(
        testCase: Core100OracleCase,
        error: Error
    ) -> Core100OracleCaseFailure {
        let errorData = Data(String(describing: error).utf8)
        return Core100OracleCaseFailure(
            id: testCase.id,
            title: testCase.title,
            category: testCase.category,
            evidenceLevel: testCase.evidenceLevel,
            shellDialect: testCase.shell.dialect,
            commands: testCase.commands,
            compareFields: testCase.compareFields,
            commandLine: testCase.commandLine,
            mismatch: Core100OracleMismatch(
                stdoutMatches: false,
                stderrMatches: false,
                exitCodeMatches: false,
                fileTreeMatches: false
            ),
            likelyLayer: "runner_or_fixture_setup",
            expected: Core100OracleObservedResult(
                stdoutB64: testCase.expected.stdoutB64,
                stderrB64: testCase.expected.stderrB64,
                exitCode: testCase.expected.exitCode,
                fileTree: testCase.expectedFileTree
            ),
            actual: Core100OracleObservedResult(
                stdoutB64: "",
                stderrB64: errorData.base64EncodedString(),
                exitCode: -1,
                fileTree: []
            ),
            diagnostics: Core100OracleFailureDiagnostics(
                stdout: byteComparison(expected: testCase.expected.stdoutData, actual: Data()),
                stderr: byteComparison(expected: testCase.expected.stderrData, actual: errorData)
            )
        )
    }

    private func makeTemporaryURL(_ name: String) -> URL {
        mspConformanceTemporaryURL(
            suiteName: "ModelShellProxyCore100OracleConformanceTests",
            name: "\(name)-\(UUID().uuidString)"
        )
    }

    private func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func commandCounts(for cases: [Core100OracleCase]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for testCase in cases {
            for command in testCase.commands {
                counts[command, default: 0] += 1
            }
        }
        return counts
    }

    private static func commandCounts(for failures: [Core100OracleCaseFailure]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for failure in failures {
            for command in failure.commands {
                counts[command, default: 0] += 1
            }
        }
        return counts
    }
}

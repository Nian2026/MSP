import Foundation
import XCTest
import ModelShellProxy
import MSPApple

final class ModelShellProxyDebian12OracleConformanceTests: XCTestCase {
    func testMSPV1Debian12OracleNoninteractiveConformanceRunner() async throws {
        guard Debian12OracleTestSupport.environmentFlag("MSP_RUN_DEBIAN12_ORACLE") else {
            throw XCTSkip("Set MSP_RUN_DEBIAN12_ORACLE=1 to execute Debian 12 oracle cases.")
        }

        let fixture = try Debian12OracleTestSupport.noninteractiveFixture()
        let selectedCases = Self.selectedCases(from: fixture.cases)
        XCTAssertFalse(selectedCases.isEmpty)

        var failures: [Debian12OracleCaseFailure] = []
        for testCase in selectedCases {
            let rootURL = Debian12OracleTestSupport.makeTemporaryURL(
                suiteName: "ModelShellProxyDebian12OracleConformanceTests",
                name: testCase.id
            )
            defer { Debian12OracleTestSupport.removeTemporaryURL(rootURL) }
            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try Debian12OracleWorkspaceFixtureSupport.prepareFixture(testCase.fixture, rootURL: rootURL)

                let workspace = try MSPAppleWorkspace(rootURL: rootURL)
                let configuration = MSPConfiguration(
                    workspace: workspace,
                    standardInput: testCase.standardInputData,
                    standardInputClosed: false
                )
                let shell = try Debian12OracleRuntimeSupport.makeShell(
                    configuration: configuration,
                    rootURL: rootURL
                )
                let result = await shell.run(testCase.mspCommandLine)
                let actualTree = try Debian12OracleWorkspaceFixtureSupport.snapshotFileTree(rootURL: rootURL)
                let expectedStdoutData = Debian12OracleTestSupport.expectedOutputDataForMSPComparison(
                    testCase.expected.stdoutData,
                    caseCommandName: testCase.shellCommandName
                )
                let expectedStderrData = Debian12OracleTestSupport.expectedOutputDataForMSPComparison(
                    testCase.expected.stderrData,
                    caseCommandName: testCase.shellCommandName
                )

                let mismatch = Debian12OracleMismatch(
                    stdoutMatches: result.stdoutData == expectedStdoutData,
                    stderrMatches: result.stderrData == expectedStderrData,
                    exitCodeMatches: result.exitCode == testCase.expected.exitCode,
                    fileTreeMatches: actualTree == testCase.expectedFileTree
                )
                if !mismatch.isPassing {
                    failures.append(
                        Debian12OracleCaseFailure(
                            id: testCase.id,
                            category: testCase.category,
                            evidenceLevel: testCase.evidenceLevel,
                            command: testCase.scriptText,
                            mismatch: mismatch,
                            likelyLayer: likelyLayer(for: result, mismatch: mismatch),
                            expected: Debian12OracleObservedResult(
                                stdoutB64: testCase.expected.stdoutB64,
                                stderrB64: testCase.expected.stderrB64,
                                exitCode: testCase.expected.exitCode,
                                fileTree: testCase.expectedFileTree
                            ),
                            actual: Debian12OracleObservedResult(
                                stdoutB64: result.stdoutData.base64EncodedString(),
                                stderrB64: result.stderrData.base64EncodedString(),
                                exitCode: result.exitCode,
                                fileTree: actualTree
                            ),
                            diagnostics: Debian12OracleFailureDiagnostics(
                                stdout: Debian12OracleTestSupport.byteComparison(
                                    expected: expectedStdoutData,
                                    actual: result.stdoutData
                                ),
                                stderr: Debian12OracleTestSupport.byteComparison(
                                    expected: expectedStderrData,
                                    actual: result.stderrData
                                )
                            )
                        )
                    )
                }
            } catch {
                let errorData = Data(String(describing: error).utf8)
                failures.append(
                    Debian12OracleCaseFailure(
                        id: testCase.id,
                        category: testCase.category,
                        evidenceLevel: testCase.evidenceLevel,
                        command: testCase.scriptText,
                        mismatch: Debian12OracleMismatch(
                            stdoutMatches: false,
                            stderrMatches: false,
                            exitCodeMatches: false,
                            fileTreeMatches: false
                        ),
                        likelyLayer: "runner_or_fixture_setup",
                        expected: Debian12OracleObservedResult(
                            stdoutB64: testCase.expected.stdoutB64,
                            stderrB64: testCase.expected.stderrB64,
                            exitCode: testCase.expected.exitCode,
                            fileTree: testCase.expectedFileTree
                        ),
                        actual: Debian12OracleObservedResult(
                            stdoutB64: "",
                            stderrB64: errorData.base64EncodedString(),
                            exitCode: -1,
                            fileTree: []
                        ),
                        diagnostics: Debian12OracleFailureDiagnostics(
                            stdout: Debian12OracleTestSupport.byteComparison(
                                expected: testCase.expected.stdoutData,
                                actual: Data()
                            ),
                            stderr: Debian12OracleTestSupport.byteComparison(
                                expected: testCase.expected.stderrData,
                                actual: errorData
                            )
                        )
                    )
                )
            }
        }

        let reportURL = try writeReport(
            selectedCases: selectedCases,
            failures: failures
        )
        guard failures.isEmpty else {
            XCTFail(Self.failureSummary(failures: failures, reportURL: reportURL))
            return
        }
    }

    private static func selectedCases(from cases: [Debian12OracleCase]) -> [Debian12OracleCase] {
        let environment = ProcessInfo.processInfo.environment
        var selected = cases
        if let evidence = environment["MSP_DEBIAN12_ORACLE_EVIDENCE"], !evidence.isEmpty {
            selected = selected.filter { $0.evidenceLevel == evidence }
        }
        if let categoryList = environment["MSP_DEBIAN12_ORACLE_CATEGORIES"], !categoryList.isEmpty {
            let categories = Debian12OracleTestSupport.commaSeparatedSet(categoryList)
            selected = selected.filter { categories.contains($0.category) }
        }
        if let excludedCategoryList = environment["MSP_DEBIAN12_ORACLE_EXCLUDE_CATEGORIES"],
           !excludedCategoryList.isEmpty {
            let excludedCategories = Debian12OracleTestSupport.commaSeparatedSet(excludedCategoryList)
            selected = selected.filter { !excludedCategories.contains($0.category) }
        }
        if let commandList = environment["MSP_DEBIAN12_ORACLE_COMMANDS"], !commandList.isEmpty {
            let commands = Debian12OracleTestSupport.commaSeparatedSet(commandList)
            selected = selected.filter { !commands.isDisjoint(with: Set($0.commands)) }
        }
        if let excludedCommandList = environment["MSP_DEBIAN12_ORACLE_EXCLUDE_COMMANDS"],
           !excludedCommandList.isEmpty {
            let excludedCommands = Debian12OracleTestSupport.commaSeparatedSet(excludedCommandList)
            selected = selected.filter { excludedCommands.isDisjoint(with: Set($0.commands)) }
        }
        if let caseList = environment["MSP_DEBIAN12_ORACLE_CASES"], !caseList.isEmpty {
            let ids = Debian12OracleTestSupport.commaSeparatedSet(caseList)
            selected = selected.filter { ids.contains($0.id) }
        } else if let singleCase = environment["MSP_DEBIAN12_ORACLE_CASE"], !singleCase.isEmpty {
            selected = selected.filter { $0.id == singleCase }
        }
        if let limitText = environment["MSP_DEBIAN12_ORACLE_LIMIT"],
           let limit = Int(limitText),
           limit >= 0 {
            selected = Array(selected.prefix(limit))
        }
        return selected
    }

    private func likelyLayer(for result: MSPCommandResult, mismatch: Debian12OracleMismatch) -> String {
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

    private func writeReport(
        selectedCases: [Debian12OracleCase],
        failures: [Debian12OracleCaseFailure]
    ) throws -> URL {
        let packageRoot = try Debian12OracleTestSupport.packageRoot()
        let reportURL = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("msp-conformance")
            .appendingPathComponent("debian12-noninteractive-report.json")
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let report = Debian12OracleRunReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
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

    private static func failureSummary(
        failures: [Debian12OracleCaseFailure],
        reportURL: URL
    ) -> String {
        let preview = failures.prefix(8).map { failure in
            let stdoutOffset = failure.diagnostics.stdout.firstDifferentByteOffset
                .map(String.init) ?? "none"
            let stderrOffset = failure.diagnostics.stderr.firstDifferentByteOffset
                .map(String.init) ?? "none"
            return "- \(failure.id) [\(failure.likelyLayer)] stdout=\(!failure.mismatch.stdoutMatches)@\(stdoutOffset) stderr=\(!failure.mismatch.stderrMatches)@\(stderrOffset) exit=\(!failure.mismatch.exitCodeMatches) tree=\(!failure.mismatch.fileTreeMatches)"
        }.joined(separator: "\n")
        return """
        Debian 12 oracle conformance failed: \(failures.count) case(s).
        Report: \(reportURL.path)
        \(preview)
        """
    }
}

import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyConformanceTests: XCTestCase {
    func testMSPV1DirectCommandParityCasesRunThroughWorkspaceFS() async throws {
        let fixture = try ModelShellProxyConformanceSupport.directParityFixture()

        for testCase in fixture.cases {
            let rootURL = makeTemporaryURL(testCase.command)
            defer { removeTemporaryURL(rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try writeSetupFiles(testCase.setupFiles ?? [], rootURL: rootURL)

            let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
                .enable(.posixCore)
            for setupCommand in testCase.setupScript ?? [] {
                let setupResult = await shell.run(setupCommand)
                XCTAssertEqual(
                    setupResult.exitCode,
                    0,
                    "setup failed for \(testCase.command): \(setupCommand)\n\(setupResult.stderr)"
                )
            }

            let result = await shell.run(testCase.commandLine)
            let message = """
            command: \(testCase.command)
            command_line:
            \(testCase.commandLine)
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            exit:
            \(result.exitCode)
            """

            assertStdout(result.stdout, matches: testCase, message: message)
            XCTAssertEqual(result.stderr, testCase.stderr, message)
            XCTAssertEqual(result.exitCode, testCase.exitCode, message)
            XCTAssertFalse(result.stdout.contains(rootURL.path), message)
            XCTAssertFalse(result.stderr.contains(rootURL.path), message)
        }
    }

    func testMSPV1DirectCommandParityCoverageMatchesRequiredCommandFixture() throws {
        let parity = try ModelShellProxyConformanceSupport.directParityFixture()
        let required = try ModelShellProxyConformanceSupport.requiredCommandsFixture()

        let directCommands = parity.cases.map(\.command).sorted()
        let requiredCommands = required.commands
            .filter { $0.status == "implemented" }
            .map(\.name)
            .sorted()

        XCTAssertEqual(directCommands.count, requiredCommands.count)
        XCTAssertEqual(Set(directCommands).count, directCommands.count)
        XCTAssertEqual(directCommands, requiredCommands)
    }

    func testMSPV1ParityCasesRunThroughWorkspaceFS() async throws {
        let fixture = try ModelShellProxyConformanceSupport.parityFixture()

        for testCase in fixture.cases {
            let rootURL = makeTemporaryURL(testCase.id)
            defer { removeTemporaryURL(rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try writeSetupFiles(testCase.setupFiles ?? [], rootURL: rootURL)

            let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
                .enable(.posixCore)
            let script = testCase.script.joined(separator: " &&\n")
            let result = await shell.run(script)
            let stepDiagnostics: String
            if result.stdout != testCase.stdout
                || result.stderr != testCase.stderr
                || result.exitCode != testCase.exitCode {
                stepDiagnostics = try await diagnoseSteps(for: testCase, rootURL: rootURL)
            } else {
                stepDiagnostics = ""
            }
            let message = """
            \(testCase.id)
            script:
            \(script)
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            exit:
            \(result.exitCode)
            step diagnostics:
            \(stepDiagnostics)
            """

            XCTAssertEqual(result.stdout, testCase.stdout, message)
            XCTAssertEqual(result.stderr, testCase.stderr, message)
            XCTAssertEqual(result.exitCode, testCase.exitCode, message)
            XCTAssertFalse(result.stdout.contains(rootURL.path), message)
            XCTAssertFalse(result.stderr.contains(rootURL.path), message)
        }
    }

    func testMSPV1EdgeParityCasesRunThroughWorkspaceFS() async throws {
        let fixture = try ModelShellProxyConformanceSupport.edgeParityFixture()

        for testCase in fixture.cases {
            let rootURL = makeTemporaryURL(testCase.id)
            defer { removeTemporaryURL(rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try writeSetupFiles(testCase.setupFiles ?? [], rootURL: rootURL)

            let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
                .enable(.posixCore)
            for setupCommand in testCase.setupScript ?? [] {
                let setupResult = await shell.run(setupCommand)
                XCTAssertEqual(
                    setupResult.exitCode,
                    0,
                    "setup failed for edge case \(testCase.id): \(setupCommand)\n\(setupResult.stderr)"
                )
            }

            let result = await shell.run(testCase.commandLine)
            let message = """
            edge case: \(testCase.id)
            command_line:
            \(testCase.commandLine)
            stdout:
            \(result.stdout)
            stderr:
            \(result.stderr)
            exit:
            \(result.exitCode)
            """

            assertStdout(result.stdout, matches: testCase, message: message)
            XCTAssertEqual(result.stderr, testCase.stderr, message)
            XCTAssertEqual(result.exitCode, testCase.exitCode, message)
            XCTAssertFalse(result.stdout.contains(rootURL.path), message)
            XCTAssertFalse(result.stderr.contains(rootURL.path), message)
        }
    }

    func testMSPV1ParityCaseCoverageMatchesRequiredCommandFixture() throws {
        let parity = try ModelShellProxyConformanceSupport.parityFixture()
        let required = try ModelShellProxyConformanceSupport.requiredCommandsFixture()

        let covered = Set(parity.cases.flatMap(\.coveredCommands))
        let requiredCommands = Set(
            required.commands
                .filter { $0.status == "implemented" }
                .map(\.name)
        )

        XCTAssertEqual(covered, requiredCommands)
    }

    func testMSPV1EdgeParityCasesOnlyReferenceRequiredCommands() throws {
        let edgeParity = try ModelShellProxyConformanceSupport.edgeParityFixture()
        let required = try ModelShellProxyConformanceSupport.requiredCommandsFixture()
        let requiredCommands = Set(
            required.commands
                .filter { $0.status == "implemented" }
                .map(\.name)
        )

        let covered = Set(edgeParity.cases.flatMap(\.coveredCommands))
        XCTAssertFalse(covered.isEmpty)
        XCTAssertTrue(covered.isSubset(of: requiredCommands), "unknown edge commands: \(covered.subtracting(requiredCommands).sorted())")
    }

    private func assertStdout(
        _ stdout: String,
        matches testCase: DirectCommandParityCase,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let expected = testCase.stdout {
            XCTAssertEqual(stdout, expected, message, file: file, line: line)
            return
        }
        guard let pattern = testCase.stdoutMatches else {
            XCTFail("missing stdout expectation for \(testCase.command)", file: file, line: line)
            return
        }
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(stdout.startIndex..., in: stdout)
            let match = regex.firstMatch(in: stdout, range: range)
            XCTAssertEqual(match?.range, range, message, file: file, line: line)
        } catch {
            XCTFail("invalid stdout regex for \(testCase.command): \(error)", file: file, line: line)
        }
    }

    private func assertStdout(
        _ stdout: String,
        matches testCase: EdgeCommandParityCase,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let expected = testCase.stdout {
            XCTAssertEqual(stdout, expected, message, file: file, line: line)
            return
        }
        guard let pattern = testCase.stdoutMatches else {
            XCTFail("missing stdout expectation for \(testCase.id)", file: file, line: line)
            return
        }
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(stdout.startIndex..., in: stdout)
            let match = regex.firstMatch(in: stdout, range: range)
            XCTAssertEqual(match?.range, range, message, file: file, line: line)
        } catch {
            XCTFail("invalid stdout regex for \(testCase.id): \(error)", file: file, line: line)
        }
    }

    private func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyConformanceTests",
            name: name
        )
    }

    private func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
    }

    private func writeSetupFiles(_ files: [ParitySetupFile], rootURL: URL) throws {
        for file in files {
            let url = rootURL.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func diagnoseSteps(for testCase: ParityCase, rootURL: URL) async throws -> String {
        let diagnosticRoot = rootURL.deletingLastPathComponent()
            .appendingPathComponent(rootURL.lastPathComponent + "-diagnostic")
        removeTemporaryURL(diagnosticRoot)
        try FileManager.default.createDirectory(at: diagnosticRoot, withIntermediateDirectories: true)
        try writeSetupFiles(testCase.setupFiles ?? [], rootURL: diagnosticRoot)
        let shell = try ModelShellProxy.iOS(workspaceURL: diagnosticRoot)
            .enable(.posixCore)

        var rows: [String] = []
        for (index, step) in testCase.script.enumerated() {
            let result = await shell.run(step)
            rows.append(
                "#\(index + 1) exit=\(result.exitCode) step=\(step)\n"
                    + "stdout=\(result.stdout.debugDescription)\n"
                    + "stderr=\(result.stderr.debugDescription)"
            )
            if result.exitCode != 0 {
                break
            }
        }
        removeTemporaryURL(diagnosticRoot)
        return rows.joined(separator: "\n")
    }
}

import Foundation
import XCTest

final class ModelShellProxyReleaseGatePreflightConformanceTests: XCTestCase {
    func testFinalExecSessionReleaseGateRejectsNonRequiredModel() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let finalGateURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_final_exec_session_release_gate.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "final-exec-session-gate-rejects-non-required-model"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let result = try runFinalGatePreflight(
            finalGateURL: finalGateURL,
            rootURL: rootURL,
            tempRoot: tempRoot,
            environmentVariable: "MSP_FINAL_EXEC_SESSION_GATE_TMPDIR",
            value: tempRoot.appendingPathComponent("tmp").path,
            model: "gpt-4.1"
        )

        XCTAssertEqual(result.exitCode, 2, "wrong model should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the final release gate; got gpt-4.1"),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("final release gate lock:"),
            "wrong model should fail before acquiring final gate locks:\n\(result.stdout)"
        )
        XCTAssertFalse(
            result.stdout.contains("== final gate step:"),
            "wrong model should fail before running any final gate step:\n\(result.stdout)"
        )
    }

    func testFinalExecSessionReleaseGateRejectsSuiteWeakeningEnvironment() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let finalGateURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_final_exec_session_release_gate.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "final-exec-session-gate-rejects-weakening-env"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        for variable in [
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "MSP_PLAYGROUND_PRESSURE_RESET_APP",
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP"
        ] {
            let result = try runFinalGatePreflight(
                finalGateURL: finalGateURL,
                rootURL: rootURL,
                tempRoot: tempRoot.appendingPathComponent(variable),
                environmentVariable: variable,
                value: "0"
            )

            XCTAssertEqual(result.exitCode, 2, "\(variable) should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(
                result.stderr.contains("\(variable)=0 is not allowed in the final release gate"),
                "\(variable) produced unexpected stderr:\n\(result.stderr)"
            )
            XCTAssertFalse(
                result.stdout.contains("final release gate lock:"),
                "\(variable) should fail before acquiring final gate locks:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stdout.contains("== final gate step:"),
                "\(variable) should fail before running any final gate step:\n\(result.stdout)"
            )
        }
    }

    func testFinalExecSessionReleaseGateRejectsProviderSmokeBypassEnvironment() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let finalGateURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_final_exec_session_release_gate.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "final-exec-session-gate-rejects-provider-bypass"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let cases = [
            (
                variable: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
                value: "MSP_PROVIDER_OK_fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
                value: tempRoot.appendingPathComponent("custom-playground-prompts.json").path,
                expected: "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE is not allowed in the final release gate"
            ),
            (
                variable: "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
                value: tempRoot.appendingPathComponent("custom-photosorter-prompts.json").path,
                expected: "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE is not allowed in the final release gate"
            )
        ]

        for testCase in cases {
            let result = try runFinalGatePreflight(
                finalGateURL: finalGateURL,
                rootURL: rootURL,
                tempRoot: tempRoot.appendingPathComponent(testCase.variable),
                environmentVariable: testCase.variable,
                value: testCase.value
            )

            XCTAssertEqual(result.exitCode, 2, "\(testCase.variable) should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(
                result.stderr.contains(testCase.expected),
                "\(testCase.variable) produced unexpected stderr:\n\(result.stderr)"
            )
            XCTAssertFalse(
                result.stdout.contains("final release gate lock:"),
                "\(testCase.variable) should fail before acquiring final gate locks:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stdout.contains("== final gate step:"),
                "\(testCase.variable) should fail before running any final gate step:\n\(result.stdout)"
            )
        }
    }

    private func runFinalGatePreflight(
        finalGateURL: URL,
        rootURL: URL,
        tempRoot: URL,
        environmentVariable: String,
        value: String,
        model: String = "gpt-5.5"
    ) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["MSP_PLAYGROUND_MODEL_BASE_URL"] = "https://example.invalid/v1"
        environment["MSP_PLAYGROUND_MODEL_API_KEY"] = "dummy"
        environment["MSP_PLAYGROUND_MODEL"] = model
        environment["MSP_FINAL_EXEC_SESSION_GATE_OUT_DIR"] = tempRoot.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

        for key in [
            "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
            "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
            "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
            "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "MSP_PLAYGROUND_PRESSURE_RESET_APP",
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP"
        ] {
            environment.removeValue(forKey: key)
        }
        environment[environmentVariable] = value

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [finalGateURL.path]
        process.currentDirectoryURL = rootURL
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

import Foundation
import XCTest

final class ModelShellProxyPressureHarnessConformanceTests: XCTestCase {
    func testRealModelPressureMatrixRejectsNonRequiredModel() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let matrixRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-matrix-rejects-non-required-model"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let result = try runPressureMatrixPreflight(
            matrixRunnerURL: matrixRunnerURL,
            rootURL: rootURL,
            tempRoot: tempRoot,
            environmentVariable: "MSP_REAL_MODEL_PRESSURE_MATRIX_FAIL_FAST",
            value: "1",
            model: "gpt-4.1"
        )

        XCTAssertEqual(result.exitCode, 2, "wrong model should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("MSP_PLAYGROUND_MODEL must be exactly gpt-5.5 for the real-model pressure matrix; got gpt-4.1"),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("real-model pressure matrix lock:"),
            "wrong model should fail before acquiring matrix locks:\n\(result.stdout)"
        )
        XCTAssertFalse(
            result.stdout.contains("== running pressure suite:"),
            "wrong model should fail before running any suite:\n\(result.stdout)"
        )
    }

    func testRealModelPressureMatrixRejectsSuiteWeakeningEnvironment() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let matrixRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-matrix-rejects-weakening-env"
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
            let result = try runPressureMatrixPreflight(
                matrixRunnerURL: matrixRunnerURL,
                rootURL: rootURL,
                tempRoot: tempRoot.appendingPathComponent(variable),
                environmentVariable: variable,
                value: "0"
            )

            XCTAssertEqual(result.exitCode, 2, "\(variable) should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(
                result.stderr.contains("\(variable)=0 is not allowed in the real-model pressure matrix"),
                "\(variable) produced unexpected stderr:\n\(result.stderr)"
            )
            XCTAssertFalse(
                result.stdout.contains("real-model pressure matrix lock:"),
                "\(variable) should fail before acquiring matrix locks:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stdout.contains("== running pressure suite:"),
                "\(variable) should fail before running any suite:\n\(result.stdout)"
            )
        }
    }

    func testRealModelPressureMatrixRejectsPartialSuiteListBeforeLocking() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let matrixRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-matrix-rejects-partial-suite-list"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let result = try runPressureMatrixPreflight(
            matrixRunnerURL: matrixRunnerURL,
            rootURL: rootURL,
            tempRoot: tempRoot,
            environmentVariable: "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES",
            value: "host-backed"
        )

        XCTAssertEqual(result.exitCode, 2, "partial suite list should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains(
                "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES must include every required suite; missing: exec-session mixed-backend photosorter-virtual photosorter-exec-session"
            ),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("real-model pressure matrix lock:"),
            "partial suite list should fail before acquiring matrix locks:\n\(result.stdout)"
        )
        XCTAssertFalse(
            result.stdout.contains("== running pressure suite:"),
            "partial suite list should fail before running any suite:\n\(result.stdout)"
        )
    }

    func testRealModelPressureMatrixRejectsFinalGateActiveWithoutOutputRootBeforeLocking() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let matrixRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-matrix-rejects-final-gate-active-without-output-root"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let result = try runPressureMatrixPreflight(
            matrixRunnerURL: matrixRunnerURL,
            rootURL: rootURL,
            tempRoot: tempRoot,
            environmentVariable: "MSP_FINAL_EXEC_SESSION_GATE_ACTIVE",
            value: "1",
            extraEnvironment: [
                "MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR": ""
            ]
        )

        XCTAssertEqual(result.exitCode, 2, "final-gate active matrix run without output root should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR is required when the matrix is launched from the final release gate"),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("real-model pressure matrix lock:"),
            "missing final-gate matrix output root should fail before acquiring matrix locks:\n\(result.stdout)"
        )
        XCTAssertFalse(
            result.stdout.contains("== running pressure suite:"),
            "missing final-gate matrix output root should fail before running any suite:\n\(result.stdout)"
        )
    }

    func testRealModelPressureMatrixRejectsProviderSmokeBypassEnvironment() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let matrixRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_real_model_pressure_matrix.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-matrix-rejects-provider-bypass"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let cases = [
            (
                variable: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
                value: "MSP_PROVIDER_OK_fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
                value: tempRoot.appendingPathComponent("custom-playground-prompts.json").path,
                expected: "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE is not allowed in the real-model pressure matrix"
            ),
            (
                variable: "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
                value: tempRoot.appendingPathComponent("custom-photosorter-prompts.json").path,
                expected: "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE is not allowed in the real-model pressure matrix"
            )
        ]

        for testCase in cases {
            let result = try runPressureMatrixPreflight(
                matrixRunnerURL: matrixRunnerURL,
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
                result.stdout.contains("real-model pressure matrix lock:"),
                "\(testCase.variable) should fail before acquiring matrix locks:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stdout.contains("== running pressure suite:"),
                "\(testCase.variable) should fail before running any suite:\n\(result.stdout)"
            )
        }
    }

    func testRealModelPressureSuiteRunnersRejectWeakeningEnvironmentBeforeLocking() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let playgroundRunnerURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("MSPPlaygroundApp")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("run-real-model-pressure.sh")
        let photoSorterRunnerURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("PhotoSorter")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("run-real-model-pressure.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-suite-runners-reject-weakening-env"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }

        let cases = [
            (
                label: "playground-skip-provider",
                runnerURL: playgroundRunnerURL,
                variable: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure suite"
            ),
            (
                label: "playground-disable-python",
                runnerURL: playgroundRunnerURL,
                variable: "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
                value: "0",
                expected: "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0 is not allowed in the real-model pressure suite"
            ),
            (
                label: "playground-provider-nonce",
                runnerURL: playgroundRunnerURL,
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE is not allowed in the real-model pressure suite"
            ),
            (
                label: "photosorter-skip-provider",
                runnerURL: photoSorterRunnerURL,
                variable: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
                value: "1",
                expected: "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE=1 is not allowed in the real-model pressure suite"
            ),
            (
                label: "photosorter-disable-cpython",
                runnerURL: photoSorterRunnerURL,
                variable: "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
                value: "0",
                expected: "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0 is not allowed in the real-model pressure suite"
            ),
            (
                label: "photosorter-provider-prompt",
                runnerURL: photoSorterRunnerURL,
                variable: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
                value: "fixed",
                expected: "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT is not allowed in the real-model pressure suite"
            )
        ]

        for testCase in cases {
            let result = try runPressureSuitePreflight(
                runnerURL: testCase.runnerURL,
                rootURL: rootURL,
                tempRoot: tempRoot.appendingPathComponent(testCase.label),
                environmentVariable: testCase.variable,
                value: testCase.value
            )

            XCTAssertEqual(result.exitCode, 2, "\(testCase.label) should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(
                result.stderr.contains(testCase.expected),
                "\(testCase.label) produced unexpected stderr:\n\(result.stderr)"
            )
            XCTAssertFalse(
                result.stdout.contains("real-model UI pressure lock:"),
                "\(testCase.label) should fail before acquiring UI pressure lock:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stdout.contains("provider smoke passed"),
                "\(testCase.label) should fail before provider smoke:\n\(result.stdout)"
            )
        }
    }

    func testPressurePromptContractAcceptsRequiredPromptFiles() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let promptFiles = [
            "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/host-backed-linux-parity-prompts.json",
            "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/exec-session-parity-prompts.json",
            "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/mixed-backend-linux-parity-prompts.json",
            "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-virtual-workspace-prompts.json",
            "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-exec-session-parity-prompts.json"
        ]

        for promptFile in promptFiles {
            let result = try runPressurePromptContract(
                rootURL: rootURL,
                promptsURL: rootURL.appendingPathComponent(promptFile)
            )

            XCTAssertEqual(result.exitCode, 0, "\(promptFile) should satisfy pressure prompt contract\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(result.stderr.isEmpty, "\(promptFile) produced unexpected stderr:\n\(result.stderr)")
            let outputLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(outputLines.count, 4, "\(promptFile) should emit runner payload plus trailing newline")
            XCTAssertTrue(outputLines[0].hasPrefix("["), "\(promptFile) did not emit prompt JSON first")
        }
    }

    func testPressurePromptContractRejectsExecutionPromptImplementationDisclosure() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-prompt-contract-disclosure"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let promptsURL = tempRoot.appendingPathComponent("prompts.json")
        try writePromptArray([
            """
            请运行 pwd，并注意这是 iOS 沙盒里的 MSP launcher/runtime 执行环境，路径可能来自 CoreSimulator app container、PhotoKit PHAsset localIdentifier 和 virtual materialized 文件。

            最终回答最后一行必须只写：DISCLOSURE_DONE
            """,
            finalFeedbackPrompt()
        ], to: promptsURL)

        let result = try runPressurePromptContract(rootURL: rootURL, promptsURL: promptsURL)

        XCTAssertEqual(result.exitCode, 2, "execution prompt disclosure should fail before UI pressure\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("pressure prompt 0 discloses implementation term before feedback: iOS"),
            result.stderr
        )
        XCTAssertTrue(
            result.stderr.contains("pressure prompt 0 discloses implementation term before feedback: MSP"),
            result.stderr
        )
        XCTAssertTrue(
            result.stderr.contains("pressure prompt 0 discloses implementation term before feedback: 沙盒"),
            result.stderr
        )
        for forbidden in ["launcher", "runtime", "CoreSimulator", "app container", "PhotoKit", "PHAsset", "localIdentifier", "virtual", "materialized"] {
            XCTAssertTrue(
                result.stderr.contains("pressure prompt 0 discloses implementation term before feedback: \(forbidden)"),
                "missing forbidden prompt disclosure for \(forbidden):\n\(result.stderr)"
            )
        }
        XCTAssertTrue(result.stdout.isEmpty, "failed prompt contract should not emit runner payload:\n\(result.stdout)")
    }

    func testPressureSuiteRunnersRejectBadPromptContractBeforeLocking() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let playgroundRunnerURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("MSPPlaygroundApp")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("run-real-model-pressure.sh")
        let photoSorterRunnerURL = rootURL
            .appendingPathComponent("Examples")
            .appendingPathComponent("iOS")
            .appendingPathComponent("PhotoSorter")
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")
            .appendingPathComponent("run-real-model-pressure.sh")
        let tempRoot = ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "real-model-pressure-runner-rejects-bad-prompt-contract"
        )
        defer { ModelShellProxyConformanceSupport.removeTemporaryURL(tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let promptsURL = tempRoot.appendingPathComponent("bad-prompts.json")
        try writePromptArray([
            """
            请运行 pwd。这个任务运行在 iOS 沙盒里的 MSP。

            最终回答最后一行必须只写：BAD_PROMPT_DONE
            """,
            finalFeedbackPrompt()
        ], to: promptsURL)

        let cases = [
            (
                label: "playground",
                runnerURL: playgroundRunnerURL,
                promptsVariable: "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
                lockMarker: "real-model UI pressure lock:",
                pythonMarker: "host-backed pressure requires CPython"
            ),
            (
                label: "photosorter",
                runnerURL: photoSorterRunnerURL,
                promptsVariable: "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
                lockMarker: "real-model UI pressure lock:",
                pythonMarker: "PhotoSorter pressure requires CPython"
            )
        ]

        for testCase in cases {
            let result = try runPressureSuitePreflight(
                runnerURL: testCase.runnerURL,
                rootURL: rootURL,
                tempRoot: tempRoot.appendingPathComponent(testCase.label),
                environmentVariable: testCase.promptsVariable,
                value: promptsURL.path
            )

            XCTAssertEqual(result.exitCode, 2, "\(testCase.label) bad prompt should fail preflight\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(
                result.stderr.contains("pressure prompt 0 discloses implementation term before feedback"),
                "\(testCase.label) bad prompt stderr did not come from prompt contract:\n\(result.stderr)"
            )
            XCTAssertFalse(
                result.stdout.contains(testCase.lockMarker),
                "\(testCase.label) should fail before acquiring UI pressure lock:\n\(result.stdout)"
            )
            XCTAssertFalse(
                result.stderr.contains(testCase.pythonMarker),
                "\(testCase.label) should fail prompt contract before CPython asset checks:\n\(result.stderr)"
            )
        }
    }

    private func runPressureMatrixPreflight(
        matrixRunnerURL: URL,
        rootURL: URL,
        tempRoot: URL,
        environmentVariable: String,
        value: String,
        model: String = "gpt-5.5",
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["MSP_PLAYGROUND_MODEL_BASE_URL"] = "https://example.invalid/v1"
        environment["MSP_PLAYGROUND_MODEL_API_KEY"] = "dummy"
        environment["MSP_PLAYGROUND_MODEL"] = model
        environment["MSP_REAL_MODEL_PRESSURE_MATRIX_OUT_DIR"] = tempRoot.path
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
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP",
            "MSP_REAL_MODEL_PRESSURE_MATRIX_SUITES",
            "MSP_FINAL_EXEC_SESSION_GATE_ACTIVE"
        ] {
            environment.removeValue(forKey: key)
        }
        environment[environmentVariable] = value
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [matrixRunnerURL.path]
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

    private func runPressureSuitePreflight(
        runnerURL: URL,
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
        environment["MSP_PLAYGROUND_PRESSURE_OUT_DIR"] = tempRoot.appendingPathComponent("playground").path
        environment["MSP_PHOTOSORTER_PRESSURE_OUT_DIR"] = tempRoot.appendingPathComponent("photosorter").path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

        for key in [
            "MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD",
            "MSP_PLAYGROUND_PRESSURE_SKIP_PROVIDER_SMOKE",
            "MSP_PHOTOSORTER_PRESSURE_SKIP_PROVIDER_SMOKE",
            "MSP_PLAYGROUND_PROVIDER_CHECK_NONCE",
            "MSP_PLAYGROUND_PROVIDER_CHECK_PROMPT",
            "MSP_PLAYGROUND_PROVIDER_CHECK_EXPECTED_OUTPUT",
            "MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON",
            "MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC",
            "MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE",
            "MSP_PLAYGROUND_PRESSURE_RESET_APP",
            "MSP_PLAYGROUND_E2E_RESET_APP",
            "MSP_PLAYGROUND_PRESSURE_PROMPTS_FILE",
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON",
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP",
            "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE"
        ] {
            environment.removeValue(forKey: key)
        }
        environment[environmentVariable] = value

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runnerURL.path]
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

    private func runPressurePromptContract(rootURL: URL, promptsURL: URL) throws -> ProcessResult {
        let scriptURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("msp_pressure_prompt_contract.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, promptsURL.path]
        process.currentDirectoryURL = rootURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONDONTWRITEBYTECODE": "1"
        ]) { _, new in new }

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

    private func writePromptArray(_ prompts: [String], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: prompts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func finalFeedbackPrompt() -> String {
        """
        只根据前面几轮你亲眼看到的命令输出回答，不要再运行命令。请严格输出一个 JSON 对象，不要 Markdown，不要解释，字段如下：

        {
          "looks_like_regular_linux": true 或 false,
          "can_distinguish_from_regular_linux": true 或 false,
          "suspicious_outputs": [字符串数组],
          "leaked_internal_paths": [字符串数组],
          "notes": "一句话说明"
        }

        判断标准：不要猜测底层环境，只根据前面可见输出判断它是否能和真 Linux 工作区区分。如果你看到了 iOS 沙盒路径、broker 路径、materialized 路径，必须放进 leaked_internal_paths。
        """
    }
}

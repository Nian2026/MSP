import Foundation
import XCTest

extension ModelShellProxyPressureVerifierConformanceTests {
    func requirePython3ForPressureMatrixVerifier() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for matrix verifier tests.")
        }
    }

    func pressureMatrixVerifierURL() throws -> URL {
        try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("verify_real_model_pressure_matrix.py")
    }

    func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        ModelShellProxyConformanceSupport.makeTemporaryURL(
            suiteName: "ModelShellProxyPressureVerifierConformanceTests",
            name: name
        )
    }

    func removeTemporaryURL(_ url: URL) {
        ModelShellProxyConformanceSupport.removeTemporaryURL(url)
    }

    func writeCleanPressureSuiteReports(rootURL: URL) throws {
        for suite in ModelShellProxyPressureGateFixtureSupport.pressureSuites {
            try writePressureSuiteReport(
                suite,
                rootURL: rootURL,
                passed: true,
                failures: []
            )
        }
    }

    func writePressureSuiteReport(
        _ suite: String,
        rootURL: URL,
        passed: Bool,
        failures: [String],
        providerSmokeChecked: Bool = true,
        providerSmokeExpectedOutput: String? = nil,
        providerSmokeActualOutput: String? = nil,
        model: String = ModelShellProxyPressureGateFixtureSupport.requiredModel,
        mainRequestModel: String = ModelShellProxyPressureGateFixtureSupport.requiredModel,
        providerSmokeRequestModel: String = ModelShellProxyPressureGateFixtureSupport.requiredModel,
        modelRequestCount: Int? = nil,
        modelRequestExpectedCount: Int? = nil,
        reportedModelFailures: [String]? = nil,
        reportedPassed: Bool? = nil
    ) throws {
        try ModelShellProxyPressureGateFixtureSupport.writePressureSuiteReport(
            suite,
            rootURL: rootURL,
            passed: passed,
            failures: failures,
            providerSmokeChecked: providerSmokeChecked,
            providerSmokeExpectedOutput: providerSmokeExpectedOutput,
            providerSmokeActualOutput: providerSmokeActualOutput,
            model: model,
            mainRequestModel: mainRequestModel,
            providerSmokeRequestModel: providerSmokeRequestModel,
            modelRequestCount: modelRequestCount,
            modelRequestExpectedCount: modelRequestExpectedCount,
            reportedModelFailures: reportedModelFailures,
            reportedPassed: reportedPassed
        )
    }

    func runMatrixVerifier(
        verifierURL: URL,
        rootURL: URL,
        model: String = ModelShellProxyPressureGateFixtureSupport.requiredModel,
        suiteOverrides: [String: URL] = [:],
        extraSuiteArguments: [(String, URL)] = []
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = [
            verifierURL.path,
            "--root",
            rootURL.path,
            "--report",
            rootURL.appendingPathComponent("pressure-matrix-report.json").path,
            "--model",
            model
        ]
        for suite in suiteOverrides.keys.sorted() {
            guard let url = suiteOverrides[suite] else { continue }
            arguments.append(contentsOf: ["--suite", "\(suite)=\(url.path)"])
        }
        for (suite, url) in extraSuiteArguments {
            arguments.append(contentsOf: ["--suite", "\(suite)=\(url.path)"])
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    func appendRuntimeError(rootURL: URL, suite: String, message: String) throws {
        let eventURL = rootURL
            .appendingPathComponent(suite)
            .appendingPathComponent("events.jsonl")
        let event: [String: Any] = [
            "timestamp": ModelShellProxyPressureGateFixtureSupport.syntheticEventTimestamp,
            "event": "runtime_error",
            "fields": [
                "message": message
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self) + "\n"
        let handle = try FileHandle(forWritingTo: eventURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }
}

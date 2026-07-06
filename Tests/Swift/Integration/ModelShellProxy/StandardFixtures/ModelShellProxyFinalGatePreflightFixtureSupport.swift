import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writePreflightFixtureReport(to url: URL) throws {
        try writeJSONObject(makePreflightFixtureReport(), to: url)
    }

    private static func makePreflightFixtureReport() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            preflightFixtureGeneratorSource()
        ]
        process.currentDirectoryURL = try ModelShellProxyConformanceSupport.packageRoot()

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPATH"] = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ModelShellProxyFinalGatePreflightFixtureSupport",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "preflight fixture generation failed: \(errorOutput)"
                ]
            )
        }

        let value = try JSONSerialization.jsonObject(with: output)
        guard let object = value as? [String: Any] else {
            throw NSError(
                domain: "ModelShellProxyFinalGatePreflightFixtureSupport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "preflight fixture generator did not return a JSON object"]
            )
        }
        return object
    }

    private static func preflightFixtureGeneratorSource() -> String {
        #"""
        import json

        from msp_final_gate_preflight import (
            PREFLIGHT_CASE_CONTRACTS,
            REQUIRED_PREFLIGHT_CASE_LABELS,
            REQUIRED_PREFLIGHT_RUNNER_KINDS,
        )
        from msp_pressure_evidence import REQUIRED_MODEL

        cases = []
        for label in REQUIRED_PREFLIGHT_CASE_LABELS:
            contract = PREFLIGHT_CASE_CONTRACTS[label]
            cases.append({
                "label": label,
                "runner_kind": contract["runner_kind"],
                "runner": contract["runner"],
                "override_keys": contract["override_keys"],
                "expected_exit_code": 2,
                "exit_code": 2,
                "expected_stderr": contract["expected_stderr"],
                "stderr_matched": True,
                "forbidden_stdout": contract["forbidden_stdout"],
                "forbidden_stdout_absent": True,
                "forbidden_stderr": contract["forbidden_stderr"],
                "forbidden_stderr_absent": True,
                "passed": True,
                "failures": [],
            })

        report = {
            "passed": True,
            "required_model": REQUIRED_MODEL,
            "case_count": len(cases),
            "passed_case_count": len(cases),
            "failed_case_count": 0,
            "case_labels": REQUIRED_PREFLIGHT_CASE_LABELS,
            "required_case_labels": REQUIRED_PREFLIGHT_CASE_LABELS,
            "runner_kinds": REQUIRED_PREFLIGHT_RUNNER_KINDS,
            "failures": [],
            "cases": cases,
        }
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        """#
    }
}

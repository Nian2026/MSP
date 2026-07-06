import Foundation
import XCTest

final class ModelShellProxyReleaseGateAuxiliarySourceGuardTests: XCTestCase {
    func testExecSessionStressGateRequiresBothStressOwners() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let stressGateURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_exec_session_stress_gate.sh")
        let stressGate = try String(contentsOf: stressGateURL, encoding: .utf8)

        for required in [
            "ModelShellProxyExecSessionStressTests",
            "ModelShellProxyExecSessionPTYStressTests",
            "ModelShellProxyExecSessionStressTests|ModelShellProxyExecSessionPTYStressTests",
            "--scratch-path",
            "MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT",
            "minimum_executed_test_count",
            "executed_test_count",
            "skipped_test_count",
            "failure_count",
            "unexpected_failure_count",
            "exit_code",
            "command",
            "swift_filters",
            "MSP_EXEC_SESSION_STRESS_CONCURRENCY",
            "MSP_EXEC_SESSION_STRESS_LARGE_OUTPUT_BYTES",
            "MSP_EXEC_SESSION_STRESS_RING_OUTPUT_BYTES",
            "MSP_EXEC_SESSION_OUTPUT_MAX_BYTES",
            "MSP_EXEC_SESSION_STRESS_STDIN_WRITES",
            "MSP_EXEC_SESSION_STRESS_RESOURCE_ITERATIONS",
            "MSP_EXEC_SESSION_STRESS_ALLOWED_FD_GROWTH",
            "MSP_EXEC_SESSION_STRESS_ALLOWED_MEMORY_GROWTH_BYTES",
            "MSP_EXEC_SESSION_STRESS_ALLOWED_IDLE_CPU_MILLISECONDS",
            "app lifecycle background/foreground gap preserves running pipe session state",
            "app lifecycle background/foreground gap preserves running PTY session state",
            "PTY retained-output cap/ring truncation preserves later reads",
            "PTY repeated-session fd leak budget",
            "PTY repeated-session resident memory growth budget",
            "PTY post-cleanup idle CPU budget",
            "exec-session-stress-report.json"
        ] {
            XCTAssertTrue(stressGate.contains(required), "exec-session stress gate missing \(required)")
        }
    }

    func testModelWorkspaceExecutionProfileDocumentsFinalGateRequirements() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let profileURL = rootURL
            .appendingPathComponent("Spec")
            .appendingPathComponent("Profiles")
            .appendingPathComponent("MSPModelWorkspaceExecutionSDKProfile.md")
        let profile = try String(contentsOf: profileURL, encoding: .utf8)

        for required in [
            "MSP_PLAYGROUND_MODEL=gpt-5.5",
            "run_final_exec_session_release_gate.sh",
            "This gate is intentionally not a smoke test",
            "check_real_model_pressure_preflight.py",
            "real-model pressure preflight",
            "real-model pressure matrix both refuse",
            "not exactly `gpt-5.5`",
            "provider smoke prompt, expected output, or nonce are overridden",
            "suite-level environment variables disable the required Python",
            "shell diagnostic, Python oracle, embedded CPython, or fresh-app-reset pressure",
            "required CPython packaging asset is missing",
            "embedded CPython pressure path",
            "cache_beeware_cpython_apple_support.sh",
            "run_exec_session_stress_gate.sh",
            "verify_readex_boundary.py",
            "Readex boundary verifier",
            "external Readex source dependencies",
            "Python subprocess calls have not",
            "command-pack exclusions",
            "--require-linux-runner",
            "mock model",
            "audit-ready",
            "per-step log paths",
            "exec-session stress report",
            "Debian noninteractive oracle",
            "Core100 noninteractive oracle",
            "focused test-suites ledger",
            "focused-test-suites-ledger/focused-test-suites-ledger-report.json",
            "canonical step log",
            "Linux PTY oracle report",
            "pressure matrix report",
            "linux_character_oracle_alignment",
            "Linux character-level oracle cases passed",
            "compatibility adjustments are empty",
            "recompute the summary",
            "must refuse to",
            "verify_final_exec_session_release_gate_report.py",
            "verifier summary",
            "can distinguish MSP from regular Linux",
            "iOS sandbox path, broker path, materialized path",
            "observed command/Python output",
            "any claimed leak must quote the observed text"
        ] {
            XCTAssertTrue(profile.contains(required), "profile missing final gate requirement \(required)")
        }
    }

    func testReadexBoundaryVerifierPreservesSnapshotGuardrails() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let readexBoundaryVerifierURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("verify_readex_boundary.py")
        let readexBoundarySupportURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("final_gate_verifier_support")
            .appendingPathComponent("readex_boundary.py")
        let readexBoundaryVerifier = try [
            readexBoundaryVerifierURL,
            readexBoundarySupportURL
        ].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        for required in [
            "READ_ONLY_SNAPSHOT_DIRS",
            "References/ReadexShellSnapshot",
            "References/ReadexReadingAgentSnapshot",
            "SCRIPT_SCAN_ROOTS",
            "FORBIDDEN_EXTERNAL_READEX_MARKERS",
            "/Volumes/PrivateReference/Projects/Readex",
            "PrivateReadexReferenceApp",
            "PRIVATE_READEX_REFERENCE_",
            "git status",
            "Readex reference snapshot is not clean",
            "scanned_scripts",
            "forbidden external Readex marker"
        ] {
            XCTAssertTrue(readexBoundaryVerifier.contains(required), "Readex boundary verifier missing \(required)")
        }
    }

    func testDebianNoninteractiveRunnerUsesIsolatedConformanceTempAndToolDiscovery() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let noninteractiveRunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_debian12_oracle_conformance.sh")
        let noninteractiveRunner = try String(contentsOf: noninteractiveRunnerURL, encoding: .utf8)

        for required in [
            "MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON",
            "MSP_CONFORMANCE_TMPDIR",
            ".build/msp-conformance/debian12-oracle/tmp",
            "msp-debian12-oracle-tmp-",
            "MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE",
            "MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE",
            "command -v python3",
            "command -v node",
            "MSP_DEBIAN12_ORACLE_SCRATCH_ROOT",
            "--scratch-path",
            "ModelShellProxyDebian12OracleConformanceTests/testMSPV1Debian12OracleNoninteractiveConformanceRunner"
        ] {
            XCTAssertTrue(noninteractiveRunner.contains(required), "Debian noninteractive runner missing \(required)")
        }
    }

    func testCore100RunnerUsesIsolatedConformanceTempAndSwiftScratchPath() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let core100RunnerURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("run_core100_oracle_conformance.sh")
        let core100Runner = try String(contentsOf: core100RunnerURL, encoding: .utf8)

        for required in [
            "MSP_CONFORMANCE_TMPDIR",
            ".build/msp-conformance/core100-oracle/tmp",
            "msp-core100-oracle-tmp-",
            "MSP_CORE100_ORACLE_SCRATCH_ROOT",
            "--scratch-path",
            "ModelShellProxyCore100OracleConformanceTests/testMSPV1Core100OracleNoninteractiveConformanceRunner"
        ] {
            XCTAssertTrue(core100Runner.contains(required), "Core100 runner missing \(required)")
        }
    }

    func testFocusedLedgerWriterRecordsFinalGateScratchContracts() throws {
        let rootURL = try ModelShellProxyConformanceSupport.packageRoot()
        let focusedLedgerWriterURL = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("write_focused_test_suites_ledger.py")
        let focusedLedgerWriter = try String(contentsOf: focusedLedgerWriterURL, encoding: .utf8)

        for required in [
            "_with_final_gate_scratch_contract",
            "$OUT_DIR/swiftpm-scratch/{step}",
            "--scratch-path",
            "MSP_EXEC_SESSION_STRESS_GATE_SCRATCH_ROOT=$OUT_DIR/exec-session-stress/scratch"
        ] {
            XCTAssertTrue(focusedLedgerWriter.contains(required), "focused ledger writer missing \(required)")
        }
    }
}

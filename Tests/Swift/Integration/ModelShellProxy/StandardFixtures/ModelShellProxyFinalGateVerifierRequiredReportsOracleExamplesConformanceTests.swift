import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testFinalGateVerifierRejectsForgedLiveNoninteractiveLinuxVPSOracleReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-live-vps-oracle")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let liveURL = rootURL.appendingPathComponent("live-noninteractive-linux-vps-oracle-report.json")
        var live = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(liveURL)
        live["runnerPlatform"] = "macOS-15.5-arm64"
        live["runnerSystem"] = "Darwin"
        live["runnerOSRelease"] = "NAME=\"Not Debian\"\nVERSION_ID=\"0\"\n"
        live["runnerFailures"] = ["ssh runner failed"]
        live["failedCaseCount"] = 1
        live["failedCaseIDs"] = ["existing-coreutils-text-pipeline"]
        live["failures"] = [["id": "existing-coreutils-text-pipeline"]]
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(live, to: liveURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("live noninteractive Linux VPS oracle runner is not proven Linux/Debian"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("live noninteractive Linux VPS oracle runner is not proven Debian 12/bookworm"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("live noninteractive Linux VPS oracle has failed cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("live noninteractive Linux VPS runnerFailures is missing or non-empty"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsForgedReadexBoundaryScriptScan() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-forged-readex-boundary-script-scan")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let boundaryURL = rootURL.appendingPathComponent("readex-boundary-report.json")
        var boundary = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(boundaryURL)
        boundary["scanned_script_count"] = 0
        boundary["scanned_scripts"] = []
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(boundary, to: boundaryURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary did not scan release scripts"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary report scanned_script_count does not match current repository scan"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary report scanned_scripts does not match current repository scan"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsDirtyReadexSnapshotAfterBoundaryReportWasWritten() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-dirty-readex-boundary")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dirtySnapshotFile = rootURL
            .appendingPathComponent("References")
            .appendingPathComponent("ReadexShellSnapshot")
            .appendingPathComponent("dirty-after-report.txt")
        try "dirty\n".write(to: dirtySnapshotFile, atomically: true, encoding: .utf8)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary current repository scan did not pass"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary report dirty_snapshot_status does not match current repository scan"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Readex boundary report passed does not match current repository scan"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsDebianNoninteractiveOracleMissingRequiredPassedCaseID() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-debian-noninteractive-case-id")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let noninteractiveURL = rootURL.appendingPathComponent("debian12-noninteractive-oracle-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(noninteractiveURL)
        let required = "existing-coreutils-text-pipeline"
        report["passedCaseIDs"] = (report["passedCaseIDs"] as? [String] ?? []).filter { $0 != required }
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: noninteractiveURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Debian noninteractive passedCaseIDs does not contain 50 unique cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Debian noninteractive oracle missing required passed case id: existing-coreutils-text-pipeline"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsLinuxPTYOracleMissingRequiredPassedCaseID() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-missing-linux-pty-case-id")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let ptyURL = rootURL.appendingPathComponent("debian12-linux-pty-oracle-report.json")
        var report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(ptyURL)
        let required = "pty_live_python_stdin_script_split"
        report["passedCaseIDs"] = (report["passedCaseIDs"] as? [String] ?? []).filter { $0 != required }
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(report, to: ptyURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("Debian Linux PTY passedCaseIDs does not contain 157 unique cases"),
            failed.stderr
        )
        XCTAssertTrue(
            failed.stderr.contains("Debian Linux PTY oracle missing required passed case id: pty_live_python_stdin_script_split"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsIncompleteOpenSourceReleaseDryRunReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-incomplete-open-source-release-dry-run")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dryRunURL = rootURL
            .appendingPathComponent("open-source-release-dry-run")
            .appendingPathComponent("open-source-release-dry-run-report.json")
        var dryRun = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dryRunURL)
        var commands = dryRun["commands"] as? [[String: Any]] ?? []
        commands.removeAll {
            let command = ($0["command"] as? [String]) ?? []
            return command.prefix(2).elementsEqual(["swift", "test"])
                && command.contains { $0.contains("Examples/iOS/PhotoSorter") }
        }
        dryRun["commands"] = commands
        dryRun["failures"] = []
        dryRun["passed"] = true
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dryRun, to: dryRunURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("open-source release dry-run commands do not cover every required copied-tree SwiftPM test"),
            failed.stderr
        )
    }
}

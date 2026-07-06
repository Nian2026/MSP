import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateOpenSourceReleaseDryRunFixture(rootURL: URL) throws -> URL {
        let reportRootURL = rootURL.appendingPathComponent("open-source-release-dry-run")
        let reportURL = reportRootURL.appendingPathComponent("open-source-release-dry-run-report.json")
        let publishRootURL = reportRootURL.appendingPathComponent("publish")
        let logsRootURL = reportRootURL.appendingPathComponent("logs")
        let reportsRootURL = reportRootURL.appendingPathComponent("reports")
        let scratchRootURL = reportRootURL.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: publishRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportsRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)

        let requiredChecks: [[String: Any]] = [
            [
                "check_id": "open-source-example-boundary",
                "kind": "gate-script",
                "description": "copied tree only contains the public iOS examples and their allowed dependencies"
            ],
            [
                "check_id": "open-source-hygiene",
                "kind": "gate-script",
                "description": "copied tree contains no release-blocking local artifacts or private validation output"
            ],
            [
                "check_id": "example-chat-renderer-vendor-hygiene",
                "kind": "gate-script",
                "description": "copied tree example transcript renderer vendor assets have manifests, bounded symlinks, and third-party license evidence"
            ],
            [
                "check_id": "open-source-license-notice",
                "kind": "gate-script",
                "description": "copied tree has root license/notice files and public third-party license evidence"
            ],
            [
                "check_id": "photosorter-default-package-boundary",
                "kind": "gate-script",
                "description": "copied tree PhotoSorter default package excludes local FastVLM sources, model weights, and MLX package products"
            ],
            [
                "check_id": "swift-test-MSPPlaygroundApp",
                "kind": "swiftpm-test",
                "package_path": "Examples/iOS/MSPPlaygroundApp",
                "description": "default SwiftPM test for the public MSPPlaygroundApp example package"
            ],
            [
                "check_id": "swift-test-PhotoSorter",
                "kind": "swiftpm-test",
                "package_path": "Examples/iOS/PhotoSorter",
                "description": "default SwiftPM test for the public PhotoSorter example package"
            ]
        ]
        let requiredExamples: [[String: Any]] = [
            [
                "name": "MSPPlaygroundApp",
                "package_path": "Examples/iOS/MSPPlaygroundApp",
                "required_command": "swift test"
            ],
            [
                "name": "PhotoSorter",
                "package_path": "Examples/iOS/PhotoSorter",
                "required_command": "swift test"
            ]
        ]
        let coverage = [
            "copied publishable release tree",
            "open-source example boundary gate on copied tree",
            "open-source hygiene gate on copied tree",
            "example chat renderer vendor/license hygiene gate on copied tree",
            "open-source license/notice gate on copied tree",
            "PhotoSorter default package/local FastVLM boundary gate on copied tree",
            "public MSPPlaygroundApp and PhotoSorter SwiftPM tests on copied tree"
        ]

        let commands: [[String: Any]] = [
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "open-source-example-boundary",
                purpose: "open-source example boundary gate on copied tree",
                command: [
                    "python3",
                    publishRootURL
                        .appendingPathComponent("Conformance/Scripts/check_open_source_example_boundary.py")
                        .path,
                    "--root",
                    publishRootURL.path,
                    "--report",
                    reportsRootURL.appendingPathComponent("open-source-example-boundary.json").path
                ],
                logURL: logsRootURL.appendingPathComponent("open-source-example-boundary.log"),
                evidenceReportURL: reportsRootURL.appendingPathComponent("open-source-example-boundary.json")
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "open-source-hygiene",
                purpose: "open-source hygiene gate on copied tree",
                command: [
                    "python3",
                    publishRootURL
                        .appendingPathComponent("Conformance/Scripts/check_open_source_hygiene.py")
                        .path,
                    "--root",
                    publishRootURL.path,
                    "--report",
                    reportsRootURL.appendingPathComponent("open-source-hygiene.json").path
                ],
                logURL: logsRootURL.appendingPathComponent("open-source-hygiene.log"),
                evidenceReportURL: reportsRootURL.appendingPathComponent("open-source-hygiene.json")
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "example-chat-renderer-vendor-hygiene",
                purpose: "example chat renderer vendor/license hygiene gate on copied tree",
                command: [
                    "python3",
                    publishRootURL
                        .appendingPathComponent("Conformance/Scripts/check_example_chat_renderer_vendor_hygiene.py")
                        .path,
                    "--root",
                    publishRootURL.path,
                    "--report",
                    reportsRootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene.json").path
                ],
                logURL: logsRootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene.log"),
                evidenceReportURL: reportsRootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene.json")
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "open-source-license-notice",
                purpose: "open-source license/notice gate on copied tree",
                command: [
                    "python3",
                    publishRootURL
                        .appendingPathComponent("Conformance/Scripts/check_open_source_license_notice.py")
                        .path,
                    "--root",
                    publishRootURL.path,
                    "--report",
                    reportsRootURL.appendingPathComponent("open-source-license-notice.json").path
                ],
                logURL: logsRootURL.appendingPathComponent("open-source-license-notice.log"),
                evidenceReportURL: reportsRootURL.appendingPathComponent("open-source-license-notice.json")
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "photosorter-default-package-boundary",
                purpose: "PhotoSorter default package/local FastVLM boundary gate on copied tree",
                command: [
                    "python3",
                    publishRootURL
                        .appendingPathComponent("Conformance/Scripts/check_photosorter_default_package_boundary.py")
                        .path,
                    "--root",
                    publishRootURL.path,
                    "--report",
                    reportsRootURL.appendingPathComponent("photosorter-default-package-boundary.json").path
                ],
                logURL: logsRootURL.appendingPathComponent("photosorter-default-package-boundary.log"),
                evidenceReportURL: reportsRootURL.appendingPathComponent("photosorter-default-package-boundary.json")
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "swift-test-MSPPlaygroundApp",
                purpose: "default SwiftPM test for public MSPPlaygroundApp example on copied tree",
                command: [
                    "swift",
                    "test",
                    "--package-path",
                    publishRootURL.appendingPathComponent("Examples/iOS/MSPPlaygroundApp").path,
                    "--scratch-path",
                    scratchRootURL.appendingPathComponent("MSPPlaygroundApp").path
                ],
                logURL: logsRootURL.appendingPathComponent("MSPPlaygroundApp-swift-test.log"),
                packagePath: "Examples/iOS/MSPPlaygroundApp",
                executedTestCount: 59,
                skippedTestCount: 1
            ),
            finalGateOpenSourceReleaseDryRunCommand(
                checkID: "swift-test-PhotoSorter",
                purpose: "default SwiftPM test for public PhotoSorter example on copied tree",
                command: [
                    "swift",
                    "test",
                    "--package-path",
                    publishRootURL.appendingPathComponent("Examples/iOS/PhotoSorter").path,
                    "--scratch-path",
                    scratchRootURL.appendingPathComponent("PhotoSorter").path
                ],
                logURL: logsRootURL.appendingPathComponent("PhotoSorter-swift-test.log"),
                packagePath: "Examples/iOS/PhotoSorter",
                executedTestCount: 349,
                skippedTestCount: 13
            )
        ]

        try writeJSONObject([
            "schema_version": 1,
            "passed": true,
            "gate": "msp-open-source-release-dry-run",
            "source_root": rootURL.path,
            "out_dir": reportRootURL.path,
            "publish_root": publishRootURL.path,
            "report": reportURL.path,
            "release_candidate_contract": [
                "copy current publishable Git worktree surface into a temporary release tree",
                "run open-source gates inside the copied release tree",
                "run default SwiftPM tests for MSPPlaygroundApp and PhotoSorter inside the copied release tree",
                "do not treat source-tree-only results as publishable release evidence"
            ],
            "publishable_file_set_rule": "git ls-files -co --exclude-standard -z, existing files and symlinks only",
            "file_set_rule": "git ls-files -co --exclude-standard -z, existing files and symlinks only",
            "required_checks": requiredChecks,
            "required_examples": requiredExamples,
            "coverage": coverage,
            "copy_summary": [
                "candidate_path_count": 42,
                "copied_file_count": 40,
                "copied_symlink_count": 2,
                "skipped_paths": []
            ],
            "release_tree_checks": [
                "path_findings": [],
                "symlink_findings": [],
                "post_test_removed_paths": [
                    "Examples/iOS/MSPPlaygroundApp/Package.resolved",
                    "Examples/iOS/PhotoSorter/Package.resolved"
                ],
                "post_test_generated_path_findings": []
            ],
            "commands": commands,
            "failures": []
        ], to: reportURL)
        return reportURL
    }

    static func finalGateOpenSourceReleaseDryRunCommand(
        checkID: String,
        purpose: String,
        command: [String],
        logURL: URL,
        packagePath: String? = nil,
        evidenceReportURL: URL? = nil,
        executedTestCount: Int? = nil,
        skippedTestCount: Int? = nil
    ) -> [String: Any] {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let logText: String
        if let executedTestCount, let skippedTestCount {
            logText = """
            Test Suite 'Selected tests' passed.
            \t Executed \(executedTestCount) tests, with \(skippedTestCount) tests skipped and 0 failures (0 unexpected) in 0.001 seconds

            """
        } else {
            logText = "MSP copied-tree open-source gate passed\n"
        }
        try? logText.write(to: logURL, atomically: true, encoding: .utf8)
        if let evidenceReportURL {
            try? FileManager.default.createDirectory(
                at: evidenceReportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "{\"passed\":true,\"failures\":[]}\n".write(
                to: evidenceReportURL,
                atomically: true,
                encoding: .utf8
            )
        }

        var report: [String: Any] = [
            "check_id": checkID,
            "purpose": purpose,
            "command": command,
            "cwd": logURL.deletingLastPathComponent().deletingLastPathComponent().path,
            "exit_code": 0,
            "log": logURL.path,
            "passed": true,
            "elapsed_seconds": 0.1
        ]
        if let packagePath {
            report["package_path"] = packagePath
        }
        if let evidenceReportURL {
            report["evidence_report"] = evidenceReportURL.path
        }
        if let executedTestCount, let skippedTestCount {
            report["executed_test_count"] = executedTestCount
            report["skipped_test_count"] = skippedTestCount
            report["failure_count"] = 0
            report["unexpected_failure_count"] = 0
        }
        return report
    }

}

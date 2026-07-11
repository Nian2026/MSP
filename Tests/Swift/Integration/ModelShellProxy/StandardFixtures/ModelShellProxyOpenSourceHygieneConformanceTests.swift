import Foundation
import XCTest

extension ModelShellProxyFinalGateVerifierConformanceTests {
    func testOpenSourceHygieneScriptAcceptsCleanTree() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-clean-tree")
        defer { removeTemporaryURL(rootURL) }
        let cleanFiles = [
            "Sources/MSPCore/MSPClean.swift": "public struct MSPClean {}\n",
            "Tools/RequestParity/capture_proxy.py": "# public helper\n",
            "Conformance/Chat/CodexCliValidation/VENDOR_MANIFEST.md": "# Codex CLI Vendor Manifest\n",
            "Conformance/Chat/CodexCliValidation/reports/portable-validation-evidence.md": """
            # Portable Codex CLI Validation Evidence

            - gate fixture: `Conformance/Chat/CodexCliValidation/fixtures/gate-input/codex-validation-gate-note.txt`
            - upstream repo: `$CODEX_UPSTREAM_REPO`
            - repo root: `<repo-root>`
            - build root: `<codex-chat-validation-build-root>`
            """,
            "References/LinuxSourceSnapshot/README.md": "# Linux Source Snapshot\n"
        ]
        for (path, contents) in cleanFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["blocked_path_count"] as? Int, 0)
    }

    func testOpenSourceHygieneScriptRejectsReleaseBlockingArtifacts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-blocked-tree")
        defer { removeTemporaryURL(rootURL) }
        let blockedFiles = [
            ".build/debug/output.o",
            ".codex-tmp/architecture/draft.md",
            ".swiftpm/configuration/registries.json",
            "DerivedData/Module/build.db",
            "artifacts/run.json",
            "a",
            "b",
            "Examples/iOS/PhotoSorter.backup-20260629-170131/Package.swift",
            "Examples/iOS/PhotoSorter/Project/build-mcp/output.txt",
            "Conformance/Chat/CodexCliValidation/results/local-smoke/output.json",
            "Conformance/Chat/CodexCliValidation/upstream/openai-codex-original/README.md",
            "Conformance/Chat/CodexCliValidation/instrumented-work/local-run/output.json",
            "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/target/debug/codex",
            "main--abc123.js",
            ".DS_Store",
            "__pycache__/module.cpython-313.pyc"
        ]
        for path in blockedFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "blocked\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        for expected in [
            "root-runtime-artifacts",
            "private-construction-state",
            "swift-and-xcode-build-output",
            "example-backups-and-build-mcp",
            "internal-validation-results",
            "bundled-js-output",
            "macos-finder-metadata",
            "python-bytecode-cache"
        ] {
            XCTAssertTrue(reportText.contains(expected), reportText)
        }
    }

    func testOpenSourceHygieneScriptRejectsInternalValidationRootDirectories() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-internal-validation-roots")
        defer { removeTemporaryURL(rootURL) }
        for path in [
            "Conformance/Chat/CodexCliValidation/results",
            "Conformance/Chat/CodexCliValidation/upstream",
            "Conformance/Chat/CodexCliValidation/instrumented-work"
        ] {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(
            reportText.contains("Conformance/Chat/CodexCliValidation/results"),
            reportText
        )
        XCTAssertTrue(
            reportText.contains("Conformance/Chat/CodexCliValidation/upstream"),
            reportText
        )
        XCTAssertTrue(
            reportText.contains("Conformance/Chat/CodexCliValidation/instrumented-work"),
            reportText
        )
        XCTAssertTrue(reportText.contains("internal-validation-results"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsCodexValidationLocalHostPaths() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-codex-validation-local-paths")
        defer { removeTemporaryURL(rootURL) }
        let reportPath = "Conformance/Chat/CodexCliValidation/reports/local-machine-evidence.md"
        let reportURL = rootURL.appendingPathComponent(reportPath)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
            # Local Machine Evidence

            - attachment: `/Users/example/.codex/attachments/local/pasted-text-1.txt`
            - checkout: `/Volumes/ExampleDrive/Projects/codex`
            """
            .write(to: reportURL, atomically: true, encoding: .utf8)

        let gateReportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: gateReportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: gateReportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains(reportPath), reportText)
        XCTAssertTrue(reportText.contains("codex-validation-local-host-paths"), reportText)
        XCTAssertTrue(reportText.contains("local machine paths"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsFirstPartyLocalHostPaths() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-first-party-local-paths")
        defer { removeTemporaryURL(rootURL) }
        let statusPath = "Spec/Chat/CurrentStatus.md"
        let statusURL = rootURL.appendingPathComponent(statusPath)
        try FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let userHomePath = "/Users/" + "example-private-user/.codex/attachments/local/pasted-text-1.txt"
        let volumePath = "/Volumes/" + "ExampleDrive/Projects/PrivateWorktree/.codex-tmp/local-tmp"
        try """
            # Local Evidence

            - attachment: `\(userHomePath)`
            - tmp: `\(volumePath)`
            """
            .write(to: statusURL, atomically: true, encoding: .utf8)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains(statusPath), reportText)
        XCTAssertTrue(reportText.contains("first-party-local-host-paths"), reportText)
        XCTAssertTrue(reportText.contains("local machine paths"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsMarkstreamPublicSurface() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-markstream-public-surface")
        defer { removeTemporaryURL(rootURL) }
        let sdkPath = "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/readex-markstream-sdk.js"
        let runtimePath = "Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/RuntimeResources/Math/chat-transcript-render-support.js"
        try writeFile(
            rootURL: rootURL,
            relativePath: sdkPath,
            contents: "window.ReadexMarkstreamSDK = Object.freeze({});\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: runtimePath,
            contents: "const enabled = rendererProfile.startsWith(\"markstream-\");\n"
        )
        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("markstream-public-surface"), reportText)
        XCTAssertTrue(reportText.contains(sdkPath), reportText)
        XCTAssertTrue(reportText.contains(runtimePath), reportText)
    }

    func testOpenSourceHygieneScriptAllowsAuditedMSPChatUIMarkstreamSurface() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-audited-msp-chat-ui-markstream")
        defer { removeTemporaryURL(rootURL) }
        try writeAuditedMSPChatUIMarkstreamFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["blocked_path_count"] as? Int, 0)
        let ruleIDs = report["required_rule_ids"] as? [String]
        XCTAssertTrue(ruleIDs?.contains("msp-chat-ui-markstream-vendor-hygiene") == true)
    }

    func testOpenSourceHygieneScriptRejectsTamperedMSPChatUIMarkstreamBundle() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-tampered-msp-chat-ui-markstream")
        defer { removeTemporaryURL(rootURL) }
        try writeAuditedMSPChatUIMarkstreamFixture(rootURL: rootURL)
        try writeFile(
            rootURL: rootURL,
            relativePath: "Implementations/UI/MSPChatUI/Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js",
            contents: "window.markstream = null;\n"
        )

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("msp-chat-ui-markstream-vendor-hygiene"), reportText)
        XCTAssertTrue(reportText.contains("checksum does not match"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsForceTrackedPrivateAndBuildState() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-force-tracked-private-state")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let gitProbe = try runGit(["--version"], currentDirectoryURL: rootURL)
        guard gitProbe.exitCode == 0 else {
            throw XCTSkip("git is required for force-tracked open-source hygiene tests.")
        }
        let initResult = try runGit(["init"], currentDirectoryURL: rootURL)
        XCTAssertEqual(initResult.exitCode, 0, initResult.stderr)

        let blockedFiles = [
            ".build/debug/output.o",
            ".codex-tmp/architecture/draft.md",
            ".swiftpm/configuration/registries.json",
            "DerivedData/Module/build.db"
        ]
        for path in blockedFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "blocked\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let addResult = try runGit(["add", "-f"] + blockedFiles, currentDirectoryURL: rootURL)
        XCTAssertEqual(addResult.exitCode, 0, addResult.stderr)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("private-construction-state"), reportText)
        XCTAssertTrue(reportText.contains("swift-and-xcode-build-output"), reportText)
        for path in blockedFiles {
            XCTAssertTrue(reportText.contains(path), reportText)
        }
    }

    func testOpenSourceHygieneScriptRejectsForceTrackedLocalSourceSnapshots() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-force-tracked-linux-source")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let gitProbe = try runGit(["--version"], currentDirectoryURL: rootURL)
        guard gitProbe.exitCode == 0 else {
            throw XCTSkip("git is required for force-tracked open-source hygiene tests.")
        }
        let initResult = try runGit(["init"], currentDirectoryURL: rootURL)
        XCTAssertEqual(initResult.exitCode, 0, initResult.stderr)

        let sourcePaths = [
            "References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cat.c",
            "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/core/README.md",
            "Spec/Chat/Internal/Drafts/SourceMappingDraft.md",
            "Spec/AgentBridge/Internal/Compaction/README.md",
            "References/ReadexReadingAgentSnapshot/local-source/Sources/AppModel.swift",
            "References/ReadexShellSnapshot/local-source/Sources/Shell.swift"
        ]
        for sourcePath in sourcePaths {
            let sourceURL = rootURL.appendingPathComponent(sourcePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "/* local-only source */\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        }
        let addResult = try runGit(["add", "-f"] + sourcePaths, currentDirectoryURL: rootURL)
        XCTAssertEqual(addResult.exitCode, 0, addResult.stderr)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        for sourcePath in sourcePaths {
            XCTAssertTrue(reportText.contains(sourcePath), reportText)
        }
        XCTAssertTrue(reportText.contains("local-linux-source-snapshot"), reportText)
        XCTAssertTrue(reportText.contains("local-codex-source-snapshot"), reportText)
        XCTAssertTrue(reportText.contains("internal-chat-spec-drafts"), reportText)
        XCTAssertTrue(reportText.contains("internal-agentbridge-construction-notes"), reportText)
        XCTAssertTrue(reportText.contains("local-readex-reference-snapshot"), reportText)
        XCTAssertTrue(reportText.contains("git-publishable"), reportText)
    }

    func testOpenSourceHygieneScriptAllowsIgnoredLocalSourceSnapshots() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-ignored-local-linux-source")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let gitProbe = try runGit(["--version"], currentDirectoryURL: rootURL)
        guard gitProbe.exitCode == 0 else {
            throw XCTSkip("git is required for ignored local source hygiene tests.")
        }
        let initResult = try runGit(["init"], currentDirectoryURL: rootURL)
        XCTAssertEqual(initResult.exitCode, 0, initResult.stderr)

        try """
            References/LinuxSourceSnapshot/debian12-bookworm/sources/
            Conformance/Chat/CodexCliValidation/source-snapshots/
            Spec/Chat/Internal/
            Spec/AgentBridge/Internal/
            References/ReadexReadingAgentSnapshot/*/
            References/ReadexShellSnapshot/*/
            """
            .write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let sourcePaths = [
            "References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cat.c",
            "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/core/README.md",
            "Spec/Chat/Internal/Drafts/SourceMappingDraft.md",
            "Spec/AgentBridge/Internal/Compaction/README.md",
            "References/ReadexReadingAgentSnapshot/local-source/Sources/AppModel.swift",
            "References/ReadexShellSnapshot/local-source/Sources/Shell.swift"
        ]
        for sourcePath in sourcePaths {
            let sourceURL = rootURL.appendingPathComponent(sourcePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "/* local-only source */\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["blocked_path_count"] as? Int, 0)
    }

    func testOpenSourceHygieneScriptRejectsLocalOnlySourceMaterialInCopiedReleaseTree() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-copied-release-tree-local-source")
        defer { removeTemporaryURL(rootURL) }
        let copiedReleasePaths = [
            "References/LinuxSourceSnapshot/debian12-bookworm/sources/coreutils-9.1/src/cat.c",
            "Conformance/Chat/CodexCliValidation/source-snapshots/openai-codex-original/codex-rs/core/README.md",
            "Spec/Chat/Internal/Drafts/SourceMappingDraft.md",
            "Spec/AgentBridge/Internal/Compaction/README.md",
            "References/ReadexReadingAgentSnapshot/local-source/Sources/AppModel.swift",
            "References/ReadexShellSnapshot/local-source/Sources/Shell.swift"
        ]
        for path in copiedReleasePaths {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "/* copied local-only source */\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        for expected in [
            "local-linux-source-snapshot",
            "local-codex-source-snapshot",
            "internal-chat-spec-drafts",
            "internal-agentbridge-construction-notes",
            "local-readex-reference-snapshot"
        ] {
            XCTAssertTrue(reportText.contains(expected), reportText)
        }
    }

    func testOpenSourceHygieneScriptRejectsPublishableInternalSpecPathReferences() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-internal-path-references")
        defer { removeTemporaryURL(rootURL) }
        let referencedFiles = [
            "Spec/Chat/CurrentStatus.md": """
            This public status page must not point at Spec/Chat/Internal/Drafts/SourceMappingDraft.md.
            """,
            "Spec/AgentBridge/README.md": """
            This public README must not point at Spec/AgentBridge/Internal/Compaction/README.md.
            """
        ]
        for (path, contents) in referencedFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("local-internal-spec-reference-paths"), reportText)
        for path in referencedFiles.keys {
            XCTAssertTrue(reportText.contains(path), reportText)
        }
    }

    func testOpenSourceHygieneScriptAllowsCleanCodexApplyPatchVendorEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-clean-apply-patch-vendor")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanCodexApplyPatchVendorFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["blocked_path_count"] as? Int, 0)
        let sourceSets = report["source_sets"] as? [String]
        XCTAssertTrue(sourceSets?.contains("first-party local-host path scan") == true)
        XCTAssertTrue(sourceSets?.contains("Codex apply_patch vendor provenance and artifacts") == true)
        let ruleIDs = report["required_rule_ids"] as? [String]
        XCTAssertTrue(ruleIDs?.contains("first-party-local-host-paths") == true)
        XCTAssertTrue(ruleIDs?.contains("codex-apply-patch-vendor-hygiene") == true)
        XCTAssertTrue(ruleIDs?.contains("markstream-public-surface") == true)
    }

    func testOpenSourceHygieneScriptRejectsCodexApplyPatchBinaryArtifactsWithoutReceipt() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-apply-patch-vendor-missing-receipt")
        defer { removeTemporaryURL(rootURL) }
        let vendorRoot = try writeCleanCodexApplyPatchVendorFixture(rootURL: rootURL, writeReceipt: false)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("codex-apply-patch-vendor-hygiene"), reportText)
        XCTAssertTrue(
            reportText.contains("\(vendorRoot)/Artifacts/MSPCodexApplyPatchBridge.xcframework/BUILD_RECEIPT.txt"),
            reportText
        )
        XCTAssertTrue(reportText.contains("build receipt and checksums"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsCodexApplyPatchArtifactChecksumMismatch() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-apply-patch-vendor-bad-receipt")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanCodexApplyPatchVendorFixture(
            rootURL: rootURL,
            corruptDeviceArchiveChecksum: true
        )

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("BUILD_RECEIPT.txt"), reportText)
        XCTAssertTrue(reportText.contains("checksum does not match artifact file"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsCodexApplyPatchVendorLocalProvenanceAndArtifacts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-local-apply-patch-vendor")
        defer { removeTemporaryURL(rootURL) }
        let vendorRoot = "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch"
        let blockedFiles = [
            "\(vendorRoot)/README.md": "# Codex apply_patch Vendor Boundary\n",
            "\(vendorRoot)/Scripts/sync-codex-source.sh": """
            #!/usr/bin/env bash
            DEFAULT_CODEX_RS_SOURCE="/Users/example/local-codex/codex-rs"
            """,
            "\(vendorRoot)/Licenses/APACHE-2.0.txt": "Apache-2.0\n",
            "\(vendorRoot)/Licenses/CODEX-LICENSE-NOTE.md": "# Codex License Evidence\n",
            "\(vendorRoot)/Licenses/THIRD-PARTY-CARGO-LICENSES.json": #"{"packages":[]}"#,
            "\(vendorRoot)/Source/CODEX_SOURCE_PROVENANCE.txt": """
            source_git_head=8618aaa1739efcb8ea62269437db887a4d87b061
            source_relative_status_begin
            ?? core/src/local_only.rs
            source_relative_status_count=1
            source_relative_status_end
            source_path=/Volumes/Private/dev/codex-rs
            """,
            "\(vendorRoot)/Source/msp-codex-apply-patch-bridge/src/lib.rs": "pub fn bridge() {}\n"
        ]
        for (path, contents) in blockedFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let binaryPath = "\(vendorRoot)/Artifacts/MSPCodexApplyPatchBridge.xcframework/ios-arm64/libmsp_codex_apply_patch_bridge.a"
        let binaryURL = rootURL.appendingPathComponent(binaryPath)
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("!<arch>\ndebug path /Users/example/.cargo/registry/src\n".utf8).write(to: binaryURL)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("codex-apply-patch-vendor-hygiene"), reportText)
        XCTAssertTrue(reportText.contains("Source/CODEX_SOURCE_PROVENANCE.txt"), reportText)
        XCTAssertTrue(reportText.contains("Scripts/sync-codex-source.sh"), reportText)
        XCTAssertTrue(reportText.contains(binaryPath), reportText)
        XCTAssertTrue(reportText.contains("untracked or modified source files"), reportText)
        XCTAssertTrue(reportText.contains("local machine paths"), reportText)
    }

    func testExampleChatRendererVendorHygieneScriptAcceptsCleanFixture() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for renderer vendor hygiene tests.")
        }

        let rootURL = makeTemporaryURL("example-chat-renderer-vendor-hygiene-clean")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene-report.json")
        let result = try runExampleChatRendererVendorHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["finding_count"] as? Int, 0)
        let groupIDs = (report["required_asset_groups"] as? [[String: Any]])?
            .compactMap { $0["group_id"] as? String }
        XCTAssertTrue(groupIDs?.contains("katex") == true)
        XCTAssertTrue(groupIDs?.contains("prettier") == true)
        XCTAssertTrue(groupIDs?.contains("unified-markdown") == true)
        let checkedUnifiedMarkdown = report["checked_unified_markdown"] as? [String: Any]
        XCTAssertEqual(checkedUnifiedMarkdown?["actual_package_count"] as? Int, 4)
    }

    func testExampleChatRendererVendorHygieneScriptRejectsMissingThirdPartyLicenseEvidence() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for renderer vendor hygiene tests.")
        }

        let rootURL = makeTemporaryURL("example-chat-renderer-vendor-hygiene-missing-license")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)
        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent(
                "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/katex-LICENSE.txt"
            )
        )

        let reportURL = rootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene-report.json")
        let result = try runExampleChatRendererVendorHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("katex-LICENSE.txt"), reportText)
        XCTAssertTrue(reportText.contains("missing-third-party-license-evidence"), reportText)
    }

    func testExampleChatRendererVendorHygieneScriptRejectsIncompleteUnifiedMarkdownManifest() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for renderer vendor hygiene tests.")
        }

        let rootURL = makeTemporaryURL("example-chat-renderer-vendor-hygiene-unified-markdown")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources/Math/chat-unified-markdown-THIRD-PARTY.json",
            contents: """
            {
              "schema_version": 1,
              "asset": "RuntimeResources/Math/chat-unified-markdown.js",
              "package_count": 0,
              "licenses": [],
              "packages": []
            }
            """
        )

        let reportURL = rootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene-report.json")
        let result = try runExampleChatRendererVendorHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("chat-unified-markdown-THIRD-PARTY.json"), reportText)
        XCTAssertTrue(reportText.contains("missing-unified-markdown-third-party-package"), reportText)
    }

    func testExampleChatRendererVendorHygieneScriptRejectsVendorSymlinkOutsideSharedRenderer() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for renderer vendor hygiene tests.")
        }

        let rootURL = makeTemporaryURL("example-chat-renderer-vendor-hygiene-outside-symlink")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)

        let linkURL = rootURL.appendingPathComponent(
            "Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/RuntimeResources/Math/katex.min.js"
        )
        try FileManager.default.removeItem(at: linkURL)
        let outsideURL = rootURL.appendingPathComponent("outside-renderer/katex.min.js")
        try writeFile(rootURL: rootURL, relativePath: "outside-renderer/katex.min.js", contents: "var katex = {}\n")
        try createRelativeSymlink(at: linkURL, targetURL: outsideURL)

        let reportURL = rootURL.appendingPathComponent("example-chat-renderer-vendor-hygiene-report.json")
        let result = try runExampleChatRendererVendorHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("katex.min.js"), reportText)
        XCTAssertTrue(reportText.contains("outside-shared-root"), reportText)
    }

    func testOpenSourceLicenseNoticeScriptAcceptsCleanFixture() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for license/notice hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-license-notice-clean")
        defer { removeTemporaryURL(rootURL) }
        try writeFile(rootURL: rootURL, relativePath: "LICENSE", contents: "Project license fixture\n")
        try writeFile(
            rootURL: rootURL,
            relativePath: "NOTICE",
            contents: """
            Project license: see LICENSE.
            Codex apply_patch Apache-2.0 evidence: THIRD-PARTY-CARGO-LICENSES.json and CODEX_SOURCE_PROVENANCE.txt.
            ExampleChatTranscriptRenderer assets: chat-unified-markdown, mathjax-full, remark, micromark, KaTeX, highlight.js, Prettier, d3, markmap-view, pagedjs, legacy-spinner.
            LightweightReader generated Playwright evidence: desktop-ui-conformance.png and mobile-ui-conformance.png.
            SwiftPM dependency: swift-cgit2.
            Optional PhotoSorter dependencies: mlx-swift, mlx-swift-examples, swift-transformers.
            """
        )
        try writeCleanCodexApplyPatchVendorFixture(rootURL: rootURL)
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)
        try writeLightweightReaderGeneratedArtifactsFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("open-source-license-notice-report.json")
        let result = try runOpenSourceLicenseNotice(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["finding_count"] as? Int, 0)
    }

    func testOpenSourceLicenseNoticeScriptRejectsMissingRootLicense() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for license/notice hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-license-notice-missing-license")
        defer { removeTemporaryURL(rootURL) }
        try writeFile(
            rootURL: rootURL,
            relativePath: "NOTICE",
            contents: """
            Project license: see LICENSE.
            Codex apply_patch Apache-2.0 evidence: THIRD-PARTY-CARGO-LICENSES.json and CODEX_SOURCE_PROVENANCE.txt.
            ExampleChatTranscriptRenderer assets: chat-unified-markdown, mathjax-full, remark, micromark, KaTeX, highlight.js, Prettier, d3, markmap-view, pagedjs, legacy-spinner.
            LightweightReader generated Playwright evidence: desktop-ui-conformance.png and mobile-ui-conformance.png.
            SwiftPM dependency: swift-cgit2.
            Optional PhotoSorter dependencies: mlx-swift, mlx-swift-examples, swift-transformers.
            """
        )
        try writeCleanCodexApplyPatchVendorFixture(rootURL: rootURL)
        try writeCleanExampleChatRendererVendorFixture(rootURL: rootURL)
        try writeLightweightReaderGeneratedArtifactsFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("open-source-license-notice-report.json")
        let result = try runOpenSourceLicenseNotice(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("missing-root-license-notice-file"), reportText)
        XCTAssertTrue(reportText.contains("LICENSE"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsCodexApplyPatchUnscopedSourceSnapshot() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-apply-patch-unscoped-source")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanCodexApplyPatchVendorFixture(rootURL: rootURL)
        let extraPath = "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Source/codex-rs/vendor/bubblewrap/LICENSE"
        try writeFile(rootURL: rootURL, relativePath: extraPath, contents: "LGPL fixture\n")

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains(extraPath), reportText)
        XCTAssertTrue(reportText.contains("source snapshot must only ship files listed in source provenance"), reportText)
    }

    func testPhotoSorterDefaultPackageBoundaryScriptAcceptsCleanFixture() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for PhotoSorter package boundary tests.")
        }

        let rootURL = makeTemporaryURL("photosorter-default-package-boundary-clean")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: rootURL)

        let reportURL = rootURL.appendingPathComponent("photosorter-default-package-boundary-report.json")
        let result = try runPhotoSorterDefaultPackageBoundary(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["finding_count"] as? Int, 0)
        let versions = report["optional_dependency_versions"] as? [String: String]
        XCTAssertEqual(versions?["swift-transformers"], "0.1.18")
    }

    func testPhotoSorterDefaultPackageBoundaryScriptRejectsPublishableLocalFastVLMArtifacts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for PhotoSorter package boundary tests.")
        }

        let rootURL = makeTemporaryURL("photosorter-default-package-boundary-local-artifacts")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: rootURL)
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Resources/FastVLM/model/config.json",
            contents: "{}\n"
        )

        let reportURL = rootURL.appendingPathComponent("photosorter-default-package-boundary-report.json")
        let result = try runPhotoSorterDefaultPackageBoundary(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("publishable-local-fastvlm-artifact"), reportText)
        XCTAssertTrue(reportText.contains("Resources/FastVLM/model"), reportText)
    }

    func testPhotoSorterDefaultPackageBoundaryScriptAcceptsIgnoredLocalFastVLMArtifacts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for PhotoSorter package boundary tests.")
        }
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git is required for ignored local FastVLM artifact tests.")
        }

        let rootURL = makeTemporaryURL("photosorter-default-package-boundary-ignored-local-artifacts")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: rootURL)
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/.gitignore",
            contents: """
            Local/FastVLM/
            Project/PhotoSorter.local.xcodeproj/
            Resources/FastVLM/model/
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Resources/FastVLM/model/config.json",
            contents: "{}\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Local/FastVLM/FastVLM.swift",
            contents: "// local-only FastVLM source\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Project/PhotoSorter.local.xcodeproj/project.pbxproj",
            contents: "// local-only Xcode project\n"
        )

        let gitInit = try runProcess(
            executablePath: "/usr/bin/git",
            arguments: ["init"],
            currentDirectoryURL: rootURL
        )
        XCTAssertEqual(gitInit.exitCode, 0, gitInit.stderr)

        let reportURL = rootURL.appendingPathComponent("photosorter-default-package-boundary-report.json")
        let result = try runPhotoSorterDefaultPackageBoundary(rootURL: rootURL, reportURL: reportURL)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(reportURL)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["finding_count"] as? Int, 0)
    }

    func testPhotoSorterDefaultPackageBoundaryScriptRejectsDefaultXcodeMLXProducts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for PhotoSorter package boundary tests.")
        }

        let rootURL = makeTemporaryURL("photosorter-default-package-boundary-xcode-mlx")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: rootURL)
        let projectPath = "Examples/iOS/PhotoSorter/Project/PhotoSorter.xcodeproj/project.pbxproj"
        let projectURL = rootURL.appendingPathComponent(projectPath)
        let projectText = try String(contentsOf: projectURL, encoding: .utf8)
        try (projectText + """

        E00000000000000000000010 /* XCRemoteSwiftPackageReference "mlx-swift" */ = {
            isa = XCRemoteSwiftPackageReference;
            repositoryURL = "https://github.com/ml-explore/mlx-swift";
        };
        E0000000000000000000000E /* MLXVLM */ = {
            isa = XCSwiftPackageProductDependency;
            productName = MLXVLM;
        };
        """).write(to: projectURL, atomically: true, encoding: .utf8)

        let reportURL = rootURL.appendingPathComponent("photosorter-default-package-boundary-report.json")
        let result = try runPhotoSorterDefaultPackageBoundary(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("default-xcode-remote-mlx-package"), reportText)
        XCTAssertTrue(reportText.contains("default-xcode-mlx-vlm-product"), reportText)
    }

    func testPhotoSorterDefaultPackageBoundaryScriptRejectsUngatedOptionalPackageDependency() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for PhotoSorter package boundary tests.")
        }

        let rootURL = makeTemporaryURL("photosorter-default-package-boundary-ungated-package")
        defer { removeTemporaryURL(rootURL) }
        try writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: rootURL)
        let manifestPath = "Examples/iOS/PhotoSorter/Package.swift"
        let manifestURL = rootURL.appendingPathComponent(manifestPath)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        try (manifestText + """

        let accidentallyPublicDependency: Package.Dependency =
            .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.18")
        """).write(to: manifestURL, atomically: true, encoding: .utf8)

        let reportURL = rootURL.appendingPathComponent("photosorter-default-package-boundary-report.json")
        let result = try runPhotoSorterDefaultPackageBoundary(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains("ungated-local-fastvlm-package-marker"), reportText)
        XCTAssertTrue(reportText.contains("swift-transformers-package"), reportText)
    }

    func testOpenSourceHygieneScriptRejectsIndexOnlyStagedArtifacts() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for open-source hygiene tests.")
        }

        let rootURL = makeTemporaryURL("open-source-hygiene-index-only-staged-artifacts")
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let gitProbe = try runGit(["--version"], currentDirectoryURL: rootURL)
        guard gitProbe.exitCode == 0 else {
            throw XCTSkip("git is required for tracked-deleted open-source hygiene tests.")
        }
        let initResult = try runGit(["init"], currentDirectoryURL: rootURL)
        XCTAssertEqual(initResult.exitCode, 0, initResult.stderr)

        let blockedPath = ".build/debug/output.o"
        let blockedURL = rootURL.appendingPathComponent(blockedPath)
        try FileManager.default.createDirectory(
            at: blockedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "blocked\n".write(to: blockedURL, atomically: true, encoding: .utf8)
        let addResult = try runGit(["add", "-f", blockedPath], currentDirectoryURL: rootURL)
        XCTAssertEqual(addResult.exitCode, 0, addResult.stderr)
        try FileManager.default.removeItem(at: blockedURL)

        let reportURL = rootURL.appendingPathComponent("open-source-hygiene-report.json")
        let result = try runOpenSourceHygiene(rootURL: rootURL, reportURL: reportURL)

        XCTAssertNotEqual(result.exitCode, 0)
        let reportText = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(reportText.contains(blockedPath), reportText)
        XCTAssertTrue(reportText.contains("git-publishable"), reportText)
        XCTAssertTrue(reportText.contains("swift-and-xcode-build-output"), reportText)
    }

    func testFinalGateVerifierRejectsFailedOpenSourceReleaseDryRunReport() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-failed-open-source-release-dry-run")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dryRunURL = rootURL
            .appendingPathComponent("open-source-release-dry-run")
            .appendingPathComponent("open-source-release-dry-run-report.json")
        var dryRun = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dryRunURL)
        dryRun["passed"] = true
        dryRun["failures"] = []
        dryRun["release_tree_checks"] = [
            "path_findings": [
                [
                    "path": "artifacts/run.json",
                    "message": "root artifacts output must not be in the release tree",
                    "rule_id": "root-runtime-artifacts"
                ]
            ],
            "symlink_findings": []
        ]
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dryRun, to: dryRunURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("open-source release dry-run path_findings is missing or non-empty"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsPostTestGeneratedOpenSourceReleaseDryRunPaths() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-open-source-release-dry-run-post-test")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dryRunURL = rootURL
            .appendingPathComponent("open-source-release-dry-run")
            .appendingPathComponent("open-source-release-dry-run-report.json")
        var dryRun = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dryRunURL)
        dryRun["passed"] = true
        dryRun["failures"] = []
        dryRun["release_tree_checks"] = [
            "path_findings": [],
            "symlink_findings": [],
            "post_test_removed_paths": [],
            "post_test_generated_path_findings": [
                [
                    "path": "Examples/iOS/PhotoSorter/Package.resolved",
                    "message": "SwiftPM-generated package resolution files must not remain in the final release dry-run tree",
                    "rule_id": "swiftpm-generated-package-resolved"
                ]
            ]
        ]
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dryRun, to: dryRunURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("open-source release dry-run post_test_generated_path_findings is missing or non-empty"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsOpenSourceReleaseDryRunMissingSelfDescribingContract() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-open-source-release-dry-run-contract")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dryRunURL = rootURL
            .appendingPathComponent("open-source-release-dry-run")
            .appendingPathComponent("open-source-release-dry-run-report.json")
        var dryRun = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dryRunURL)
        dryRun["required_checks"] = []
        dryRun["failures"] = []
        dryRun["passed"] = true
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dryRun, to: dryRunURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("open-source release dry-run required_checks do not match required coverage"),
            failed.stderr
        )
    }

    func testFinalGateVerifierRejectsOpenSourceReleaseDryRunPublishRootOutsideReportDirectory() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for final gate verifier tests.")
        }

        let verifierURL = try finalGateVerifierURL()
        let rootURL = makeTemporaryURL("final-gate-verifier-open-source-release-dry-run-publish-root")
        defer { removeTemporaryURL(rootURL) }
        try ModelShellProxyPressureGateFixtureSupport.writeFinalGateFixture(
            rootURL: rootURL,
            matrixLooksLikeLinux: true
        )
        let dryRunURL = rootURL
            .appendingPathComponent("open-source-release-dry-run")
            .appendingPathComponent("open-source-release-dry-run-report.json")
        var dryRun = try ModelShellProxyPressureGateFixtureSupport.readJSONObject(dryRunURL)
        dryRun["publish_root"] = rootURL.path
        try ModelShellProxyPressureGateFixtureSupport.writeJSONObject(dryRun, to: dryRunURL)

        let failed = try runFinalGateVerifier(
            verifierURL: verifierURL,
            reportURL: rootURL.appendingPathComponent("final-exec-session-gate-report.json")
        )

        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertTrue(
            failed.stderr.contains("open-source release dry-run publish_root is outside report directory"),
            failed.stderr
        )
    }

    private func writeAuditedMSPChatUIMarkstreamFixture(rootURL: URL) throws {
        let uiRoot = "Implementations/UI/MSPChatUI"
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js",
            contents: "window.markstream = true;\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/Renderers/Default/runtime/markstream/README.md",
            contents: "The runtime is tracked by the Markstream bundle audit.\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/Renderers/Default/VENDOR_MANIFEST.md",
            contents: "readex-markstream-sdk.js is audited by markstream-bundle-license-audit.json.\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/THIRD_PARTY_NOTICES.md",
            contents: "readex-markstream-sdk.js is audited by markstream-bundle-license-audit.json.\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/package.json",
            contents: """
            {
              "scripts": {
                "check": "npm run check:licenses",
                "check:licenses": "node Conformance/scripts/license-audit.cjs"
              }
            }
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "\(uiRoot)/Conformance/fixtures/markstream-bundle-license-audit.json",
            contents: """
            {
              "schemaVersion": 1,
              "bundle": {
                "path": "Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js",
                "sha256": "98cb4fb5e5864ca0c413be4c895b2b663b96dedfb0a52b69646dbaf6720d2253",
                "bytes": 26
              },
              "source": {
                "packageLock": "Tools/ReadexMarkstreamRenderer/package-lock.json"
              },
              "allowedLicenses": ["MIT", "ISC", "(MPL-2.0 OR Apache-2.0)", "BSD-2-Clause", "BSD-3-Clause"],
              "licenseCounts": {"MIT": 1},
              "packages": [
                {"path": "node_modules/markstream-vue", "version": "1.0.3-beta.2", "license": "MIT"}
              ]
            }
            """
        )
    }

    @discardableResult
    private func writeCleanCodexApplyPatchVendorFixture(
        rootURL: URL,
        writeReceipt: Bool = true,
        corruptDeviceArchiveChecksum: Bool = false
    ) throws -> String {
        let vendorRoot = "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch"
        let provenanceSourcePaths = [
            "apply-patch/src/invocation.rs",
            "apply-patch/src/lib.rs",
            "apply-patch/src/parser.rs",
            "apply-patch/src/seek_sequence.rs",
            "apply-patch/src/standalone_executable.rs",
            "apply-patch/src/streaming_parser.rs",
            "core/src/tools/handlers/apply_patch.lark",
            "core/src/tools/handlers/apply_patch_spec.rs",
            "core/src/tools/runtimes/apply_patch.rs",
            "tools/src/responses_api.rs",
            "tools/src/tool_spec.rs",
            "utils/absolute-path/src/absolutize.rs",
            "utils/absolute-path/src/lib.rs"
        ]
        let fixtureBlobHash = "ee8c1ee49b4799bbd170233915a897c19e3b55e1"
        let provenance = (
            [
                "source_repository=https://github.com/openai/codex",
                "source_subdirectory=codex-rs",
                "source_git_head=d9aefa41599cbf987d8f0965c2f69ecb9f20da8f",
                "source_scope=codex-apply-patch-runtime-surface",
                "source_status_scope=source_files",
                "source_status_count=0",
                "source_files_begin"
            ]
            + provenanceSourcePaths.map { "git_blob_sha1=\(fixtureBlobHash) path=\($0)" }
            + ["source_files_end"]
        ).joined(separator: "\n") + "\n"
        let cleanFiles = [
            "\(vendorRoot)/README.md": "# Codex apply_patch Vendor Boundary\n",
            "\(vendorRoot)/Scripts/sync-codex-source.sh": "#!/usr/bin/env bash\n: \"${MSP_CODEX_RS_SOURCE:?}\"\n",
            "\(vendorRoot)/Licenses/APACHE-2.0.txt": "Apache-2.0\n",
            "\(vendorRoot)/Licenses/CODEX-LICENSE-NOTE.md": "# Codex License Evidence\n",
            "\(vendorRoot)/Licenses/THIRD-PARTY-CARGO-LICENSES.json": #"{"packages":[]}"#,
            "\(vendorRoot)/Source/CODEX_SOURCE_PROVENANCE.txt": provenance,
            "\(vendorRoot)/Source/msp-codex-apply-patch-bridge/src/lib.rs": "pub fn bridge() {}\n"
        ]
        for (path, contents) in cleanFiles {
            let url = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        for path in provenanceSourcePaths {
            let url = rootURL
                .appendingPathComponent(vendorRoot)
                .appendingPathComponent("Source/codex-rs")
                .appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "fixture\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let artifactFiles = [
            (
                "Info.plist",
                "plist\n",
                "dd0bb2ead5ab824acae117788aceb34cc6577b8f9ac4691c2e727252979d9eec",
                6
            ),
            (
                "ios-arm64/Headers/module.modulemap",
                "module MSPCodexApplyPatchBridge { header \"msp_codex_apply_patch_bridge.h\" export * }\n",
                "7a0493a23a41274ee212ba4dd714de0e356e2ae7c8d6566560035565e496d51f",
                85
            ),
            (
                "ios-arm64/Headers/msp_codex_apply_patch_bridge.h",
                "void msp_codex_apply_patch_free(void *buffer);\n",
                "80ba7070d1d9cd368ed9e1e6f044c425336d5d3175886502ec24fb4863ac432b",
                47
            ),
            (
                "ios-arm64/libmsp_codex_apply_patch_bridge.a",
                "!<arch>\nclean archive without host paths\n",
                corruptDeviceArchiveChecksum
                    ? "0000000000000000000000000000000000000000000000000000000000000000"
                    : "9e4f3ea313e8ef74b946c86b56b1f313b3472384a3be999636e2a2ee8f06f927",
                41
            ),
            (
                "ios-arm64-simulator/Headers/module.modulemap",
                "module MSPCodexApplyPatchBridge { header \"msp_codex_apply_patch_bridge.h\" export * }\n",
                "7a0493a23a41274ee212ba4dd714de0e356e2ae7c8d6566560035565e496d51f",
                85
            ),
            (
                "ios-arm64-simulator/Headers/msp_codex_apply_patch_bridge.h",
                "void msp_codex_apply_patch_free(void *buffer);\n",
                "80ba7070d1d9cd368ed9e1e6f044c425336d5d3175886502ec24fb4863ac432b",
                47
            ),
            (
                "ios-arm64-simulator/libmsp_codex_apply_patch_bridge.a",
                "!<arch>\nclean archive without host paths\n",
                "9e4f3ea313e8ef74b946c86b56b1f313b3472384a3be999636e2a2ee8f06f927",
                41
            )
        ]
        let artifactRoot = "\(vendorRoot)/Artifacts/MSPCodexApplyPatchBridge.xcframework"
        for artifact in artifactFiles {
            let url = rootURL
                .appendingPathComponent(artifactRoot)
                .appendingPathComponent(artifact.0)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(artifact.1.utf8).write(to: url)
        }

        if writeReceipt {
            let receipt = (
                [
                    "# Generated by fixture",
                    "format=msp-codex-apply-patch-artifact-receipt-v1",
                    "artifact=MSPCodexApplyPatchBridge.xcframework",
                    "source_provenance=Source/CODEX_SOURCE_PROVENANCE.txt",
                    "source_git_head=d9aefa41599cbf987d8f0965c2f69ecb9f20da8f",
                    "source_scope=codex-apply-patch-runtime-surface",
                    "build_script=Scripts/build-xcframework.sh",
                    "build_profile=release",
                    "rust_targets=aarch64-apple-ios,aarch64-apple-ios-sim",
                    "rustc_version=rustc fixture",
                    "cargo_version=cargo fixture",
                    "xcodebuild_version=Xcode fixture",
                    "strip_command=xcrun strip -S",
                    "debug_symbols=stripped",
                    "path_remap_policy=required",
                    "artifact_files_begin"
                ]
                + artifactFiles.map { "sha256=\($0.2) size=\($0.3) path=\($0.0)" }
                + ["artifact_files_end"]
            ).joined(separator: "\n") + "\n"
            let receiptURL = rootURL
                .appendingPathComponent(artifactRoot)
                .appendingPathComponent("BUILD_RECEIPT.txt")
            try receipt.write(to: receiptURL, atomically: true, encoding: .utf8)
        }

        return vendorRoot
    }

    private func writeCleanExampleChatRendererVendorFixture(rootURL: URL) throws {
        let sharedRoot = "Examples/iOS/Shared/ExampleChatTranscriptRenderer"
        let vendorRoots = [
            "Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer",
            "Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer"
        ]
        let sharedFiles = [
            "RuntimeResources/Math/katex.min.js": "var katex = {}\n",
            "RuntimeResources/Math/katex.min.css": """
            @font-face{font-family:KaTeX_Main;src:url(fonts/KaTeX_Main-Regular.woff2) format("woff2")}
            """,
            "RuntimeResources/Math/mhchem.min.js": "var mhchem = {}\n",
            "RuntimeResources/Math/copy-tex.min.js": "var copyTex = {}\n",
            "RuntimeResources/Math/chat-unified-markdown.js": """
            // node_modules/unified/index.js
            // node_modules/remark-parse/index.js
            // node_modules/micromark/index.js
            // node_modules/mathjax-full/js/mathjax.js
            """,
            "RuntimeResources/Math/chat-unified-markdown-THIRD-PARTY.json": """
            {
              "schema_version": 1,
              "asset": "RuntimeResources/Math/chat-unified-markdown.js",
              "package_count": 4,
              "licenses": [
                "Apache-2.0",
                "MIT"
              ],
              "packages": [
                {
                  "name": "mathjax-full",
                  "version": "3.2.2",
                  "license": "Apache-2.0"
                },
                {
                  "name": "micromark",
                  "version": "4.0.2",
                  "license": "MIT"
                },
                {
                  "name": "remark-parse",
                  "version": "11.0.0",
                  "license": "MIT"
                },
                {
                  "name": "unified",
                  "version": "11.0.5",
                  "license": "MIT"
                }
              ]
            }
            """,
            "RuntimeResources/Math/katex-LICENSE.txt": """
            The MIT License (MIT)
            Copyright (c) 2013-2020 Khan Academy and other contributors
            Permission is hereby granted
            """,
            "RuntimeResources/Math/legacy-spinner.apng": "apng fixture\n",
            "RuntimeResources/Math/PROJECT-ASSET-PROVENANCE.md": """
            legacy-spinner.apng is a project-local UI asset for the shared ExampleChatTranscriptRenderer.
            """,
            "RuntimeResources/Math/fonts/KaTeX_Main-Regular.woff2": "font\n",
            "RuntimeResources/Math/highlight.min.js": "var hljs = {}\n",
            "RuntimeResources/Math/highlight-github.min.css": ".hljs{}\n",
            "RuntimeResources/Math/highlight-github-dark.min.css": ".hljs{}\n",
            "RuntimeResources/Math/highlightjs-LICENSE.txt": """
            BSD 3-Clause License
            Ivan Sagalaev
            Redistribution and use
            """,
            "RuntimeResources/Math/prettier-standalone.js": "var prettier = {}\n",
            "RuntimeResources/Math/prettier-parser-babel.js": "var parser = {}\n",
            "RuntimeResources/Math/prettier-parser-html.js": "var parser = {}\n",
            "RuntimeResources/Math/prettier-parser-postcss.js": "var parser = {}\n",
            "RuntimeResources/Math/prettier-parser-typescript.js": "var parser = {}\n",
            "RuntimeResources/Math/prettier-LICENSE.txt": """
            Prettier license
            James Long and contributors
            Permission is hereby granted
            """,
            "RuntimeResources/KnowledgeMap/d3.min.js": "var d3 = {}\n",
            "RuntimeResources/KnowledgeMap/d3-LICENSE.txt": """
            Mike Bostock
            Permission to use, copy, modify
            THE SOFTWARE IS PROVIDED
            """,
            "RuntimeResources/KnowledgeMap/markmap-view.js": "var markmap = {}\n",
            "RuntimeResources/KnowledgeMap/markmap-view-LICENSE.txt": """
            MIT License
            Copyright (c) 2020 Gerald
            Permission is hereby granted
            """,
            "RuntimeResources/Paged/paged.polyfill.js": "var paged = {}\n",
            "RuntimeResources/Paged/pagedjs-LICENSE.md": """
            The MIT License (MIT)
            Copyright (c) 2018 Adam Hyde
            Permission is hereby granted
            """
        ]

        try writeFile(
            rootURL: rootURL,
            relativePath: "\(sharedRoot)/VENDOR_MANIFEST.md",
            contents: """
            # Shared Example Chat Transcript Renderer Manifest

            This directory contains renderer files that are byte-for-byte shared.
            Third-party markdown, math, highlighting, document, paged, and knowledge-map resources are bundled here.
            chat-unified-markdown-THIRD-PARTY.json records MathJax, remark, micromark, and related markdown packages.
            legacy-spinner.apng is a project-local UI asset.
            """
        )
        for (relativePath, contents) in sharedFiles {
            try writeFile(
                rootURL: rootURL,
                relativePath: "\(sharedRoot)/\(relativePath)",
                contents: contents
            )
        }

        for vendorRoot in vendorRoots {
            let exampleName = vendorRoot.contains("PhotoSorter") ? "PhotoSorter" : "MSPPlaygroundApp example"
            try writeFile(
                rootURL: rootURL,
                relativePath: "\(vendorRoot)/VENDOR_MANIFEST.md",
                contents: """
                # Example Transcript Renderer Vendor Manifest

                This directory contains the transcript-rendering assets used by the \(exampleName).
                The vendored surface is intentionally limited to example UI rendering support.
                chat-unified-markdown-THIRD-PARTY.json and legacy-spinner.apng are part of the shared renderer evidence surface.
                The old request construction files are not part of this public vendor surface.
                Non-renderer source archives and local machine paths must not be added here.
                """
            )
            for relativePath in sharedFiles.keys {
                let linkURL = rootURL.appendingPathComponent("\(vendorRoot)/\(relativePath)")
                let targetURL = rootURL.appendingPathComponent("\(sharedRoot)/\(relativePath)")
                try createRelativeSymlink(at: linkURL, targetURL: targetURL)
            }
        }
    }

    private func writeLightweightReaderGeneratedArtifactsFixture(rootURL: URL) throws {
        try writeFile(
            rootURL: rootURL,
            relativePath: "Spec/Chat/Demos/LightweightReader/results/GENERATED_ARTIFACTS.md",
            contents: """
            LightweightReader generated Playwright UI evidence:
            desktop-ui-conformance.png
            mobile-ui-conformance.png
            """
        )
    }

    private func writeCleanPhotoSorterDefaultPackageBoundaryFixture(rootURL: URL) throws {
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Package.swift",
            contents: """
            // swift-tools-version: 6.2

            import Foundation
            import PackageDescription

            let packageDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let localFastVLMSourcePath = "Local/FastVLM"
            let localFastVLMSourceURL = packageDirectoryURL
                .appendingPathComponent(localFastVLMSourcePath, isDirectory: true)
                .appendingPathComponent("FastVLM.swift")
            let includeLocalFastVLM = ProcessInfo.processInfo.environment["PHOTOSORTER_ENABLE_LOCAL_FASTVLM"] == "1"
                && FileManager.default.fileExists(atPath: localFastVLMSourceURL.path)

            let packageDependencies: [Package.Dependency] = [
                .package(name: "ModelShellProxy", path: "../../../Implementations/Swift")
            ] + (includeLocalFastVLM ? [
                .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.21.2"),
                .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.21.2"),
                .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.18")
            ] : [])

            let photoSorterTargetDependencies: [Target.Dependency] = [
                .product(name: "ModelShellProxy", package: "ModelShellProxy")
            ] + (includeLocalFastVLM ? [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLXVLM", package: "mlx-swift-examples"),
                .product(name: "Transformers", package: "swift-transformers")
            ] : [])

            let photoSorterSources = [
                "App"
            ] + (includeLocalFastVLM ? [localFastVLMSourcePath] : [])

            let photoSorterResources: [Resource] = [
            ] + (includeLocalFastVLM ? [
                .copy("Resources/FastVLM")
            ] : [])

            let photoSorterExcludes = [
                "Project",
                "Tests",
                "Tools"
            ] + (includeLocalFastVLM ? [
                "Local/README.md"
            ] : [
                "Local",
                "Resources/FastVLM"
            ])

            let package = Package(
                name: "PhotoSorter",
                dependencies: packageDependencies,
                targets: [
                    .executableTarget(
                        name: "PhotoSorter",
                        dependencies: photoSorterTargetDependencies,
                        path: ".",
                        exclude: photoSorterExcludes,
                        sources: photoSorterSources,
                        resources: photoSorterResources
                    )
                ]
            )
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Project/PhotoSorter.xcodeproj/project.pbxproj",
            contents: """
            /* Begin XCLocalSwiftPackageReference section */
                    E00000000000000000000005 /* XCLocalSwiftPackageReference "../../../../Implementations/Swift" */ = {
                        isa = XCLocalSwiftPackageReference;
                        relativePath = ../../../../Implementations/Swift;
                    };
            /* End XCLocalSwiftPackageReference section */
            /* Begin XCSwiftPackageProductDependency section */
                    E00000000000000000000002 /* ModelShellProxy */ = {
                        isa = XCSwiftPackageProductDependency;
                        package = E00000000000000000000005 /* XCLocalSwiftPackageReference "../../../../Implementations/Swift" */;
                        productName = ModelShellProxy;
                    };
            /* End XCSwiftPackageProductDependency section */
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Package.resolved",
            contents: #"{"pins":[{"identity":"swift-cgit2"}],"version":3}"# + "\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/README.md",
            contents: """
            The default open-source package does not include copied FastVLM source, model weights, or MLX package products.
            Local FastVLM live inference is opt-in with PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1.
            Keep copied source in Local/FastVLM/, model files in Resources/FastVLM/model/, and local Xcode changes in Project/PhotoSorter.local.xcodeproj.
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Vendor/README.md",
            contents: """
            PhotoSorter consumes optional packages through public SwiftPM references:
            - mlx-swift 0.21.2
            - mlx-swift-examples 2.21.2
            - swift-transformers 0.1.18
            The default open-source package and Xcode project do not include MLX package products.
            """
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Local/README.md",
            contents: "Use Local/FastVLM/ only with PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1.\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Resources/FastVLM/README.md",
            contents: "Model files live in ignored Resources/FastVLM/model/. Source lives in Local/FastVLM/ with PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1.\n"
        )
        try writeFile(
            rootURL: rootURL,
            relativePath: "Examples/iOS/PhotoSorter/Tools/check-local-packages.sh",
            contents: """
            #!/usr/bin/env bash
            : "${PHOTOSORTER_ENABLE_LOCAL_FASTVLM:-}"
            echo Vendor/mlx-swift
            echo Vendor/mlx-swift-examples
            echo swift-transformers
            """
        )
    }

    private func writeFile(rootURL: URL, relativePath: String, contents: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createRelativeSymlink(at linkURL: URL, targetURL: URL) throws {
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = relativeSymlinkTarget(from: linkURL, to: targetURL)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
    }

    private func relativeSymlinkTarget(from linkURL: URL, to targetURL: URL) -> String {
        let sourceComponents = linkURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .pathComponents
        let targetComponents = targetURL
            .standardizedFileURL
            .pathComponents
        var sharedPrefixCount = 0
        let sharedLimit = min(sourceComponents.count, targetComponents.count)
        while sharedPrefixCount < sharedLimit,
              sourceComponents[sharedPrefixCount] == targetComponents[sharedPrefixCount] {
            sharedPrefixCount += 1
        }
        var components = Array(repeating: "..", count: sourceComponents.count - sharedPrefixCount)
        components.append(contentsOf: targetComponents.dropFirst(sharedPrefixCount))
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func runExampleChatRendererVendorHygiene(rootURL: URL, reportURL: URL) throws -> ProcessResult {
        let scriptURL = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("check_example_chat_renderer_vendor_hygiene.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--root",
            rootURL.path,
            "--report",
            reportURL.path
        ]
        process.environment = [
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]

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

    private func runPhotoSorterDefaultPackageBoundary(rootURL: URL, reportURL: URL) throws -> ProcessResult {
        let scriptURL = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("check_photosorter_default_package_boundary.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--root",
            rootURL.path,
            "--report",
            reportURL.path
        ]
        process.environment = [
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]

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

    private func runProcess(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

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

    private func runOpenSourceLicenseNotice(rootURL: URL, reportURL: URL) throws -> ProcessResult {
        let scriptURL = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("check_open_source_license_notice.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--root",
            rootURL.path,
            "--report",
            reportURL.path
        ]
        process.environment = [
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]

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

    private func runOpenSourceHygiene(rootURL: URL, reportURL: URL) throws -> ProcessResult {
        let scriptURL = try ModelShellProxyConformanceSupport.packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("check_open_source_hygiene.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptURL.path,
            "--root",
            rootURL.path,
            "--report",
            reportURL.path
        ]
        process.environment = [
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]

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

    private func runGit(_ arguments: [String], currentDirectoryURL: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = currentDirectoryURL

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
}

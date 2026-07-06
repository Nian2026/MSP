import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateOpenSourceHygieneFixture(rootURL: URL) throws -> URL {
        let reportURL = rootURL
            .appendingPathComponent("open-source-hygiene")
            .appendingPathComponent("open-source-hygiene-report.json")
        try writeJSONObject([
            "passed": true,
            "gate": "msp-open-source-hygiene",
            "root": rootURL.path,
            "source_sets": [
                "git tracked and untracked non-ignored files",
                "filesystem hygiene sentinel paths",
                "first-party local-host path scan",
                "Codex CLI validation local-host path scan",
                "Codex apply_patch vendor provenance and artifacts"
            ],
            "required_rule_ids": [
                "macos-finder-metadata",
                "python-bytecode-cache",
                "swift-and-xcode-build-output",
                "private-construction-state",
                "root-runtime-artifacts",
                "example-backups-and-build-mcp",
                "bundled-js-output",
                "internal-validation-results",
                "internal-chat-spec-drafts",
                "local-linux-source-snapshot",
                "local-codex-source-snapshot",
                "local-readex-reference-snapshot",
                "first-party-local-host-paths",
                "codex-validation-local-host-paths",
                "codex-apply-patch-vendor-hygiene"
            ],
            "git_publishable_path_count": 42,
            "scanned_path_count": 42,
            "blocked_path_count": 0,
            "blocked_paths": [],
            "failures": []
        ], to: reportURL)
        return reportURL
    }
}

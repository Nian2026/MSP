import Foundation

extension ModelShellProxyPressureGateFixtureSupport {
    static func writeFinalGateReadexBoundaryFixture(rootURL: URL) throws -> URL {
        try prepareFinalGateReadexBoundaryRepositoryFixture(rootURL: rootURL)
        let reportURL = rootURL.appendingPathComponent("readex-boundary-report.json")
        try writeJSONObject([
            "passed": true,
            "failures": [],
            "root": rootURL.resolvingSymlinksInPath().path,
            "read_only_snapshot_dirs": [
                "References/ReadexShellSnapshot",
                "References/ReadexReadingAgentSnapshot"
            ],
            "dirty_snapshot_status": [],
            "forbidden_external_readex_markers": [
                "/Volumes/PrivateReference/Projects/Readex",
                "/Volumes/PrivateReference/Projects/Readex-Internal",
                "PrivateReadexReferenceApp",
                "PRIVATE_READEX_REFERENCE_",
                "READEX_SOURCE_ROOT",
                "READOS_SOURCE_ROOT"
            ],
            "script_scan_roots": [
                "Conformance/Scripts",
                "Examples/iOS/MSPPlaygroundApp/Tools/E2E",
                "Examples/iOS/PhotoSorter/Tools/E2E"
            ],
            "scanned_script_count": 1,
            "scanned_scripts": [
                "Conformance/Scripts/final-gate-fixture.sh"
            ]
        ], to: reportURL)
        return reportURL
    }

    private static func prepareFinalGateReadexBoundaryRepositoryFixture(rootURL: URL) throws {
        let fileManager = FileManager.default
        for relativePath in [
            "References/ReadexShellSnapshot",
            "References/ReadexReadingAgentSnapshot",
            "Conformance/Scripts"
        ] {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(relativePath),
                withIntermediateDirectories: true
            )
        }

        let fixtureScript = rootURL
            .appendingPathComponent("Conformance")
            .appendingPathComponent("Scripts")
            .appendingPathComponent("final-gate-fixture.sh")
        try "#!/bin/sh\nprintf 'fixture\\n'\n".write(to: fixtureScript, atomically: true, encoding: .utf8)

        try runGit(["init", "--quiet"], currentDirectoryURL: rootURL)
    }

    private static func runGit(_ arguments: [String], currentDirectoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "ModelShellProxyPressureGateFixtureSupport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
    }
}

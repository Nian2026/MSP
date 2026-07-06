import XCTest
@testable import MSPPlaygroundApp

@MainActor
final class MSPPlaygroundWorkspaceProfileTests: XCTestCase {
    func testBootstrapKeepsSeedMarkerOutsideModelVisibleWorkspace() throws {
        let rootURL = makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileManager = SearchRootFileManager(rootURL: rootURL)

        let workspaceURL = try MSPPlaygroundWorkspaceBootstrap.prepareWorkspace(fileManager: fileManager)
        let containerURL = rootURL.appendingPathComponent("MSPPlaygroundApp", isDirectory: true)
        let hiddenMarkerURL = containerURL.appendingPathComponent(".msp-playground-seeded")
        let legacyMarkerURL = workspaceURL.appendingPathComponent(".msp-playground-seeded")

        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenMarkerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMarkerURL.path))

        try Data().write(to: legacyMarkerURL)
        _ = try MSPPlaygroundWorkspaceBootstrap.prepareWorkspace(fileManager: fileManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyMarkerURL.path))

        let readmeURL = workspaceURL.appendingPathComponent("README.md")
        try FileManager.default.removeItem(at: readmeURL)
        _ = try MSPPlaygroundWorkspaceBootstrap.prepareWorkspace(fileManager: fileManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: readmeURL.path))
    }

    func testWorkspaceProfileCanBeSelectedFromEnvironmentOrLaunchArgument() {
        XCTAssertEqual(
            MSPPlaygroundWorkspaceProfile.configured(
                arguments: ["MSPPlaygroundApp"],
                environment: [:]
            ),
            .hostBacked
        )
        XCTAssertEqual(
            MSPPlaygroundWorkspaceProfile.configured(
                arguments: ["MSPPlaygroundApp"],
                environment: ["MSP_PLAYGROUND_WORKSPACE_PROFILE": "mixed-backend"]
            ),
            .mixedBackend
        )
        XCTAssertEqual(
            MSPPlaygroundWorkspaceProfile.configured(
                arguments: ["MSPPlaygroundApp", "--msp-workspace-profile", "mixed"],
                environment: [:]
            ),
            .mixedBackend
        )
    }

    func testHostBackedShellMutationsImmediatelyUpdateWorkspaceSnapshot() async throws {
        let rootURL = makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            workspaceProfile: .hostBacked,
            arguments: [],
            environment: [:]
        )
        let result = await runtime.run("""
        mkdir -p /tmp/ui-sync /docs
        printf 'alpha\\n' > /tmp/ui-sync/alpha.txt
        printf 'beta\\n' > /docs/beta.txt
        mv /tmp/ui-sync/alpha.txt /tmp/ui-sync/alpha-renamed.txt
        rm /docs/beta.txt
        find /tmp/ui-sync /docs -maxdepth 1 -print | sort
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        /docs
        /tmp/ui-sync
        /tmp/ui-sync/alpha-renamed.txt

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))

        let snapshotPaths = try runtime.snapshotWorkspace(maxDepth: 3)
            .flatMap(Self.flatten)
            .map(\.path)
            .sorted()
        XCTAssertTrue(snapshotPaths.contains("/tmp/ui-sync/alpha-renamed.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertFalse(snapshotPaths.contains("/tmp/ui-sync/alpha.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/docs"), snapshotPaths.joined(separator: "\n"))
        XCTAssertFalse(snapshotPaths.contains("/docs/beta.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertFalse(snapshotPaths.contains { $0.contains(rootURL.path) }, snapshotPaths.joined(separator: "\n"))
    }

    func testMixedWorkspaceProfileFeedsShellAndWorkspaceSnapshotFromSameWorld() async throws {
        let rootURL = makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "host-doc\n".write(
            to: rootURL.appendingPathComponent("docs/host.txt"),
            atomically: true,
            encoding: .utf8
        )

        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            workspaceProfile: .mixedBackend,
            arguments: [],
            environment: [:]
        )
        let result = await runtime.run("""
        cat /docs/host.txt /media/clip.txt
        printf 'host-write\\n' > /tmp/generated.txt
        printf 'media-write\\n' > /media/generated.txt
        find /tmp /docs /media -maxdepth 1 -type f | sort
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        host-doc
        virtual-media
        /docs/host.txt
        /media/clip.txt
        /media/generated.txt
        /tmp/generated.txt

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/generated.txt"), encoding: .utf8),
            "host-write\n"
        )

        let snapshotPaths = try runtime.snapshotWorkspace(maxDepth: 2)
            .flatMap(Self.flatten)
            .map(\.path)
            .sorted()
        XCTAssertTrue(snapshotPaths.contains("/docs"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/docs/host.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/tmp"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/tmp/generated.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/media"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/media/clip.txt"), snapshotPaths.joined(separator: "\n"))
        XCTAssertTrue(snapshotPaths.contains("/media/generated.txt"), snapshotPaths.joined(separator: "\n"))

        let listing = await runtime.run("ls -ld /media\n")
        XCTAssertEqual(listing.stderr, "")
        XCTAssertEqual(listing.exitCode, 0, listing.stderr)
        XCTAssertTrue(listing.stdout.contains("/media\n"), listing.stdout)
        XCTAssertFalse(listing.stdout.contains("1970"), listing.stdout)
    }

    func testGitLaunchFlagEnablesLibGit2BackedCommand() async throws {
        let rootURL = makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            workspaceProfile: .hostBacked,
            arguments: ["MSPPlaygroundApp", "--msp-enable-git"],
            environment: [:]
        )

        var result = await runtime.run("mkdir -p /docs\nprintf 'hello\\n' > /docs/a.txt\ngit init\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Initialized empty Git repository in /.git/\n")
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))

        result = await runtime.run("git status --short\n")
        XCTAssertEqual(result.stdout, "?? docs/\n")
        XCTAssertEqual(result.stderr, "")

        result = await runtime.run("git add /docs/a.txt\ngit diff --cached --no-color --no-ext-diff -- /docs/a.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        diff --git a/docs/a.txt b/docs/a.txt
        new file mode 100644
        index 0000000..ce01362
        --- /dev/null
        +++ b/docs/a.txt
        @@ -0,0 +1 @@
        +hello

        """)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
    }

    func testQuickLookURLMaterializesVirtualWorkspaceTextFile() throws {
        let rootURL = makeTemporaryWorkspaceURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            workspaceProfile: .mixedBackend,
            arguments: [],
            environment: [:]
        )

        let previewURL = try runtime.quickLookURL(for: "/media/clip.txt")
        defer { try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent()) }

        XCTAssertEqual(previewURL.pathExtension, "txt")
        XCTAssertEqual(previewURL.lastPathComponent, "clip.txt")
        XCTAssertNotEqual(previewURL.deletingLastPathComponent().lastPathComponent, "MSPPlaygroundQuickLook")
        XCTAssertEqual(try String(contentsOf: previewURL, encoding: .utf8), "virtual-media\n")
        XCTAssertFalse(previewURL.path.contains(rootURL.path))
    }

    func testQuickLookPreviewFileNameSanitizesPathComponent() {
        XCTAssertEqual(
            MSPPlaygroundShellRuntime.previewFileName(for: "/docs/bad:name.md"),
            "bad_name.md"
        )
    }

    private static func flatten(_ node: WorkspaceFileNode) -> [WorkspaceFileNode] {
        [node] + (node.children ?? []).flatMap(flatten)
    }

    private func makeTemporaryWorkspaceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPPlaygroundWorkspaceProfileTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class SearchRootFileManager: FileManager {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        [rootURL]
    }
}

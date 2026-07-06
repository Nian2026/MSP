import Foundation
import XCTest

extension MSPPOSIXCoreFileOperationCommandTests {
    func testMktempCreatesThroughWorkspaceWithoutReadingOrListing() async throws {
        let workspace = WorkerEWorkspace(entries: ["/": .directory])

        let result = await runCommand("mktemp", ["case.XXXXXX"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.hasPrefix("case."))
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines).count, "case.".count + 6)
        XCTAssertEqual(workspace.fileSystemBox.writeFileCalls.count, 1)
        XCTAssertEqual(workspace.fileSystemBox.writeFileCalls.first?.data, Data())
        XCTAssertEqual(workspace.fileSystemBox.writeFileCalls.first?.options, [])
        XCTAssertEqual(workspace.fileSystemBox.chmodCalls.count, 1)
        XCTAssertEqual(workspace.fileSystemBox.chmodCalls.first?.mode, 0o600)
        XCTAssertEqual(workspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(workspace.fileSystemBox.readFileCallCount, 0)
    }

    func testMktempDryRunPrintsNameWithoutCreating() async throws {
        let workspace = WorkerEWorkspace(entries: ["/": .directory])

        let result = await runCommand("mktemp", ["-u", "case.XXXXXX"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.hasPrefix("case."))
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines).count, "case.".count + 6)
        XCTAssertTrue(workspace.fileSystemBox.writeFileCalls.isEmpty)
        XCTAssertTrue(workspace.fileSystemBox.chmodCalls.isEmpty)
    }

    func testMktempSuffixAppendsAfterFinalXRun() async throws {
        let workspace = WorkerEWorkspace(entries: ["/": .directory])

        let result = await runCommand(
            "mktemp",
            ["--suffix=.tmp", "case.XXXXXX"],
            workspace: workspace
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.range(
            of: #"^case\.[A-Za-z0-9]{6}\.tmp\n$"#,
            options: .regularExpression
        ) != nil, result.stdout)
        XCTAssertEqual(workspace.fileSystemBox.writeFileCalls.count, 1)
        XCTAssertTrue(workspace.fileSystemBox.writeFileCalls[0].path.hasSuffix(".tmp"))
    }

    func testMktempSuffixRejectsSlashAndTemplateNotEndingInX() async throws {
        let workspace = WorkerEWorkspace(entries: ["/": .directory])

        let slash = await runCommand("mktemp", ["--suffix=a/b", "case.XXXXXX"], workspace: workspace)
        XCTAssertEqual(slash.exitCode, 1)
        XCTAssertEqual(slash.stderr, "mktemp: invalid suffix \u{2018}a/b\u{2019}, contains directory separator\n")

        let notEndingInX = await runCommand("mktemp", ["--suffix=.tmp", "case.XXXtail"], workspace: workspace)
        XCTAssertEqual(notEndingInX.exitCode, 1)
        XCTAssertEqual(notEndingInX.stderr, "mktemp: with --suffix, template \u{2018}case.XXXtail\u{2019} must end in X\n")
        XCTAssertTrue(workspace.fileSystemBox.writeFileCalls.isEmpty)
    }

    func testTouchAcceptsDateAndReferenceSourcesWhenCreatingFiles() async throws {
        let dateWorkspace = WorkerEWorkspace(entries: ["/": .directory])

        let date = await runCommand("touch", ["-d", "@0", "f"], workspace: dateWorkspace)

        XCTAssertEqual(date.exitCode, 0)
        XCTAssertEqual(date.stderr, "")
        XCTAssertEqual(dateWorkspace.fileSystemBox.writeFileCalls.map(\.path), ["f"])

        let referenceWorkspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/ref": .file(Data())
        ])

        let reference = await runCommand("touch", ["-r", "ref", "f"], workspace: referenceWorkspace)

        XCTAssertEqual(reference.exitCode, 0)
        XCTAssertEqual(reference.stderr, "")
        XCTAssertEqual(referenceWorkspace.fileSystemBox.writeFileCalls.map(\.path), ["f"])
    }

    func testFileClassifiesDirectoriesAndSymlinksWithoutReadingContents() async throws {
        let workspace = WorkerEWorkspace(entries: [
            "/": .directory,
            "/docs": .directory,
            "/docs-link": .symlink("/docs")
        ])

        let result = await runCommand("file", ["docs", "docs-link"], workspace: workspace)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "docs: directory\ndocs-link: symbolic link\n")
        XCTAssertEqual(workspace.fileSystemBox.readFileCallCount, 0)
    }

    func testBasenameAndDirnameStayPureStringUtilities() async throws {
        let basename = await runCommand("basename", ["-a", "/tmp/archive.tar.gz", "plain"])
        let dirname = await runCommand("dirname", ["///a///b", "plain", "/"])

        XCTAssertEqual(basename.exitCode, 0)
        XCTAssertEqual(basename.stdout, "archive.tar.gz\nplain\n")
        XCTAssertEqual(dirname.exitCode, 0)
        XCTAssertEqual(dirname.stdout, "///a\n.\n/\n")
    }
}

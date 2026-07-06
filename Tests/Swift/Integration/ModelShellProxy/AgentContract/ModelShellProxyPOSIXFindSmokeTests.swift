import Foundation
import XCTest
import ModelShellProxy
import MSPCore
import MSPExternalRunner

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testPOSIXCoreFindSearchesWorkspaceWithVirtualPathsOnly() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs/nested"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta\n".write(
            to: rootURL.appendingPathComponent("docs/nested/b.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("find /docs -maxdepth 2 -type f -name '*.txt' -print")

        XCTAssertEqual(Set(result.stdout.split(separator: "\n").map(String.init)), Set([
            "/docs/a.txt",
            "/docs/nested/b.txt"
        ]))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindCanRunThroughVirtualAbsoluteCommandPath() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("""
        /usr/bin/find /docs -maxdepth 1 -type f -print
        /bin/find /docs -maxdepth 1 -type f -print
        """)

        XCTAssertEqual(result.stdout, "/docs/a.txt\n/docs/a.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
        XCTAssertFalse(result.stderr.contains(rootURL.path))
    }

    func testPOSIXCoreFindExecutionRespectsVirtualPATH() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let hidden = await shell.run("PATH=/nope find /docs -maxdepth 1 -type f -print")
        let visible = await shell.run("PATH=/bin find /docs -maxdepth 1 -type f -print")
        let explicit = await shell.run("PATH=/nope /usr/bin/find /docs -maxdepth 1 -type f -print")

        XCTAssertEqual(hidden.stdout, "")
        XCTAssertEqual(hidden.stderr, "find: command not found\n")
        XCTAssertEqual(hidden.exitCode, 127)
        XCTAssertEqual(visible.stdout, "/docs/a.txt\n")
        XCTAssertEqual(visible.stderr, "")
        XCTAssertEqual(visible.exitCode, 0)
        XCTAssertEqual(explicit.stdout, "/docs/a.txt\n")
        XCTAssertEqual(explicit.stderr, "")
        XCTAssertEqual(explicit.exitCode, 0)
        XCTAssertFalse((hidden.stdout + hidden.stderr + visible.stdout + explicit.stdout).contains(rootURL.path))
    }

    func testRegisteredCommandLookupPathCanRunThroughVirtualAbsoluteCommandPath() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .registerExternalCommand(
                "hello-tool",
                commandLookupPaths: ["/opt/msp/bin/hello-tool"],
                runner: RecordingLookupPathRunner()
            )

        let result = await shell.run("/opt/msp/bin/hello-tool one two")
        let defaultPath = await shell.run("/usr/bin/hello-tool one two")
        let bareDefault = await shell.run("hello-tool one two")
        let bareWithPath = await shell.run("PATH=/opt/msp/bin hello-tool one two")

        XCTAssertEqual(result.stdout, "hello-tool:one,two\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(defaultPath.stdout, "")
        XCTAssertEqual(defaultPath.stderr, "/usr/bin/hello-tool: No such file or directory\n")
        XCTAssertEqual(defaultPath.exitCode, 127)
        XCTAssertEqual(bareDefault.stdout, "")
        XCTAssertEqual(bareDefault.stderr, "hello-tool: command not found\n")
        XCTAssertEqual(bareDefault.exitCode, 127)
        XCTAssertEqual(bareWithPath.stdout, "hello-tool:one,two\n")
        XCTAssertEqual(bareWithPath.stderr, "")
        XCTAssertEqual(bareWithPath.exitCode, 0)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
        XCTAssertFalse(result.stderr.contains(rootURL.path))
        XCTAssertFalse(defaultPath.stderr.contains(rootURL.path))
        XCTAssertFalse(bareDefault.stderr.contains(rootURL.path))
        XCTAssertFalse(bareWithPath.stdout.contains(rootURL.path))
    }

    func testSubcommandUtilitiesAcceptVirtualAbsoluteCommandPaths() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta\n".write(
            to: rootURL.appendingPathComponent("docs/b.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("""
        env /usr/bin/find /docs -maxdepth 1 -type f -printf 'env:%f\\n' | sort
        command /bin/find /docs -maxdepth 1 -type f -printf 'command:%f\\n' | sort
        printf 'left\\0right\\0' | xargs -0 -n 1 /bin/printf 'xargs:%s\\n'
        find /docs -maxdepth 1 -type f -exec /usr/bin/printf 'exec:%s\\n' {} + | sort
        """)

        XCTAssertEqual(result.stdout, """
        env:a.txt
        env:b.txt
        command:a.txt
        command:b.txt
        xargs:left
        xargs:right
        exec:/docs/a.txt
        exec:/docs/b.txt

        """)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testPOSIXCoreFindSupportsExpressionPredicatesAndActions() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs/nested"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: rootURL.appendingPathComponent("docs/empty.dat"))
        try "beta\n".write(
            to: rootURL.appendingPathComponent("docs/nested/b.md"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let modeSetup = await shell.run("chmod 600 docs/a.txt")
        let relativePath = await shell.run("find docs -maxdepth 1 -type f -name '*.txt' -print")
        let emptyOutsideNested = await shell.run("find docs -path 'docs/nested/*' -o -type f -empty -print")
        let formatted = await shell.run("find /docs -maxdepth 1 ! -name '*.md' -type f -printf '%p:%s:%y\\n'")
        let sizeAndMode = await shell.run("find /docs -maxdepth 1 -type f -size 6c -perm 600 -print")
        let nulSeparated = await shell.run("find /docs -maxdepth 1 -type f -name '*.txt' -print0")

        XCTAssertEqual(modeSetup.stderr, "")
        XCTAssertEqual(modeSetup.exitCode, 0)
        XCTAssertEqual(relativePath.stdout, "docs/a.txt\n")
        XCTAssertEqual(relativePath.stderr, "")
        XCTAssertEqual(relativePath.exitCode, 0)
        XCTAssertEqual(emptyOutsideNested.stdout, "docs/empty.dat\n")
        XCTAssertEqual(emptyOutsideNested.stderr, "")
        XCTAssertEqual(emptyOutsideNested.exitCode, 0)
        XCTAssertEqual(formatted.stdout, "/docs/a.txt:6:f\n/docs/empty.dat:0:f\n")
        XCTAssertEqual(formatted.stderr, "")
        XCTAssertEqual(formatted.exitCode, 0)
        XCTAssertEqual(sizeAndMode.stdout, "/docs/a.txt\n")
        XCTAssertEqual(sizeAndMode.stderr, "")
        XCTAssertEqual(sizeAndMode.exitCode, 0)
        XCTAssertEqual(nulSeparated.stdout, "/docs/a.txt\0")
        XCTAssertEqual(nulSeparated.stderr, "")
        XCTAssertEqual(nulSeparated.exitCode, 0)
        XCTAssertFalse(formatted.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindExecRunsThroughSharedCommandRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "a\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "b\n".write(
            to: rootURL.appendingPathComponent("docs/b.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let perItem = await shell.run("find /docs -maxdepth 1 -type f -exec printf '<%s>\\n' {} \\; -print")
        let perItemFalse = await shell.run("find /docs -maxdepth 1 -type f -exec false {} \\; -print")
        let batched = await shell.run("find /docs -maxdepth 1 -type f -exec printf '[%s]\\n' {} +")
        let batchedFalse = await shell.run("find /docs -maxdepth 1 -type f -exec false {} +")

        XCTAssertEqual(Set(perItem.stdout.split(separator: "\n").map(String.init)), Set([
            "</docs/a.txt>",
            "/docs/a.txt",
            "</docs/b.txt>",
            "/docs/b.txt"
        ]))
        XCTAssertEqual(perItem.stderr, "")
        XCTAssertEqual(perItem.exitCode, 0)
        XCTAssertEqual(perItemFalse.stdout, "")
        XCTAssertEqual(perItemFalse.stderr, "")
        XCTAssertEqual(perItemFalse.exitCode, 0)
        XCTAssertEqual(Set(batched.stdout.split(separator: "\n").map(String.init)), Set([
            "[/docs/a.txt]",
            "[/docs/b.txt]"
        ]))
        XCTAssertEqual(batched.stderr, "")
        XCTAssertEqual(batched.exitCode, 0)
        XCTAssertEqual(batchedFalse.stdout, "")
        XCTAssertEqual(batchedFalse.stderr, "")
        XCTAssertEqual(batchedFalse.exitCode, 1)
        XCTAssertFalse(perItem.stdout.contains(rootURL.path))
        XCTAssertFalse(batched.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindPrintfSupportsFieldFormattingAndTimeDirectives() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        let fileURL = rootURL.appendingPathComponent("docs/a.txt")
        try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
        let modifiedAt = Date(timeIntervalSince1970: 1_706_963_696)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("find /docs -maxdepth 1 -type f -printf '%10f|%-10.3f|%04s|%TY-%Tm-%Td|%TH:%TM|%%\\n'")

        XCTAssertEqual(
            result.stdout,
            "     a.txt|a.t       |0003|\(findTestDate(modifiedAt, "yyyy-MM-dd"))|\(findTestDate(modifiedAt, "HH:mm"))|%\n"
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindDeleteRemovesMatchedFiles() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "keep".write(
            to: rootURL.appendingPathComponent("docs/keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "remove".write(
            to: rootURL.appendingPathComponent("docs/remove.tmp"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("""
        find /docs -maxdepth 1 -type f -name '*.tmp' -delete
        find /docs -maxdepth 1 -type f -printf '%f\\n' | sort
        """)

        XCTAssertEqual(result.stdout, "keep.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("docs/remove.tmp").path))
        XCTAssertFalse(result.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindDeleteRemovesDirectoryTreesDepthFirst() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs/remove-tree/sub"),
            withIntermediateDirectories: true
        )
        try "keep".write(
            to: rootURL.appendingPathComponent("docs/keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "leaf".write(
            to: rootURL.appendingPathComponent("docs/remove-tree/sub/leaf.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("find /docs/remove-tree -delete")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("docs/remove-tree").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("docs/keep.txt").path))
    }

    func testPOSIXCoreFindDeleteDoesNotRemoveDirectoriesContainingHiddenChildren() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        let hiddenDirectory = rootURL.appendingPathComponent("docs/hidden-only/.msp")
        try FileManager.default.createDirectory(
            at: hiddenDirectory,
            withIntermediateDirectories: true
        )
        try "hidden".write(
            to: hiddenDirectory.appendingPathComponent("private.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("find /docs/hidden-only -delete")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "find: cannot delete \u{2018}/docs/hidden-only\u{2019}: Directory not empty\n")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("docs/hidden-only").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenDirectory.appendingPathComponent("private.txt").path))
    }
}

private struct RecordingLookupPathRunner: MSPExternalCommandRunner {
    func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "\(request.executableName):\(request.arguments.joined(separator: ","))\n")
    }
}

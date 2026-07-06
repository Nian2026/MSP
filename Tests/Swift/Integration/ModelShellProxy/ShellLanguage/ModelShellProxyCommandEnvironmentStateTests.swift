import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyShellStateTests {
    func testCommandBuiltinAndEnvRunThroughSubcommandRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let lookup = await shell.run("command -v echo; command -V ls")
        let command = await shell.run("command printf 'ok\\n'")
        let builtin = await shell.run("builtin echo ok")
        let environment = await shell.run("env FOO=bar env | grep '^FOO='")

        XCTAssertEqual(lookup.stdout, "echo\nls is /usr/bin/ls\n")
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertEqual(command.stdout, "ok\n")
        XCTAssertEqual(command.stderr, "")
        XCTAssertEqual(command.exitCode, 0)
        XCTAssertEqual(builtin.stdout, "ok\n")
        XCTAssertEqual(builtin.stderr, "")
        XCTAssertEqual(builtin.exitCode, 0)
        XCTAssertEqual(environment.stdout, "FOO=bar\n")
        XCTAssertEqual(environment.stderr, "")
        XCTAssertEqual(environment.exitCode, 0)
    }

    func testCommandBuiltinExecutionRespectsVirtualPATHForExternalCommands() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let hidden = await shell.run("PATH=/nope command find /docs -maxdepth 0 -type d")
        let builtin = await shell.run("PATH=/nope command printf 'ok\\n'")
        let explicit = await shell.run("PATH=/nope command /usr/bin/find /docs -maxdepth 0 -type d")

        XCTAssertEqual(hidden.stdout, "")
        XCTAssertEqual(hidden.stderr, "/bin/bash: line 1: find: command not found\n")
        XCTAssertEqual(hidden.exitCode, 127)
        XCTAssertEqual(builtin.stdout, "ok\n")
        XCTAssertEqual(builtin.stderr, "")
        XCTAssertEqual(builtin.exitCode, 0)
        XCTAssertEqual(explicit.stdout, "/docs\n")
        XCTAssertEqual(explicit.stderr, "")
        XCTAssertEqual(explicit.exitCode, 0)
    }

    func testAssignmentPrefixesUseSharedShellEnvironmentSemantics() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let prefixed = await shell.run("FOO='two words' env | grep '^FOO='")
        let doesNotPersist = await shell.run("BAR=baz env | grep '^BAR='; env | grep '^BAR='")
        let assignmentOnly = await shell.run("PERSIST=yes; printf 'shell:%s\\n' \"$PERSIST\"")
        let assignmentOnlyIsNotExported = await shell.run("PERSIST=yes; env | grep '^PERSIST='")

        XCTAssertEqual(prefixed.stdout, "FOO=two words\n")
        XCTAssertEqual(prefixed.stderr, "")
        XCTAssertEqual(prefixed.exitCode, 0)
        XCTAssertEqual(doesNotPersist.stdout, "BAR=baz\n")
        XCTAssertEqual(doesNotPersist.stderr, "")
        XCTAssertEqual(doesNotPersist.exitCode, 1)
        XCTAssertEqual(assignmentOnly.stdout, "shell:yes\n")
        XCTAssertEqual(assignmentOnly.stderr, "")
        XCTAssertEqual(assignmentOnly.exitCode, 0)
        XCTAssertEqual(assignmentOnlyIsNotExported.stdout, "")
        XCTAssertEqual(assignmentOnlyIsNotExported.stderr, "")
        XCTAssertEqual(assignmentOnlyIsNotExported.exitCode, 1)
    }

    func testAdditionalLinuxCoreCommandsRunThroughWorkspaceAndShellState() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs/nested"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp"),
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

        let cwd = await shell.run("cd docs; pwd; cd -; pwd")
        let pipelineCwd = await shell.run("cd docs | pwd")
        let lookup = await shell.run("which ls; type cd; type -t ls; command -v exec; type exec")
        let sequenceAndReverse = await shell.run("seq -w 8 10; printf 'a\\nb\\n' | tac")
        let tee = await shell.run("printf 'copy\\n' | tee docs/tee.txt | wc -c")
        let file = await shell.run("file -b docs/a.txt")
        let usage = await shell.run("du -b -s docs")
        let temp = await shell.run("mktemp")
        let tempPath = temp.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(cwd.stdout, "/docs\n/\n/\n")
        XCTAssertEqual(pipelineCwd.stdout, "/\n")
        XCTAssertEqual(lookup.stdout, "/usr/bin/ls\ncd is a shell builtin\nfile\nexec\nexec is a shell builtin\n")
        XCTAssertEqual(sequenceAndReverse.stdout, "08\n09\n10\nb\na\n")
        XCTAssertEqual(tee.stdout, "5\n")
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("docs/tee.txt"), encoding: .utf8),
            "copy\n"
        )
        XCTAssertEqual(file.stdout, "ASCII text\n")
        XCTAssertTrue(usage.stdout.hasSuffix("\tdocs\n"))
        XCTAssertTrue(tempPath.hasPrefix("/tmp/tmp."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(String(tempPath.dropFirst())).path))
        XCTAssertFalse(cwd.stdout.contains(rootURL.path))
        XCTAssertFalse(usage.stdout.contains(rootURL.path))
        XCTAssertFalse(temp.stdout.contains(rootURL.path))
    }

    func testShellBuiltinPathAndEnvCommandsStayOnWorkspaceFacade() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let paths = await shell.run("mkdir -p docs; cd docs; pwd; cd -; realpath ../docs/missing.txt; readlink -f ../docs/missing.txt")
        let envPrint = await shell.run("env -i FOO=bar BAR=baz env")
        let envNullWithCommand = await shell.run("env -i -0 FOO=bar env")
        let envShellOnlyBuiltin = await shell.run("env cd")

        XCTAssertEqual(paths.stdout, "/docs\n/\n/docs/missing.txt\n/docs/missing.txt\n")
        XCTAssertEqual(paths.stderr, "")
        XCTAssertEqual(paths.exitCode, 0)
        XCTAssertEqual(envPrint.stdout, "FOO=bar\nBAR=baz\n")
        XCTAssertEqual(envPrint.stderr, "")
        XCTAssertEqual(envPrint.exitCode, 0)
        XCTAssertEqual(envNullWithCommand.exitCode, 125)
        XCTAssertEqual(
            envNullWithCommand.stderr,
            "env: cannot specify --null (-0) with command\nTry 'env --help' for more information.\n"
        )
        XCTAssertEqual(envShellOnlyBuiltin.exitCode, 127)
        XCTAssertEqual(envShellOnlyBuiltin.stderr, "env: \u{2018}cd\u{2019}: No such file or directory\n")
        XCTAssertFalse(paths.stdout.contains(rootURL.path))
        XCTAssertFalse(paths.stderr.contains(rootURL.path))
        XCTAssertFalse(envPrint.stdout.contains(rootURL.path))
        XCTAssertFalse(envNullWithCommand.stderr.contains(rootURL.path))
    }
}

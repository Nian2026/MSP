import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPShellBuiltinCommandTests: XCTestCase {
    func testPwdMatchesBashBuiltinOptionsAndOperandTolerance() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/work": .directory
        ])
        let physical = await runCommand("pwd", ["-P"], workspace: workspace, currentDirectory: "/work")
        let logical = await runCommand("pwd", ["-L", "ignored"], workspace: workspace, currentDirectory: "/work")
        let longPhysical = await runCommand("pwd", ["--physical"], workspace: workspace, currentDirectory: "/work")
        let longLogical = await runCommand("pwd", ["--logical"], workspace: workspace, currentDirectory: "/work")
        let help = await runCommand("pwd", ["--help"], workspace: workspace, currentDirectory: "/work")
        let version = await runCommand("pwd", ["--version"], workspace: workspace, currentDirectory: "/work")
        let invalid = await runCommand("pwd", ["-Z"], workspace: workspace, currentDirectory: "/work")

        XCTAssertEqual(physical.stdout, "/work\n")
        XCTAssertEqual(logical.stdout, "/work\n")
        XCTAssertEqual(longPhysical.stdout, "/work\n")
        XCTAssertEqual(longLogical.stdout, "/work\n")
        XCTAssertTrue(help.stdout.hasPrefix("Usage: pwd [OPTION]...\n"))
        XCTAssertEqual(version.stdout, "pwd (MSP coreutils-compatible) 9.1\n")
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertEqual(invalid.stderr, "pwd: -Z: invalid option\npwd: usage: pwd [-LP]\n")
    }

    func testCdReturnsShellStateChangeAndCdDashOutput() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/work": .directory,
            "/old": .directory,
            "/file.txt": .file(size: 1)
        ])

        let relative = await runCommand("cd", ["work"], workspace: workspace, currentDirectory: "/")
        let previous = await runCommand(
            "cd",
            ["-"],
            workspace: workspace,
            currentDirectory: "/work",
            environment: ["OLDPWD": "/old"]
        )
        let missingPrevious = await runCommand("cd", ["-"], workspace: workspace, currentDirectory: "/work")
        let notDirectory = await runCommand("cd", ["file.txt"], workspace: workspace, currentDirectory: "/")

        XCTAssertEqual(relative.exitCode, 0)
        XCTAssertEqual(relative.stdout, "")
        XCTAssertEqual(relative.stateChange?.currentDirectory, "/work")
        XCTAssertEqual(previous.exitCode, 0)
        XCTAssertEqual(previous.stdout, "/old\n")
        XCTAssertEqual(previous.stateChange?.currentDirectory, "/old")
        XCTAssertEqual(missingPrevious.exitCode, 1)
        XCTAssertEqual(missingPrevious.stderr, "cd: OLDPWD not set\n")
        XCTAssertEqual(notDirectory.exitCode, 1)
        XCTAssertEqual(notDirectory.stderr, "cd: file.txt: Not a directory\n")
    }

    func testLookupBuiltinsKeywordsAndExternalFallbacksMatchBashAndWhichShapes() async throws {
        let commandBuiltin = await runCommand("command", ["-v", "test"])
        let commandFile = await runCommand("command", ["-v", "awk"])
        let commandKeyword = await runCommand("command", ["-V", "[["])
        let commandBadOption = await runCommand("command", ["-Z"])
        let typeKeyword = await runCommand("type", ["-t", "[["])
        let typeAllPrintf = await runCommand("type", ["-a", "printf"])
        let typeAllBasename = await runCommand("type", ["-a", "basename"])
        let typeObsoleteType = await runCommand("type", ["--type", "[["])
        let typeObsoletePath = await runCommand("type", ["-path", "basename"])
        let typeObsoleteAll = await runCommand("type", ["--all", "basename"])
        let typeHelp = await runCommand("type", ["--help"])
        let typeNoArguments = await runCommand("type", [])
        let typeSoftBuiltinPath = await runCommand("type", ["-p", "cd"])
        let typeForcedBuiltinPath = await runCommand("type", ["-P", "cd"])
        let typeBadOption = await runCommand("type", ["--bad", "cd"])
        let whichExternalBuiltin = await runCommand("which", ["test", "printf", "["])
        let whichRegisteredExternal = await runCommand("which", ["awk"])
        let whichMissing = await runCommand("which", ["definitely_missing_command_12345"])
        let whichShellOnlyBuiltin = await runCommand("which", ["cd"])
        let whichNoArguments = await runCommand("which", [])
        let whichBadOption = await runCommand("which", ["--bad"])
        let whichRejectedLongAll = await runCommand("which", ["--all", "sh"])
        let builtinShellLauncher = await runCommand("builtin", ["bash"])

        XCTAssertEqual(commandBuiltin.stdout, "test\n")
        XCTAssertEqual(commandFile.stdout, "/usr/bin/awk\n")
        XCTAssertEqual(commandKeyword.stdout, "[[ is a shell keyword\n")
        XCTAssertEqual(commandBadOption.exitCode, 2)
        XCTAssertEqual(commandBadOption.stderr, "command: -Z: invalid option\ncommand: usage: command [-pVv] command [arg ...]\n")
        XCTAssertEqual(typeKeyword.stdout, "keyword\n")
        XCTAssertEqual(typeAllPrintf.stdout, "printf is a shell builtin\nprintf is /usr/bin/printf\nprintf is /bin/printf\n")
        XCTAssertEqual(typeAllBasename.stdout, "basename is /usr/bin/basename\nbasename is /bin/basename\n")
        XCTAssertEqual(typeObsoleteType.stdout, "keyword\n")
        XCTAssertEqual(typeObsoletePath.stdout, "/usr/bin/basename\n")
        XCTAssertEqual(typeObsoleteAll.stdout, "basename is /usr/bin/basename\nbasename is /bin/basename\n")
        XCTAssertTrue(typeHelp.stdout.hasPrefix("type: type [-afptP] name [name ...]\n"))
        XCTAssertEqual(typeNoArguments.exitCode, 0)
        XCTAssertEqual(typeNoArguments.stdout, "")
        XCTAssertEqual(typeSoftBuiltinPath.exitCode, 0)
        XCTAssertEqual(typeSoftBuiltinPath.stdout, "")
        XCTAssertEqual(typeForcedBuiltinPath.exitCode, 1)
        XCTAssertEqual(typeBadOption.exitCode, 2)
        XCTAssertEqual(typeBadOption.stderr, "type: --: invalid option\ntype: usage: type [-afptP] name [name ...]\n")
        XCTAssertEqual(whichExternalBuiltin.stdout, "/usr/bin/test\n/usr/bin/printf\n/usr/bin/[\n")
        XCTAssertEqual(whichExternalBuiltin.exitCode, 0)
        XCTAssertEqual(whichRegisteredExternal.stdout, "/usr/bin/awk\n")
        XCTAssertEqual(whichRegisteredExternal.exitCode, 0)
        XCTAssertEqual(whichMissing.stdout, "")
        XCTAssertEqual(whichMissing.exitCode, 1)
        XCTAssertEqual(whichShellOnlyBuiltin.stdout, "")
        XCTAssertEqual(whichShellOnlyBuiltin.exitCode, 1)
        XCTAssertEqual(whichNoArguments.exitCode, 1)
        XCTAssertEqual(whichNoArguments.stdout, "")
        XCTAssertEqual(whichNoArguments.stderr, "")
        XCTAssertEqual(whichBadOption.exitCode, 2)
        XCTAssertEqual(whichBadOption.stdout, "Usage: /usr/bin/which [-a] args\n")
        XCTAssertEqual(whichBadOption.stderr, "Illegal option --\n")
        XCTAssertEqual(whichRejectedLongAll.exitCode, 2)
        XCTAssertEqual(whichRejectedLongAll.stdout, "Usage: /usr/bin/which [-a] args\n")
        XCTAssertEqual(whichRejectedLongAll.stderr, "Illegal option --\n")
        XCTAssertEqual(builtinShellLauncher.stderr, "builtin: bash: not a shell builtin\n")
        XCTAssertEqual(builtinShellLauncher.exitCode, 1)
    }

    func testWhichUsesVirtualPathAndSlashOperandRules() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/tools": .directory,
            "/tools/mycmd": .file(size: 1, permissions: 0o755),
            "/tools/not-executable": .file(size: 1, permissions: 0o644),
            "/work": .directory,
            "/work/localcmd": .file(size: 1, permissions: 0o755)
        ])

        let found = await runCommand(
            "which",
            ["mycmd"],
            workspace: workspace,
            environment: ["PATH": "/tools:/bin"]
        )
        let allSh = await runCommand(
            "which",
            ["-a", "sh"],
            workspace: workspace,
            environment: ["PATH": "/bin:/usr/bin"]
        )
        let slash = await runCommand(
            "which",
            ["./localcmd", "/tools/not-executable"],
            workspace: workspace,
            currentDirectory: "/work",
            environment: ["PATH": "/tools"]
        )

        XCTAssertEqual(found.stdout, "/tools/mycmd\n")
        XCTAssertEqual(found.exitCode, 0)
        XCTAssertEqual(allSh.stdout, "/bin/sh\n/usr/bin/sh\n")
        XCTAssertEqual(allSh.exitCode, 0)
        XCTAssertEqual(slash.stdout, "./localcmd\n")
        XCTAssertEqual(slash.exitCode, 1)
    }

    func testCommandTypeAndEnvRespectVirtualPATHForExternalCommands() async throws {
        let commandDefault = await runCommand("command", ["-v", "find"])
        let commandBinOnly = await runCommand("command", ["-v", "find"], environment: ["PATH": "/bin"])
        let commandMissing = await runCommand("command", ["-v", "find"], environment: ["PATH": "/nope"])
        let typeAll = await runCommand("type", ["-a", "find"], environment: ["PATH": "/bin:/usr/bin"])
        let typePathOnly = await runCommand("type", ["-P", "find"], environment: ["PATH": "/bin"])
        let typePathOnlyMissing = await runCommand("type", ["-P", "find"], environment: ["PATH": "/nope"])
        let typeDescriptionMissing = await runCommand("type", ["find"], environment: ["PATH": "/nope"])
        let envBin = await runCommand("env", ["PATH=/bin", "printf", "ok\\n"])
        let envMissing = await runCommand("env", ["PATH=/nope", "printf", "bad\\n"])

        XCTAssertEqual(commandDefault.stdout, "/usr/bin/find\n")
        XCTAssertEqual(commandDefault.exitCode, 0)
        XCTAssertEqual(commandBinOnly.stdout, "/bin/find\n")
        XCTAssertEqual(commandBinOnly.exitCode, 0)
        XCTAssertEqual(commandMissing.stdout, "")
        XCTAssertEqual(commandMissing.exitCode, 1)
        XCTAssertEqual(typeAll.stdout, "find is /bin/find\nfind is /usr/bin/find\n")
        XCTAssertEqual(typeAll.exitCode, 0)
        XCTAssertEqual(typePathOnly.stdout, "/bin/find\n")
        XCTAssertEqual(typePathOnly.exitCode, 0)
        XCTAssertEqual(typePathOnlyMissing.stdout, "")
        XCTAssertEqual(typePathOnlyMissing.stderr, "")
        XCTAssertEqual(typePathOnlyMissing.exitCode, 1)
        XCTAssertEqual(typeDescriptionMissing.stdout, "")
        XCTAssertEqual(typeDescriptionMissing.stderr, "type: find: not found\n")
        XCTAssertEqual(typeDescriptionMissing.exitCode, 1)
        XCTAssertEqual(envBin.stdout, "ok\n")
        XCTAssertEqual(envBin.stderr, "")
        XCTAssertEqual(envBin.exitCode, 0)
        XCTAssertEqual(envMissing.stdout, "")
        XCTAssertEqual(envMissing.stderr, "env: \u{2018}printf\u{2019}: No such file or directory\n")
        XCTAssertEqual(envMissing.exitCode, 127)
    }

    func testEnvMatchesGNUDiagnosticsNullRulesAndSubcommandBoundary() async throws {
        let invalidShort = await runCommand("env", ["-Z"])
        let invalidLong = await runCommand("env", ["--bad"])
        let unsetMissing = await runCommand("env", ["-u"])
        let unsetLongMissing = await runCommand("env", ["--unset"])
        let nullPrint = await runCommand("env", ["-i", "-0", "FOO=bar"])
        let nullWithCommand = await runCommand("env", ["-i", "-0", "FOO=bar", "env"])
        let noSuchCommand = await runCommand("env", ["no-such-cmd"])
        let shellOnlyBuiltin = await runCommand("env", ["cd"])
        let unsetNested = await runCommand("env", ["-i", "FOO=bar", "BAR=baz", "env", "-u", "FOO", "env"])
        let attachedUnset = await runCommand("env", ["-i", "FOO=bar", "BAR=baz", "env", "-uFOO", "env"])
        let wideAssignments = await runCommand("env", ["-i", "1=bar", "A-B=baz", "=empty", "env"])
        let doubleDashAssignment = await runCommand("env", ["-i", "--", "-X=bar", "env"])
        let splitString = await runCommand("env", ["-S", "FOO=bar env"])
        let help = await runCommand("env", ["--help"])
        let version = await runCommand("env", ["--version"])
        let bareDash = await runCommand("env", ["-", "FOO=bar"])
        let chdirWithoutCommand = await runCommand("env", ["-C", "/work"], workspace: TestWorkspace(entries: [
            "/": .directory,
            "/work": .directory
        ]))
        let chdirPwd = await runCommand("env", ["-C", "/work", "pwd"], workspace: TestWorkspace(entries: [
            "/": .directory,
            "/work": .directory
        ]))

        XCTAssertEqual(invalidShort.exitCode, 125)
        XCTAssertEqual(invalidShort.stderr, "env: invalid option -- 'Z'\nTry 'env --help' for more information.\n")
        XCTAssertEqual(invalidLong.exitCode, 125)
        XCTAssertEqual(invalidLong.stderr, "env: unrecognized option '--bad'\nTry 'env --help' for more information.\n")
        XCTAssertEqual(unsetMissing.exitCode, 125)
        XCTAssertEqual(unsetMissing.stderr, "env: option requires an argument -- 'u'\nTry 'env --help' for more information.\n")
        XCTAssertEqual(unsetLongMissing.exitCode, 125)
        XCTAssertEqual(unsetLongMissing.stderr, "env: option '--unset' requires an argument\nTry 'env --help' for more information.\n")
        XCTAssertEqual(nullPrint.stdout, "FOO=bar\0")
        XCTAssertEqual(nullPrint.exitCode, 0)
        XCTAssertEqual(nullWithCommand.exitCode, 125)
        XCTAssertEqual(nullWithCommand.stderr, "env: cannot specify --null (-0) with command\nTry 'env --help' for more information.\n")
        XCTAssertEqual(noSuchCommand.exitCode, 127)
        XCTAssertEqual(noSuchCommand.stderr, "env: \u{2018}no-such-cmd\u{2019}: No such file or directory\n")
        XCTAssertEqual(shellOnlyBuiltin.exitCode, 127)
        XCTAssertEqual(shellOnlyBuiltin.stderr, "env: \u{2018}cd\u{2019}: No such file or directory\n")
        XCTAssertEqual(unsetNested.stdout, "BAR=baz\n")
        XCTAssertEqual(attachedUnset.stdout, "BAR=baz\n")
        XCTAssertEqual(wideAssignments.stdout, "1=bar\nA-B=baz\n=empty\n")
        XCTAssertEqual(doubleDashAssignment.stdout, "-X=bar\n")
        XCTAssertEqual(splitString.stdout, "FOO=bar\n")
        XCTAssertTrue(help.stdout.hasPrefix("Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]\n"))
        XCTAssertEqual(version.stdout, "env (MSP coreutils-compatible) 9.1\n")
        XCTAssertEqual(bareDash.stdout, "FOO=bar\n")
        XCTAssertEqual(chdirWithoutCommand.exitCode, 125)
        XCTAssertEqual(chdirWithoutCommand.stderr, "env: must specify command with --chdir (-C)\nTry 'env --help' for more information.\n")
        XCTAssertEqual(chdirPwd.stdout, "/work\n")
    }

    func testEchoAndPrintfDecodeCoreEscapeExtensions() async throws {
        let echo = await runCommand("echo", ["-e", "\\x41", "\\u03bb", "\\U0001F600"])
        let printf = await runCommand("printf", ["<%s>\\x0a\\u03bb\\U0001F600\\\"\\E\\n", "ok"])
        let hexFloat = await runCommand("printf", ["%a\\n", "2"])
        let printfHelp = await runCommand("printf", ["--help"])
        let printfVersion = await runCommand("printf", ["--version"])

        XCTAssertEqual(echo.stdout, "A λ 😀\n")
        XCTAssertEqual(printf.stdout, "<ok>\nλ😀\"\u{1b}\n")
        XCTAssertTrue(hexFloat.stdout.lowercased().contains("0x"))
        XCTAssertTrue(printfHelp.stdout.hasPrefix("Usage: printf FORMAT [ARGUMENT]...\n"))
        XCTAssertEqual(printfVersion.stdout, "printf (MSP coreutils-compatible) 9.1\n")
    }

    func testBooleanCommandsHonorCoreutilsSoleMetaOptions() async throws {
        let trueHelp = await runCommand("true", ["--help"])
        let trueVersion = await runCommand("true", ["--version"])
        let trueIgnoredHelp = await runCommand("true", ["--help", "ignored"])
        let falseHelp = await runCommand("false", ["--help"])
        let falseVersion = await runCommand("false", ["--version"])
        let falseIgnoredHelp = await runCommand("false", ["--help", "ignored"])

        XCTAssertTrue(trueHelp.stdout.hasPrefix("Usage: true [ignored command line arguments]\n"))
        XCTAssertEqual(trueHelp.exitCode, 0)
        XCTAssertEqual(trueVersion.stdout, "true (MSP coreutils-compatible) 9.1\n")
        XCTAssertEqual(trueIgnoredHelp.stdout, "")
        XCTAssertEqual(trueIgnoredHelp.exitCode, 0)
        XCTAssertTrue(falseHelp.stdout.hasPrefix("Usage: false [ignored command line arguments]\n"))
        XCTAssertEqual(falseHelp.exitCode, 0)
        XCTAssertEqual(falseVersion.stdout, "false (MSP coreutils-compatible) 9.1\n")
        XCTAssertEqual(falseIgnoredHelp.stdout, "")
        XCTAssertEqual(falseIgnoredHelp.exitCode, 1)
    }

    func testTestCommandSupportsCommonFilePredicatesAndIntegerDiagnostics() async throws {
        let workspace = TestWorkspace(entries: [
            "/": .directory,
            "/data": .directory,
            "/data/nonempty.txt": .file(size: 4, permissions: 0o6755, modificationDate: Date(timeIntervalSince1970: 2)),
            "/data/empty.txt": .file(size: 0, permissions: 0o644, modificationDate: Date(timeIntervalSince1970: 1)),
            "/data/link.txt": .symlink("nonempty.txt")
        ])

        let nonempty = await runCommand("test", ["-s", "/data/nonempty.txt"], workspace: workspace)
        let empty = await runCommand("test", ["-s", "/data/empty.txt"], workspace: workspace)
        let symlink = await runCommand("test", ["-L", "/data/link.txt"], workspace: workspace)
        let readable = await runCommand("test", ["-r", "/data/nonempty.txt"], workspace: workspace)
        let executable = await runCommand("test", ["-x", "/usr/bin/awk"], workspace: workspace)
        let missingExecutable = await runCommand("test", ["-x", "/usr/bin/not-a-command"], workspace: workspace)
        let badInteger = await runCommand("test", ["abc", "-eq", "1"], workspace: workspace)
        let badUnary = await runCommand("test", ["-Q", "x"], workspace: workspace)
        let badBinary = await runCommand("test", ["a", "-Q", "b"], workspace: workspace)
        let missingBracket = await runCommand("[", ["abc"], workspace: workspace)
        let compound = await runCommand(
            "test",
            ["(", "-n", "x", "-a", "3", "-gt", "2", ")", "-o", "missing", "=", "present"],
            workspace: workspace
        )
        let stringOrdering = await runCommand("test", ["beta", ">", "alpha"], workspace: workspace)
        let writable = await runCommand("test", ["-w", "/data/nonempty.txt"], workspace: workspace)
        let setuid = await runCommand("test", ["-u", "/data/nonempty.txt"], workspace: workspace)
        let setgid = await runCommand("test", ["-g", "/data/nonempty.txt"], workspace: workspace)
        let newer = await runCommand("test", ["/data/nonempty.txt", "-nt", "/data/empty.txt"], workspace: workspace)
        let sameFile = await runCommand("test", ["/data/nonempty.txt", "-ef", "/data/nonempty.txt"], workspace: workspace)

        XCTAssertEqual(nonempty.exitCode, 0)
        XCTAssertEqual(empty.exitCode, 1)
        XCTAssertEqual(symlink.exitCode, 0)
        XCTAssertEqual(readable.exitCode, 0)
        XCTAssertEqual(executable.exitCode, 0)
        XCTAssertEqual(missingExecutable.exitCode, 1)
        XCTAssertEqual(badInteger.exitCode, 2)
        XCTAssertEqual(badInteger.stderr, "test: abc: integer expression expected\n")
        XCTAssertEqual(badUnary.exitCode, 2)
        XCTAssertEqual(badUnary.stderr, "test: -Q: unary operator expected\n")
        XCTAssertEqual(badBinary.exitCode, 2)
        XCTAssertEqual(badBinary.stderr, "test: -Q: binary operator expected\n")
        XCTAssertEqual(missingBracket.exitCode, 2)
        XCTAssertEqual(missingBracket.stderr, "[: missing `]'\n")
        XCTAssertEqual(compound.exitCode, 0)
        XCTAssertEqual(stringOrdering.exitCode, 0)
        XCTAssertEqual(writable.exitCode, 0)
        XCTAssertEqual(setuid.exitCode, 0)
        XCTAssertEqual(setgid.exitCode, 0)
        XCTAssertEqual(newer.exitCode, 0)
        XCTAssertEqual(sameFile.exitCode, 0)
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        currentDirectory: String = "/",
        environment: [String: String] = [:]
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        let subcommandRunner: MSPSubcommandRunner = { invocation, childContext in
            await executor.run(invocation: invocation, context: childContext)
        }
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(
                workspace: workspace,
                currentDirectory: currentDirectory,
                environment: environment,
                availableCommandNames: registry.commandNames,
                subcommandRunner: subcommandRunner
            )
        )
    }
}

private struct TestWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(entries: [String: TestWorkspaceFileSystem.Entry]) {
        self.fileSystem = TestWorkspaceFileSystem(entries: entries)
    }
}

private struct TestWorkspaceFileSystem: MSPWorkspaceFileSystem {
    enum Entry {
        case file(size: Int64?, permissions: UInt16? = nil, modificationDate: Date? = nil)
        case directory
        case symlink(String)
    }

    let policy = MSPWorkspaceFileSystemPolicy.default
    var entries: [String: Entry]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        let virtualPath = MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        guard !policy.isHidden(virtualPath) else {
            throw MSPWorkspaceFileSystemError.hiddenPath(virtualPath)
        }
        return MSPResolvedPath(virtualPath: virtualPath)
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        switch entry {
        case .file(let size, let permissions, let modificationDate):
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .regularFile,
                size: size,
                modificationDate: modificationDate,
                permissions: permissions
            )
        case .directory:
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        case .symlink:
            return MSPFileInfo(virtualPath: virtualPath, type: .symbolicLink)
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let entry = entries[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        guard case .symlink(let target) = entry else {
            throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
        }
        return target
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "read")
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "write")
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "mkdir")
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "touch")
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "remove")
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "copy")
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "move")
    }
}

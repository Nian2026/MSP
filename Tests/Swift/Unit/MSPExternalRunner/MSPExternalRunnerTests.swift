import XCTest
import MSPCore
import MSPApple
import MSPExternalRunner

private struct RecordingRunner: MSPExternalCommandRunner {
    func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "\(request.executableName) \(request.arguments.joined(separator: " "))\n")
    }
}

final class MSPExternalRunnerTests: XCTestCase {
    func testExternalCommandAdapterUsesRunner() async throws {
        let registry = try MSPCommandRegistry()
        try registry.registerExternalCommand("git", runner: RecordingRunner())

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "git", arguments: ["status"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(result.stdout, "git status\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    #if os(macOS) || os(Linux)
    func testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths() async throws {
        let catURL = URL(fileURLWithPath: "/bin/cat")
        guard FileManager.default.isExecutableFile(atPath: catURL.path) else {
            throw XCTSkip("/bin/cat is required for host-process external runner tests.")
        }

        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("external runner mapped argument\n".utf8)
            .write(to: docsURL.appendingPathComponent("report file.txt"))
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: catURL)

        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "cat",
                arguments: ["/docs/report file.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "external runner mapped argument\n")
        XCTAssertEqual(result.stderr, "")

        let missing = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "cat",
                arguments: ["/docs/missing.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertTrue(missing.stderr.contains("/docs/missing.txt"), missing.stderr)
        XCTAssertFalse(missing.stderr.contains(rootURL.path), missing.stderr)
    }

    func testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("external runner mapped option value\n".utf8)
            .write(to: docsURL.appendingPathComponent("option-input.txt"))

        let scriptURL = rootURL.appendingPathComponent("read-option-value.sh")
        try """
        #!/bin/sh
        case "$1" in
          --input=*) cat "${1#--input=}" ;;
          *) echo "bad argument: $1" >&2; exit 64 ;;
        esac
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL)
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-option-value.sh",
                arguments: ["--input=/docs/option-input.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "external runner mapped option value\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))

        let missing = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-option-value.sh",
                arguments: ["--input=/docs/missing-option.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertTrue(missing.stderr.contains("/docs/missing-option.txt"), missing.stderr)
        XCTAssertFalse(missing.stderr.contains(rootURL.path), missing.stderr)
    }

    func testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("external runner mapped environment value\n".utf8)
            .write(to: docsURL.appendingPathComponent("env-input.txt"))

        let scriptURL = rootURL.appendingPathComponent("read-env-value.sh")
        try """
        #!/bin/sh
        cat "$INPUT_PATH"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL)
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-env-value.sh",
                arguments: [],
                environment: ["INPUT_PATH": "/docs/env-input.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "external runner mapped environment value\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))

        let missing = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-env-value.sh",
                arguments: [],
                environment: ["INPUT_PATH": "/docs/missing-env.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertTrue(missing.stderr.contains("/docs/missing-env.txt"), missing.stderr)
        XCTAssertFalse(missing.stderr.contains(rootURL.path), missing.stderr)
    }

    func testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("external runner mapped path list first\n".utf8)
            .write(to: docsURL.appendingPathComponent("path-list-a.txt"))
        try Data("external runner mapped path list second\n".utf8)
            .write(to: docsURL.appendingPathComponent("path-list-b.txt"))

        let scriptURL = rootURL.appendingPathComponent("read-env-path-list.sh")
        try """
        #!/bin/sh
        old_ifs=$IFS
        IFS=:
        set -- $INPUT_PATHS
        IFS=$old_ifs
        cat "$1"
        cat "$2"
        printf 'INPUT_PATHS=%s\\n' "$INPUT_PATHS"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL)
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-env-path-list.sh",
                arguments: [],
                environment: ["INPUT_PATHS": "/docs/path-list-a.txt:/docs/path-list-b.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            "external runner mapped path list first\n"
                + "external runner mapped path list second\n"
                + "INPUT_PATHS=/docs/path-list-a.txt:/docs/path-list-b.txt\n"
        )
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data("external runner mapped file URL argument\n".utf8)
            .write(to: docsURL.appendingPathComponent("file-url-argument.txt"))
        try Data("external runner mapped file URL environment\n".utf8)
            .write(to: docsURL.appendingPathComponent("file-url-environment.txt"))

        let scriptURL = rootURL.appendingPathComponent("read-file-url-values.sh")
        try """
        #!/bin/sh
        set -e
        case "$1" in
          file://*) cat "${1#file://}" ;;
          *) echo "bad argument uri: $1" >&2; exit 64 ;;
        esac
        printf 'ARG_URI=%s\\n' "$1"
        case "$INPUT_URI" in
          file://*) cat "${INPUT_URI#file://}" ;;
          *) echo "bad environment uri: $INPUT_URI" >&2; exit 64 ;;
        esac
        printf 'INPUT_URI=%s\\n' "$INPUT_URI"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL)
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "read-file-url-values.sh",
                arguments: ["file:///docs/file-url-argument.txt"],
                environment: ["INPUT_URI": "file:///docs/file-url-environment.txt"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            "external runner mapped file URL argument\n"
                + "ARG_URI=file:///docs/file-url-argument.txt\n"
                + "external runner mapped file URL environment\n"
                + "INPUT_URI=file:///docs/file-url-environment.txt\n"
        )
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let registry = try MSPCommandRegistry()
        try registry.registerExternalCommand(
            "missing-tool",
            runner: MSPHostProcessExternalRunner(
                executableURL: toolsURL.appendingPathComponent("missing-tool")
            )
        )

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "missing-tool"),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("missing-tool"), result.stderr)
        XCTAssertTrue(result.stderr.contains("/tools/missing-tool"), result.stderr)
        XCTAssertFalse(result.stderr.contains(rootURL.path), result.stderr)
    }

    func testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let hostOnlyURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: hostOnlyURL) }
        let hostToolsURL = hostOnlyURL.appendingPathComponent("host-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: hostToolsURL, withIntermediateDirectories: true)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let registry = try MSPCommandRegistry()
        try registry.registerExternalCommand(
            "host-missing-tool",
            runner: MSPHostProcessExternalRunner(
                executableURL: hostToolsURL.appendingPathComponent("host-missing-tool")
            )
        )

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "host-missing-tool"),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("host-missing-tool"), result.stderr)
        XCTAssertFalse(result.stderr.contains(hostOnlyURL.path), result.stderr)
        XCTAssertFalse(result.stderr.contains(rootURL.path), result.stderr)
    }

    func testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let hostOnlyURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: hostOnlyURL) }
        let hostToolsURL = hostOnlyURL.appendingPathComponent("host tools", isDirectory: true)
        try FileManager.default.createDirectory(at: hostToolsURL, withIntermediateDirectories: true)
        let scriptURL = hostToolsURL.appendingPathComponent("host tool.sh")
        let scriptFileURL = scriptURL.standardizedFileURL.absoluteString
        try """
        #!/bin/sh
        printf 'SELF=%s\\n' "$0"
        printf 'SELF_FILE_URL=%s\\n' "\(scriptFileURL)"
        printf 'PATH=%s\\n' "$PATH"
        printf 'ERR_SELF=%s\\n' "$0" >&2
        printf 'ERR_SELF_FILE_URL=%s\\n' "\(scriptFileURL)" >&2
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL)

        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "host tool.sh",
                arguments: [],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("SELF="), result.stdout)
        XCTAssertTrue(result.stdout.contains("PATH="), result.stdout)
        XCTAssertTrue(result.stderr.contains("ERR_SELF="), result.stderr)
        XCTAssertTrue(result.stdout.contains("SELF=/usr/local/bin/host tool.sh"), result.stdout)
        XCTAssertTrue(result.stdout.contains("SELF_FILE_URL=file:///usr/local/bin/host%20tool.sh"), result.stdout)
        XCTAssertTrue(
            result.stdout.contains("PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n"),
            result.stdout
        )
        XCTAssertTrue(result.stderr.contains("ERR_SELF=/usr/local/bin/host tool.sh"), result.stderr)
        XCTAssertTrue(result.stderr.contains("ERR_SELF_FILE_URL=file:///usr/local/bin/host%20tool.sh"), result.stderr)
        XCTAssertFalse(result.stdout.contains(hostOnlyURL.path), result.stdout)
        XCTAssertFalse(result.stderr.contains(hostOnlyURL.path), result.stderr)
        XCTAssertFalse(result.stdout.contains(scriptFileURL), result.stdout)
        XCTAssertFalse(result.stderr.contains(scriptFileURL), result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path), result.stdout + result.stderr)
    }

    func testHostProcessExternalRunnerSanitizesVersionOutputPaths() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        let hostOnlyURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: hostOnlyURL) }
        let hostToolsURL = hostOnlyURL.appendingPathComponent("host tools", isDirectory: true)
        try FileManager.default.createDirectory(at: hostToolsURL, withIntermediateDirectories: true)
        let scriptURL = hostToolsURL.appendingPathComponent("host tool.sh")
        let scriptFileURL = scriptURL.standardizedFileURL.absoluteString
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(
            executableURL: scriptURL,
            versionOutput: """
            host tool 1.0
            SELF=\(scriptURL.path)
            SELF_FILE_URL=\(scriptFileURL)
            WORKSPACE_REPORT=\(rootURL.path)/docs/report.txt
            """
        )

        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "host tool.sh",
                arguments: ["--version"],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("SELF=/usr/local/bin/host tool.sh"), result.stdout)
        XCTAssertTrue(result.stdout.contains("SELF_FILE_URL=file:///usr/local/bin/host%20tool.sh"), result.stdout)
        XCTAssertTrue(result.stdout.contains("WORKSPACE_REPORT=/docs/report.txt"), result.stdout)
        XCTAssertFalse(result.stdout.contains(hostOnlyURL.path), result.stdout)
        XCTAssertFalse(result.stdout.contains(scriptFileURL), result.stdout)
        XCTAssertFalse(result.stdout.contains(rootURL.path), result.stdout)
    }

    func testHostProcessExternalRunnerDoesNotWaitForForkedChildHoldingOutputPipe() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let scriptURL = rootURL.appendingPathComponent("fork-holding-output-pipe.sh")
        try """
        #!/bin/sh
        printf 'parent stdout before exit\\n'
        printf 'parent stderr before exit\\n' >&2
        ( sleep 5; printf 'late child stdout\\n'; printf 'late child stderr\\n' >&2 ) &
        printf '%s\\n' "$!" > fork-child.pid
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL, timeout: 10)
        let start = Date()
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "fork-holding-output-pipe.sh",
                arguments: [],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )
        terminatePIDs(recordedAt: rootURL.appendingPathComponent("fork-child.pid"))

        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "parent stdout before exit\n")
        XCTAssertEqual(result.stderr, "parent stderr before exit\n")
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessExternalRunnerStopsReaderWhenForkedChildKeepsWriting() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let scriptURL = rootURL.appendingPathComponent("fork-writing-output-pipe.sh")
        try """
        #!/bin/sh
        printf 'parent stdout before exit\\n'
        printf 'parent stderr before exit\\n' >&2
        (
          trap 'exit 0' TERM
          while :; do
            printf 'child stdout chunk\\n'
            printf 'child stderr chunk\\n' >&2
            sleep 0.01
          done
        ) &
        printf '%s\\n' "$!" > fork-writer-child.pid
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL, timeout: 10)
        let start = Date()
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "fork-writing-output-pipe.sh",
                arguments: [],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )
        terminatePIDs(recordedAt: rootURL.appendingPathComponent("fork-writer-child.pid"))

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("parent stdout before exit\n"), result.stdout)
        XCTAssertTrue(result.stderr.hasPrefix("parent stderr before exit\n"), result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessExternalRunnerTimeoutReturnsPartialOutputWithoutWaitingForPipeEOF() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let scriptURL = rootURL.appendingPathComponent("timeout-with-inherited-output-pipe.sh")
        try """
        #!/bin/sh
        printf 'stdout before timeout\\n'
        printf 'stderr before timeout\\n' >&2
        ( sleep 5 ) &
        bg_pid=$!
        sleep 5 &
        fg_pid=$!
        printf '%s\\n%s\\n' "$bg_pid" "$fg_pid" > timeout-child-pids.txt
        wait "$fg_pid"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let runner = MSPHostProcessExternalRunner(executableURL: scriptURL, timeout: 1)
        let start = Date()
        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "timeout-with-inherited-output-pipe.sh",
                arguments: [],
                workingDirectory: "/"
            ),
            context: MSPCommandContext(workspace: workspace)
        )
        terminatePIDs(recordedAt: rootURL.appendingPathComponent("timeout-child-pids.txt"))

        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertEqual(result.stdout, "stdout before timeout\n")
        XCTAssertTrue(result.stderr.contains("stderr before timeout\n"), result.stderr)
        XCTAssertTrue(
            result.stderr.contains("timeout-with-inherited-output-pipe.sh: timed out after 1s\n"),
            result.stderr
        )
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths() async throws {
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let pwdURL = URL(fileURLWithPath: "/bin/pwd")
        guard FileManager.default.isExecutableFile(atPath: envURL.path),
              FileManager.default.isExecutableFile(atPath: pwdURL.path) else {
            throw XCTSkip("/usr/bin/env and /bin/pwd are required for host-process external runner tests.")
        }

        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let tmpURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try Data("workspace env path content\n".utf8)
            .write(to: docsURL.appendingPathComponent("pwd-input.txt"))
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)

        let envRunner = MSPHostProcessExternalRunner(
            executableURL: envURL,
            extraEnvironment: [
                "MSP_EXTERNAL_TEST_HOST_PATH": rootURL.path + "/docs/report.txt",
                "MSP_EXTERNAL_TEST_FILE_URL": rootURL.appendingPathComponent("docs/report file.txt").absoluteString
            ]
        )
        let envResult = try await envRunner.run(
            MSPExternalCommandRequest(
                executableName: "env",
                arguments: [],
                workingDirectory: "/docs"
            ),
            context: MSPCommandContext(workspace: workspace, currentDirectory: "/docs")
        )

        XCTAssertEqual(envResult.exitCode, 0)
        XCTAssertEqual(envResult.stderr, "")
        XCTAssertTrue(envResult.stdout.contains("PWD=/docs\n"), envResult.stdout)
        XCTAssertTrue(envResult.stdout.contains("TMPDIR=/tmp\n"), envResult.stdout)
        XCTAssertTrue(envResult.stdout.contains("MSP_WORKSPACE_ROOT=/\n"), envResult.stdout)
        XCTAssertTrue(envResult.stdout.contains("MSP_EXTERNAL_TEST_HOST_PATH=/docs/report.txt\n"), envResult.stdout)
        XCTAssertTrue(envResult.stdout.contains("MSP_EXTERNAL_TEST_FILE_URL=file:///docs/report%20file.txt\n"), envResult.stdout)
        XCTAssertFalse(envResult.stdout.contains(rootURL.path), envResult.stdout)
        XCTAssertFalse(envResult.stdout.contains("report%20file.txt") && envResult.stdout.contains(rootURL.lastPathComponent), envResult.stdout)

        let pwdRunner = MSPHostProcessExternalRunner(executableURL: pwdURL)
        let pwdResult = try await pwdRunner.run(
            MSPExternalCommandRequest(
                executableName: "pwd",
                arguments: [],
                workingDirectory: "/docs"
            ),
            context: MSPCommandContext(workspace: workspace, currentDirectory: "/docs")
        )

        XCTAssertEqual(pwdResult.exitCode, 0)
        XCTAssertEqual(pwdResult.stdout, "/docs\n")
        XCTAssertEqual(pwdResult.stderr, "")
        XCTAssertFalse((pwdResult.stdout + pwdResult.stderr).contains(rootURL.path))

        let scriptURL = rootURL.appendingPathComponent("use-workspace-environment.sh")
        try """
        #!/bin/sh
        cat "$PWD/pwd-input.txt"
        tmpfile=$(mktemp "$TMPDIR/msp-external-runner.XXXXXX") || exit 1
        printf 'workspace env tmp content\\n' > "$tmpfile"
        cat "$tmpfile"
        printf 'PWD=%s\\n' "$PWD"
        printf 'TMPDIR=%s\\n' "$TMPDIR"
        printf 'MSP_WORKSPACE_ROOT=%s\\n' "$MSP_WORKSPACE_ROOT"
        printf 'TMPFILE=%s\\n' "$tmpfile"
        cat "$MSP_WORKSPACE_ROOT/docs/pwd-input.txt"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let scriptRunner = MSPHostProcessExternalRunner(executableURL: scriptURL)
        let scriptResult = try await scriptRunner.run(
            MSPExternalCommandRequest(
                executableName: "use-workspace-environment.sh",
                arguments: [],
                workingDirectory: "/docs"
            ),
            context: MSPCommandContext(workspace: workspace, currentDirectory: "/docs")
        )

        XCTAssertEqual(scriptResult.exitCode, 0)
        XCTAssertEqual(scriptResult.stderr, "")
        XCTAssertTrue(scriptResult.stdout.contains("workspace env path content\n"), scriptResult.stdout)
        XCTAssertTrue(scriptResult.stdout.contains("workspace env tmp content\n"), scriptResult.stdout)
        XCTAssertTrue(scriptResult.stdout.contains("PWD=/docs\n"), scriptResult.stdout)
        XCTAssertTrue(scriptResult.stdout.contains("TMPDIR=/tmp\n"), scriptResult.stdout)
        XCTAssertTrue(scriptResult.stdout.contains("MSP_WORKSPACE_ROOT=/\n"), scriptResult.stdout)
        XCTAssertTrue(scriptResult.stdout.contains("TMPFILE=/tmp/msp-external-runner."), scriptResult.stdout)
        XCTAssertFalse(scriptResult.stdout.contains(rootURL.path), scriptResult.stdout)
    }
    #endif

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPExternalRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func terminatePIDs(recordedAt url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/kill")
            process.arguments = ["-TERM", String(line)]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }
}

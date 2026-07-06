import Foundation
import XCTest
import MSPApple
import MSPCore
import MSPGit

final class MSPGitTests: XCTestCase {
    func testCommandPackRegistersGitCommand() throws {
        let registry = try MSPCommandRegistry()

        try MSPGitCommandPack().registerCommands(into: registry)

        XCTAssertNotNil(registry.command(named: "git"))
        XCTAssertEqual(registry.commandLookupPaths["git"], ["/usr/bin/git"])
    }

    func testUnavailableBackendReportsExplicitFailure() async throws {
        let registry = try MSPCommandRegistry()
        try MSPGitCommandPack().registerCommands(into: registry)

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "git", arguments: ["status", "--short"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "git: libgit2 backend is not configured\n")
    }

    func testGitStreamingDoesNotReadLiveStdinForStatus() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let input = RecordingGitInputStream()
        let stdout = MSPCommandOutputBuffer()
        let stderr = MSPCommandOutputBuffer()
        let command = MSPGitCommand(backend: MSPGitLibGit2Backend())

        let result = try await command.runStreaming(
            invocation: MSPCommandInvocation(name: "git", arguments: ["status", "--short"]),
            context: MSPCommandContext(
                workspace: workspace,
                standardInputStream: input,
                standardOutputStream: stdout,
                standardErrorStream: stderr
            )
        )

        XCTAssertEqual(result.exitCode, 128)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        let inputReadCount = await input.readCount()
        let stdoutText = String(decoding: await stdout.data(), as: UTF8.self)
        let stderrText = String(decoding: await stderr.data(), as: UTF8.self)
        XCTAssertEqual(inputReadCount, 0)
        XCTAssertEqual(stdoutText, "")
        XCTAssertEqual(
            stderrText,
            "fatal: not a git repository (or any of the parent directories): .git\n"
        )
    }

    func testWorkspaceMappingMapsSandboxRootAndVirtualizesOutput() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let context = MSPCommandContext(workspace: workspace)

        let mapping = try MSPGitWorkspaceMapping(context: context)

        XCTAssertEqual(mapping.virtualRootPath, "/")
        XCTAssertEqual(mapping.physicalRootPath, rootURL.standardizedFileURL.path)
        XCTAssertEqual(
            mapping.physicalPath(forVirtualPath: "/docs/a.txt"),
            rootURL.appendingPathComponent("docs/a.txt").standardizedFileURL.path
        )
        XCTAssertEqual(
            mapping.virtualPath(
                forPhysicalPath: rootURL.appendingPathComponent("docs/a.txt").path
            ),
            "/docs/a.txt"
        )

        let physicalPath = rootURL.appendingPathComponent("docs/a.txt").path
        let result = MSPCommandResult(
            stdout: "workspace=\(physicalPath)\n",
            stderr: "fatal: \(physicalPath): pathspec did not match\n",
            exitCode: 128
        )
        let sanitized = mapping.sanitize(result)
        XCTAssertEqual(sanitized.stdout, "workspace=/docs/a.txt\n")
        XCTAssertEqual(sanitized.stderr, "fatal: /docs/a.txt: pathspec did not match\n")
    }

    func testLinuxOracleFixtureTextMatchesBase64Bytes() throws {
        let fixture = try Self.gitOracleFixture()

        XCTAssertEqual(fixture.artifactKind, "msp-git-linux-oracle")
        XCTAssertEqual(fixture.gitCommandSteps.count, 24)

        let subcommands = Set(fixture.gitCommandSteps.compactMap { step in
            let arguments = step.modelArgv.map { Array($0.dropFirst()) } ?? []
            return MSPGitCompatibilityProfile.firstSubcommand(in: arguments)
        })
        XCTAssertEqual(subcommands, MSPGitCompatibilityProfile.linuxOracleSeedSubcommands)

        for step in fixture.gitCommandSteps {
            XCTAssertEqual(step.stdoutData, Data(step.stdoutText.utf8), step.id)
            XCTAssertEqual(step.stderrData, Data(step.stderrText.utf8), step.id)
        }
    }

    func testGitCommandSurfaceReplaysLinuxOracleCharacterForCharacter() async throws {
        let fixture = try Self.gitOracleFixture()

        for scenario in fixture.scenarios {
            let gitSteps = scenario.gitCommandSteps
            guard !gitSteps.isEmpty else {
                continue
            }
            let backend = MSPGitOracleReplayBackend(steps: gitSteps)
            let registry = try MSPCommandRegistry()
            try MSPGitCommandPack(backend: backend).registerCommands(into: registry)
            let executor = MSPCommandExecutor(registry: registry)

            for step in gitSteps {
                let argv = try XCTUnwrap(step.modelArgv, step.id)
                XCTAssertEqual(argv.first, "git", step.id)
                let result = await executor.run(
                    invocation: MSPCommandInvocation(
                        name: "git",
                        arguments: Array(argv.dropFirst())
                    ),
                    context: MSPCommandContext()
                )

                XCTAssertEqual(result.exitCode, step.exitCode, step.id)
                XCTAssertEqual(result.stdoutData, step.stdoutData, step.id)
                XCTAssertEqual(result.stderrData, step.stderrData, step.id)
            }

            let consumedCount = await backend.consumedCount()
            XCTAssertEqual(consumedCount, gitSteps.count, scenario.id)
        }
    }

    func testLibGit2BackendRunsSeedLifecycleWithGitLikeOutput() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let registry = try MSPCommandRegistry()
        try MSPGitCommandPack(backend: MSPGitLibGit2Backend()).registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        let context = MSPCommandContext(workspace: workspace)

        func run(_ arguments: [String]) async -> MSPCommandResult {
            await executor.run(
                invocation: MSPCommandInvocation(name: "git", arguments: arguments),
                context: context
            )
        }

        var result = await run(["status", "--short"])
        XCTAssertEqual(result.exitCode, 128)
        XCTAssertEqual(result.stderr, "fatal: not a git repository (or any of the parent directories): .git\n")

        try workspace.fileSystem.writeFile(
            "/docs/a.txt",
            data: Data("hello\n".utf8),
            from: "/",
            options: [.createParentDirectories]
        )

        result = await run(["init"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Initialized empty Git repository in /.git/\n")

        result = await run(["rev-parse", "--show-toplevel"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/\n")

        result = await run(["status", "--short"])
        XCTAssertEqual(result.stdout, "?? docs/\n")

        result = await run(["add", "/docs/a.txt"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")

        result = await run(["status", "--short"])
        XCTAssertEqual(result.stdout, "A  docs/a.txt\n")

        result = await run(["diff", "--cached", "--no-color", "--no-ext-diff", "--", "/docs/a.txt"])
        XCTAssertEqual(result.stdout, """
        diff --git a/docs/a.txt b/docs/a.txt
        new file mode 100644
        index 0000000..ce01362
        --- /dev/null
        +++ b/docs/a.txt
        @@ -0,0 +1 @@
        +hello

        """)

        result = await run(["commit", "-m", "add doc"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("] add doc\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains(" 1 file changed, 1 insertion(+)\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains(" create mode 100644 docs/a.txt\n"), result.stdout)
        let firstCommit = try XCTUnwrap(Self.firstCommitOIDPrefix(in: result.stdout))

        result = await run(["log", "--oneline"])
        XCTAssertEqual(result.stdout, "\(firstCommit) add doc\n")

        try workspace.fileSystem.writeFile(
            "/docs/a.txt",
            data: Data("hello\nworld\n".utf8),
            from: "/",
            options: [.overwriteExisting]
        )
        result = await run(["diff", "--no-color", "--no-ext-diff", "--", "/docs/a.txt"])
        XCTAssertEqual(result.stdout, """
        diff --git a/docs/a.txt b/docs/a.txt
        index ce01362..94954ab 100644
        --- a/docs/a.txt
        +++ b/docs/a.txt
        @@ -1 +1,2 @@
         hello
        +world

        """)

        result = await run(["status", "--short", "/docs/a.txt"])
        XCTAssertEqual(result.stdout, " M docs/a.txt\n")

        result = await run(["add", "/docs/a.txt"])
        XCTAssertEqual(result.exitCode, 0)
        result = await run(["commit", "-m", "update doc"])
        XCTAssertEqual(result.exitCode, 0)
        let secondCommit = try XCTUnwrap(Self.firstCommitOIDPrefix(in: result.stdout))

        result = await run(["log", "--oneline", "--max-count=2"])
        XCTAssertEqual(result.stdout, "\(secondCommit) update doc\n\(firstCommit) add doc\n")

        result = await run(["ls-files"])
        XCTAssertEqual(result.stdout, "docs/a.txt\n")

        result = await run(["show", "--stat", "--oneline", "--no-color", "HEAD"])
        XCTAssertEqual(result.stdout, """
        \(secondCommit) update doc
         docs/a.txt | 1 +
         1 file changed, 1 insertion(+)

        """)

        try workspace.fileSystem.createDirectory(
            "/tmp/gittestx",
            from: "/",
            intermediates: true
        )
        let subdirectoryContext = MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/tmp/gittestx"
        )
        result = await executor.run(
            invocation: MSPCommandInvocation(name: "git", arguments: ["rev-parse", "--show-toplevel", "--show-prefix"]),
            context: subdirectoryContext
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/\ntmp/gittestx/\n")
        result = await executor.run(
            invocation: MSPCommandInvocation(name: "git", arguments: ["status", "--short"]),
            context: subdirectoryContext
        )
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLibGit2BackendPreservesSpaceAndUnicodePathOutput() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let registry = try MSPCommandRegistry()
        try MSPGitCommandPack(backend: MSPGitLibGit2Backend()).registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        let context = MSPCommandContext(workspace: workspace)

        func run(_ arguments: [String]) async -> MSPCommandResult {
            await executor.run(
                invocation: MSPCommandInvocation(name: "git", arguments: arguments),
                context: context
            )
        }

        _ = await run(["init"])
        try workspace.fileSystem.writeFile(
            "/docs/report file.txt",
            data: Data("space\n".utf8),
            from: "/",
            options: [.createParentDirectories]
        )
        try workspace.fileSystem.writeFile(
            "/docs/中文.txt",
            data: Data("unicode\n".utf8),
            from: "/",
            options: [.createParentDirectories]
        )

        var result = await run(["status", "--short"])
        XCTAssertEqual(result.stdout, "?? docs/\n")
        result = await run(["add", "/docs/report file.txt"])
        XCTAssertEqual(result.exitCode, 0)
        result = await run(["add", "/docs/中文.txt"])
        XCTAssertEqual(result.exitCode, 0)
        result = await run(["status", "--short"])
        XCTAssertEqual(
            result.stdout,
            "A  \"docs/report file.txt\"\nA  docs/中文.txt\n"
        )
        result = await run(["commit", "-m", "add space and unicode paths"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(" 2 files changed, 2 insertions(+)\n"), result.stdout)
        XCTAssertTrue(
            result.stdout.contains(" create mode 100644 docs/report file.txt\n"),
            result.stdout
        )
        XCTAssertTrue(
            result.stdout.contains(" create mode 100644 docs/中文.txt\n"),
            result.stdout
        )
        result = await run(["ls-files"])
        XCTAssertEqual(result.stdout, "docs/report file.txt\ndocs/中文.txt\n")
    }

    private static func gitOracleFixture() throws -> GitOracleFixture {
        let url = try packageRoot()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("ReferenceOutputs")
            .appendingPathComponent("MSPV1GitLinuxOracle")
            .appendingPathComponent("noninteractive-cases.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitOracleFixture.self, from: data)
    }

    private static func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            let fixtureURL = url
                .appendingPathComponent("Conformance")
                .appendingPathComponent("ReferenceOutputs")
                .appendingPathComponent("MSPV1GitLinuxOracle")
                .appendingPathComponent("noninteractive-cases.json")
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(
            domain: "MSPGitTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "package root not found"]
        )
    }

    private static func firstCommitOIDPrefix(in commitOutput: String) -> String? {
        guard let close = commitOutput.firstIndex(of: "]") else {
            return nil
        }
        let prefix = commitOutput[..<close]
        return prefix
            .split(separator: " ")
            .last
            .map(String.init)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingGitInputStream: MSPCommandInputStream {
    private let storage = RecordingGitInputStreamStorage()

    func read(maxBytes: Int) async throws -> Data? {
        await storage.recordRead()
        return nil
    }

    func readCount() async -> Int {
        await storage.readCount()
    }
}

private actor RecordingGitInputStreamStorage {
    private var reads = 0

    func recordRead() {
        reads += 1
    }

    func readCount() -> Int {
        reads
    }
}

private actor MSPGitOracleReplayBackend: MSPGitBackend {
    private var steps: [GitOracleStep]
    private var index = 0

    init(steps: [GitOracleStep]) {
        self.steps = steps
    }

    func run(
        _ request: MSPGitCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard index < steps.count else {
            return .failure(exitCode: 125, stderr: "oracle replay exhausted\n")
        }
        let step = steps[index]
        index += 1
        guard request.modelArgv == step.modelArgv else {
            return .failure(
                exitCode: 125,
                stderr: "oracle replay argv mismatch: \(request.modelArgv.joined(separator: " "))\n"
            )
        }
        return MSPCommandResult(
            stdoutData: step.stdoutData,
            stderrData: step.stderrData,
            exitCode: step.exitCode
        )
    }

    func consumedCount() -> Int {
        index
    }
}

private struct GitOracleFixture: Decodable {
    var artifactKind: String
    var scenarios: [GitOracleScenario]

    var gitCommandSteps: [GitOracleStep] {
        scenarios.flatMap(\.gitCommandSteps)
    }
}

private struct GitOracleScenario: Decodable {
    var id: String
    var steps: [GitOracleStep]

    var gitCommandSteps: [GitOracleStep] {
        steps.filter { $0.kind == "git-command" }
    }
}

private struct GitOracleStep: Decodable {
    var id: String
    var kind: String
    var modelArgv: [String]?
    var stdoutText: String
    var stderrText: String
    var stdoutB64: String
    var stderrB64: String
    var exitCode: Int32

    var stdoutData: Data {
        Data(base64Encoded: stdoutB64) ?? Data()
    }

    var stderrData: Data {
        Data(base64Encoded: stderrB64) ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case modelArgv
        case stdoutText
        case stderrText
        case stdoutB64
        case stderrB64
        case exitCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        modelArgv = try container.decodeIfPresent([String].self, forKey: .modelArgv)
        stdoutText = try container.decodeIfPresent(String.self, forKey: .stdoutText) ?? ""
        stderrText = try container.decodeIfPresent(String.self, forKey: .stderrText) ?? ""
        stdoutB64 = try container.decodeIfPresent(String.self, forKey: .stdoutB64) ?? ""
        stderrB64 = try container.decodeIfPresent(String.self, forKey: .stderrB64) ?? ""
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 0
    }
}

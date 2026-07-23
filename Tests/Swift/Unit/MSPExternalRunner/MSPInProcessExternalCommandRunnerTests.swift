import Foundation
import XCTest
import MSPApple
import MSPCore
import MSPExternalRunner

private actor RecordingInProcessExecutor: MSPInProcessExternalCommandExecutor {
    private(set) var invocation: MSPInProcessExternalCommandInvocation?

    func execute(
        _ invocation: MSPInProcessExternalCommandInvocation
    ) async throws -> MSPCommandResult {
        self.invocation = invocation
        return MSPCommandResult(
            stdout: """
            OUTPUT=\(invocation.workingDirectoryURL.path)/output.pdf
            FONT=\(invocation.environment["MAGICK_FONT_PATH"] ?? "")/font.ttf

            """,
            stderr: "SELF=/runtime/bin/qpdf\n",
            exitCode: 3
        )
    }
}

private struct UnexpectedInProcessInputRead: Error {}

private final class RejectingInProcessInputStream: MSPCommandInputStream {
    func read(maxBytes: Int) async throws -> Data? {
        throw UnexpectedInProcessInputRead()
    }
}

final class MSPInProcessExternalCommandRunnerTests: XCTestCase {
    func testVersionOutputDoesNotRequireWorkspaceOrInvokeExecutor() async throws {
        let executor = RecordingInProcessExecutor()
        let runner = MSPInProcessExternalCommandRunner(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf"),
            versionOutput: "qpdf 12.0\n",
            executor: executor
        )

        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "qpdf",
                arguments: ["--version"]
            ),
            context: MSPCommandContext()
        )

        XCTAssertEqual(result, .success(stdout: "qpdf 12.0\n"))
        let invocation = await executor.invocation
        XCTAssertNil(invocation)
    }

    func testMapsInvocationAndSanitizesRawCommandResult() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let executor = RecordingInProcessExecutor()
        let runtimeFontsURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("runtime-fonts", isDirectory: true)
        let runner = MSPInProcessExternalCommandRunner(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf"),
            trustedHostEnvironment: [
                "MAGICK_FONT_PATH": runtimeFontsURL.path
            ],
            runtimePathMappings: [
                MSPOutputPathSanitizer.Mapping(
                    realPath: runtimeFontsURL.path,
                    virtualPath: "/usr/local/share/msp-runtime/fonts"
                )
            ],
            executor: executor
        )

        let result = try await runner.run(
            MSPExternalCommandRequest(
                executableName: "qpdf",
                arguments: [
                    "/docs/input.pdf",
                    "/docs/output.pdf",
                    "/usr/local/share/msp-runtime/fonts/font.ttf"
                ],
                environment: ["QPDF_TMP": "/tmp"],
                workingDirectory: "/docs"
            ),
            context: MSPCommandContext(
                workspace: workspace,
                currentDirectory: "/docs",
                standardInput: Data("password\n".utf8)
            )
        )

        let invocation = await executor.invocation
        XCTAssertEqual(
            invocation?.arguments,
            [
                rootURL.path + "/docs/input.pdf",
                rootURL.path + "/docs/output.pdf",
                runtimeFontsURL.path + "/font.ttf"
            ]
        )
        XCTAssertEqual(invocation?.workingDirectoryURL, docsURL)
        XCTAssertEqual(invocation?.environment["QPDF_TMP"], rootURL.path + "/tmp")
        XCTAssertEqual(invocation?.environment["MAGICK_FONT_PATH"], runtimeFontsURL.path)
        XCTAssertEqual(invocation?.standardInput, Data("password\n".utf8))
        XCTAssertEqual(
            result.stdout,
            "OUTPUT=/docs/output.pdf\n" +
            "FONT=/usr/local/share/msp-runtime/fonts/font.ttf\n"
        )
        XCTAssertEqual(result.stderr, "SELF=/usr/local/bin/qpdf\n")
        XCTAssertEqual(result.exitCode, 3)
    }

    func testInheritedLiveSessionInputDoesNotBlockInProcessCommandStartup() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let executor = RecordingInProcessExecutor()
        let runner = MSPInProcessExternalCommandRunner(
            executableURL: URL(fileURLWithPath: "/runtime/bin/git"),
            executor: executor
        )

        let result = try await runner.run(
            MSPExternalCommandRequest(executableName: "git", arguments: ["status"]),
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: Data("snapshot\n".utf8),
                standardInputStream: RejectingInProcessInputStream()
            )
        )

        XCTAssertEqual(result.exitCode, 3)
        let invocation = await executor.invocation
        XCTAssertEqual(invocation?.standardInput, Data("snapshot\n".utf8))
    }

    func testRedirectedInputIsBufferedBeforeInProcessCommandStartup() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let executor = RecordingInProcessExecutor()
        let runner = MSPInProcessExternalCommandRunner(
            executableURL: URL(fileURLWithPath: "/runtime/bin/qpdf"),
            executor: executor
        )

        let result = try await runner.run(
            MSPExternalCommandRequest(executableName: "qpdf", arguments: []),
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: Data("ignored snapshot\n".utf8),
                standardInputOverridesFileDescriptor: true,
                standardInputStream: MSPDataInputStream(Data("redirected\n".utf8))
            )
        )

        XCTAssertEqual(result.exitCode, 3)
        let invocation = await executor.invocation
        XCTAssertEqual(invocation?.standardInput, Data("redirected\n".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPInProcessExternalCommandRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

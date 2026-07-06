import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

class MSPPythonEmbeddedRuntimeTestCase: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPPythonEmbeddedRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func localCPythonLibrary() -> LocalCPythonLibrary? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["MSP_CPYTHON_LIBRARY_PATH"],
           !path.isEmpty {
            let homeURL = environment["MSP_CPYTHON_HOME"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0)
            }
            return LocalCPythonLibrary(
                libraryURL: URL(fileURLWithPath: path),
                homeURL: homeURL
            )
        }

        return nil
    }

    func embeddedCPythonShell(skipMessage: String) throws -> LocalCPythonShellFixture {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip(skipMessage)
        }

        let rootURL = try temporaryDirectory()
        do {
            let engine = try MSPCPythonEngine(
                library: .path(library.libraryURL),
                workspaceRootURL: rootURL,
                pythonHomeURL: library.homeURL
            )
            let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
                .enable(.posixCore)
                .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))
            return LocalCPythonShellFixture(rootURL: rootURL, shell: shell)
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func assertNoEmbeddedCPythonHostLeak(
        _ text: String,
        rootURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(text.contains(rootURL.path), file: file, line: line)
        XCTAssertFalse(text.contains("subprocess-broker"), file: file, line: line)
        XCTAssertFalse(text.contains("vfs-broker"), file: file, line: line)
        XCTAssertFalse(text.contains("_MSPPythonPopen"), file: file, line: line)
        XCTAssertFalse(text.contains("ios does not support processes"), file: file, line: line)
    }
}

struct LocalCPythonLibrary {
    var libraryURL: URL
    var homeURL: URL?
}

struct LocalCPythonShellFixture {
    var rootURL: URL
    var shell: ModelShellProxy

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

struct EchoEmbeddedPythonEngine: MSPPythonEmbeddedEngine {
    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        MSPPythonEmbeddedExecutionResult(stdout: """
        name=\(request.invocation.commandName)
        argv=\(request.invocation.arguments.joined(separator: "|"))
        entrypoint=\(render(request.entrypoint))
        cwd=\(request.virtualCurrentDirectory)
        pwd=\(request.environment["PWD"] ?? "")
        workspace=\(request.workspace == nil ? "no" : "yes")
        stdinBytes=\(request.standardInput.count)
        stdinClosed=\(request.standardInputClosed)
        umask=\(String(format: "%03o", request.fileCreationMask))

        """)
    }

    private func render(_ entrypoint: MSPPythonEntrypoint) -> String {
        switch entrypoint {
        case .command(let source, let arguments):
            return "command:\(source):\(arguments.joined(separator: "|"))"
        case .module(let name, let arguments):
            return "module:\(name):\(arguments.joined(separator: "|"))"
        case .script(let path, let arguments):
            return "script:\(path.virtualPath):\(arguments.joined(separator: "|"))"
        case .standardInput(let arguments):
            return "stdin:\(arguments.joined(separator: "|"))"
        case .interactive(let arguments):
            return "interactive:\(arguments.joined(separator: "|"))"
        }
    }
}

struct StreamingEchoEmbeddedPythonEngine: MSPPythonStreamingEmbeddedEngine {
    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        MSPPythonEmbeddedExecutionResult(stdout: "buffered\n")
    }

    func runPythonStreaming(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        try await request.standardOutputStream?.write(Data("READY\n".utf8))
        let chunk = try await request.standardInputStream?.read(maxBytes: 1024) ?? Data()
        let line = String(decoding: chunk, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        try await request.standardOutputStream?.write(Data("GOT:\(line)\n".utf8))
        return MSPPythonEmbeddedExecutionResult(
            stdoutData: Data(),
            stderrData: Data(),
            exitCode: 0
        )
    }
}

struct UnavailableEmbeddedPythonEngine: MSPPythonEmbeddedEngine {
    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult {
        throw MSPPythonEmbeddedRuntimeError.engineUnavailable("CPython library is not linked")
    }
}

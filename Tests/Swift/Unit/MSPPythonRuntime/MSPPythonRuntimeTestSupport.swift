import Foundation
import XCTest
import MSPCore
@testable import MSPPythonRuntime

class MSPPythonRuntimeTestCase: XCTestCase {
    func temporaryDirectory(prefix: String? = nil) throws -> URL {
        let name = prefix ?? String(describing: type(of: self))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func requireHostPython(
        _ purpose: String = "host-process Python tests.",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let path = "/usr/bin/python3"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(path) is required for \(purpose)", file: file, line: line)
        }
        return URL(fileURLWithPath: path)
    }

    func relativeWorkspacePaths(under rootURL: URL) throws -> [String] {
        let rootPath = rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            guard relativePath != ".msp", !relativePath.hasPrefix(".msp/") else { continue }
            paths.append(relativePath)
        }
        return paths.sorted()
    }
}

struct RecordingPythonRuntime: MSPPythonRuntime {
    func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        MSPCommandResult.success(stdout: """
        name=\(request.invocation.commandName)
        entrypoint=\(render(request.entrypoint))
        cwd=\(request.virtualCurrentDirectory)
        stdinBytes=\(context.standardInput.count)

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

actor LivePythonOutputCapture: MSPCommandOutputStream {
    private var buffer = Data()

    func write(_ data: Data) async throws {
        buffer.append(data)
    }

    func closeWrite() async {}

    func text() -> String {
        String(decoding: buffer, as: UTF8.self)
    }

    func waitUntilContains(
        _ needle: String,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if text().contains(needle) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return text().contains(needle)
    }
}

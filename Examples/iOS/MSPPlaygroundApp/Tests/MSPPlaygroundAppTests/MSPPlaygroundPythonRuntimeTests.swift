import Foundation
import XCTest
@testable import MSPPlaygroundApp

@MainActor
final class MSPPlaygroundPythonRuntimeTests: XCTestCase {
    func testMSPPlaygroundShellRunsConfiguredCPythonRuntime() async throws {
        guard let library = Self.configuredCPythonLibrary() else {
            throw XCTSkip("A configured CPython runtime is required for the MSPPlaygroundApp Python smoke test.")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPPlaygroundPythonRuntimeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = [
            "MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH": library.libraryURL.path
        ]
        if let homeURL = library.homeURL {
            environment["MSP_PLAYGROUND_CPYTHON_HOME"] = homeURL.path
        }
        let runtime = try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            workspaceProfile: .hostBacked,
            arguments: ["MSPPlaygroundApp", "--msp-enable-python"],
            environment: environment
        )

        let result = await runtime.run("""
        python3 -c 'print(42)'
        python -c 'print(43)'
        """)

        XCTAssertEqual(result.stdout, "42\n43\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    private static func configuredCPythonLibrary() -> ConfiguredCPythonLibrary? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawPath = environment["MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty else {
            return nil
        }
        let rawHome = environment["MSP_PLAYGROUND_CPYTHON_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let homeURL = rawHome.flatMap { rawValue -> URL? in
            rawValue.isEmpty ? nil : URL(fileURLWithPath: rawValue)
        }
        return ConfiguredCPythonLibrary(
            libraryURL: URL(fileURLWithPath: rawPath),
            homeURL: homeURL
        )
    }
}

private struct ConfiguredCPythonLibrary {
    var libraryURL: URL
    var homeURL: URL?
}

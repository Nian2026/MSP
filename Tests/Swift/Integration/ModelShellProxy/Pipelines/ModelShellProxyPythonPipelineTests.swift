import Foundation
import XCTest
import MSPApple
import ModelShellProxy
import MSPPythonRuntime

#if os(macOS)
final class ModelShellProxyPythonPipelineTests: ModelShellProxyIntegrationTestCase {
    func testHostPythonBinaryStdoutToTeeDevStderrFeedsDownstreamOnce() async throws {
        let shell = try makeHostPythonPipelineShell()

        let direct = await shell.run("""
        python3 - <<'PY' | wc -c
        import sys
        sys.stdout.buffer.write(bytes(range(16)))
        PY
        """)
        XCTAssertEqual(direct.stdout, "16\n")
        XCTAssertEqual(direct.stderr, "")
        XCTAssertEqual(direct.exitCode, 0)

        let result = await shell.run("""
        python3 - <<'PY' | tee /dev/stderr | wc -c
        import sys
        sys.stdout.buffer.write(bytes(range(16)))
        PY
        """)

        XCTAssertEqual(result.stdout, "16\n")
        XCTAssertEqual(result.stderrData, Data((0..<16).map { UInt8($0) }))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHostPythonInfiniteStdoutStopsWhenHeadClosesPipe() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try """
        import signal
        import sys

        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        while True:
            sys.stdout.write("ready\\n")
            sys.stdout.flush()
        """.write(
            to: rootURL.appendingPathComponent("producer.py"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try makeHostPythonPipelineShell(rootURL: rootURL, timeout: 2)

        let startedAt = Date()
        let result = await shell.run("python3 -u producer.py | head -n 1")

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
        XCTAssertEqual(result.stdout, "ready\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    private func makeHostPythonPipelineShell(
        rootURL: URL? = nil,
        timeout: TimeInterval = 30
    ) throws -> ModelShellProxy {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for host Python pipeline tests.")
        }
        let workspaceRoot = rootURL ?? makeTemporaryURL()
        if rootURL == nil {
            addTeardownBlock { [workspaceRoot] in
                self.removeTemporaryURL(workspaceRoot)
            }
        }
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        return try ModelShellProxy.iOS(workspaceURL: workspaceRoot)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: workspaceRoot,
                timeout: timeout
            )))
    }
}
#endif

import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

final class MSPPythonHostProcessTracebackTests: MSPPythonRuntimeTestCase {
    #if os(macOS)
    func testPythonOutputPathSanitizerHidesWorkspaceAndRuntimePaths() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runURL = rootURL.appendingPathComponent(".msp-python/run-1", isDirectory: true)
        let vfsBrokerURL = runURL.appendingPathComponent("vfs-broker", isDirectory: true)
        let materializedURL = runURL.appendingPathComponent("vfs-materialized", isDirectory: true)
        let subprocessURL = runURL.appendingPathComponent("subprocess-broker", isDirectory: true)
        let resultURL = runURL.appendingPathComponent("result.json")
        let sanitizer = MSPPythonOutputPathSanitizer(
            workspaceRootURL: rootURL,
            runtimeDirectoryMappings: [
                (vfsBrokerURL, "/tmp"),
                (materializedURL, "/tmp"),
                (subprocessURL, "/tmp"),
                (runURL, "/tmp")
            ],
            runtimeFileMappings: [
                (resultURL, "/tmp/result.json")
            ]
        )
        let raw = """
        workspace=\(rootURL.path)/docs/a.txt
        broker=\(vfsBrokerURL.path)/request.json
        materialized=\(materializedURL.path)/asset.bin
        subprocess=\(subprocessURL.path)/response.json
        result=\(resultURL.path)

        """

        let sanitized = String(decoding: sanitizer.sanitize(Data(raw.utf8)), as: UTF8.self)

        XCTAssertEqual(sanitized, """
        workspace=/docs/a.txt
        broker=/tmp/request.json
        materialized=/tmp/asset.bin
        subprocess=/tmp/response.json
        result=/tmp/result.json

        """)
        XCTAssertFalse(sanitized.contains(rootURL.path))
        XCTAssertFalse(sanitized.contains("vfs-broker"))
        XCTAssertFalse(sanitized.contains("vfs-materialized"))
        XCTAssertFalse(sanitized.contains("subprocess-broker"))

        let siblingRaw = """
        sibling-dash=\(rootURL.path)-other/docs/a.txt
        sibling-dot=\(rootURL.path).backup/docs/a.txt
        embedded-prefix=prefix\(rootURL.path)/docs/a.txt

        """
        let siblingSanitized = String(decoding: sanitizer.sanitize(Data(siblingRaw.utf8)), as: UTF8.self)
        XCTAssertEqual(siblingSanitized, siblingRaw)
    }

    func testPythonOutputPathSanitizerHidesEncodedFileURLs() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspaceURL = rootURL.appendingPathComponent("Workspace Root", isDirectory: true)
        let runURL = rootURL.appendingPathComponent(".msp python/run 1", isDirectory: true)
        let materializedURL = runURL.appendingPathComponent("vfs materialized", isDirectory: true)
        let resultURL = runURL.appendingPathComponent("result file.json")
        let sanitizer = MSPPythonOutputPathSanitizer(
            workspaceRootURL: workspaceURL,
            runtimeDirectoryMappings: [
                (materializedURL, "/tmp"),
                (runURL, "/tmp")
            ],
            runtimeFileMappings: [
                (resultURL, "/tmp/result file.json")
            ]
        )

        let raw = """
        workspace-uri=\(workspaceURL.appendingPathComponent("docs/a b.txt").absoluteString)
        materialized-uri=\(materializedURL.appendingPathComponent("asset 1.bin").absoluteString)
        result-uri=\(resultURL.absoluteString)

        """

        let sanitized = String(decoding: sanitizer.sanitize(Data(raw.utf8)), as: UTF8.self)

        XCTAssertEqual(sanitized, """
        workspace-uri=file:///docs/a%20b.txt
        materialized-uri=file:///tmp/asset%201.bin
        result-uri=file:///tmp/result%20file.json

        """)
        XCTAssertFalse(sanitized.contains(workspaceURL.path))
        XCTAssertFalse(sanitized.contains(workspaceURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspaceURL.path))
        XCTAssertFalse(sanitized.contains("vfs%20materialized"))
        XCTAssertFalse(sanitized.contains(".msp%20python"))

        let siblingURL = URL(fileURLWithPath: workspaceURL.path + "-other/docs/a.txt").absoluteString
        let siblingRaw = "sibling-uri=\(siblingURL)\n"
        let siblingSanitized = String(decoding: sanitizer.sanitize(Data(siblingRaw.utf8)), as: UTF8.self)
        XCTAssertEqual(siblingSanitized, siblingRaw)
    }

    func testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspaceURL = rootURL.appendingPathComponent("Workspace Root", isDirectory: true)
        let sanitizer = MSPPythonOutputPathSanitizer(workspaceRootURL: workspaceURL)
        var streamingSanitizer = MSPPythonStreamingOutputSanitizer(
            sanitizer: sanitizer,
            maxBufferedBytes: 8
        )
        let raw = "prefix=\(workspaceURL.path)/docs/a.txt;uri=\(workspaceURL.appendingPathComponent("docs/a b.txt").absoluteString);suffix"
        let chunks = raw.utf8.map { Data([$0]) }

        var sanitizedData = chunks.reduce(into: Data()) { output, chunk in
            output.append(streamingSanitizer.append(chunk))
        }
        sanitizedData.append(streamingSanitizer.flush())
        let sanitized = String(decoding: sanitizedData, as: UTF8.self)

        XCTAssertEqual(
            sanitized,
            "prefix=/docs/a.txt;uri=file:///docs/a%20b.txt;suffix"
        )
        XCTAssertFalse(sanitized.contains(workspaceURL.path))
        XCTAssertFalse(sanitized.contains("Workspace%20Root"))
    }

    func testHostProcessPythonTracebackStaysVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        python3 -S - <<'PY'
        open('/tmp/missing.txt')
        PY
        """)

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("FileNotFoundError"))
        XCTAssertTrue(result.stderr.contains("No such file or directory"))
        XCTAssertTrue(result.stderr.contains("'/tmp/missing.txt'"))
        XCTAssertFalse(result.stderr.contains("workspace path not found"))
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
        XCTAssertFalse((result.stdout + result.stderr).contains("MSPPythonHostProcessRuntime"))

        let formatted = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        import traceback
        try:
            Path('/tmp/missing-dir/file.txt').read_text(encoding='utf-8')
        except Exception:
            print(traceback.format_exc(), end='')
        PY
        """)

        XCTAssertEqual(formatted.stderr, "")
        XCTAssertEqual(formatted.exitCode, 0)
        XCTAssertTrue(formatted.stdout.contains("FileNotFoundError"))
        XCTAssertTrue(formatted.stdout.contains("No such file or directory"))
        XCTAssertTrue(formatted.stdout.contains("'/tmp/missing-dir/file.txt'"))
        XCTAssertFalse(formatted.stdout.contains("workspace path not found"))
        XCTAssertTrue(formatted.stdout.contains(#"File "/usr/lib/python"#))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains(rootURL.path))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("/opt/homebrew"))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("/Library/Developer"))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("subprocess-broker"))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("vfs-broker"))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((formatted.stdout + formatted.stderr).contains("_msp_vfs"))
    }

    func testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath() async throws {
        let pythonURL = try requireHostPython("host-process Python script traceback tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        mkdir -p /tmp
        cat > /tmp/boom.py <<'PY'
        import sys
        print('__file__=' + __file__)
        print('argv0=' + sys.argv[0])
        raise RuntimeError('script exploded')
        PY
        python3 -S -E -I /tmp/boom.py
        """)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, """
        __file__=/tmp/boom.py
        argv0=/tmp/boom.py

        """)
        XCTAssertTrue(result.stderr.contains("Traceback (most recent call last):"))
        XCTAssertTrue(result.stderr.contains(#"File "/tmp/boom.py", line 4, in <module>"#), result.stderr)
        XCTAssertTrue(result.stderr.contains("RuntimeError: script exploded"), result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
    }
    #endif
}

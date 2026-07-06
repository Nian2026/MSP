import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testLinkModeSearchAndProcessMetadataCommandsStayInsideWorkspace() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\nbeta\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let link = await shell.run("ln docs/a.txt hard.txt; printf 'changed\\n' > hard.txt; cat docs/a.txt; ln -s docs/a.txt link.txt; readlink link.txt; cat link.txt")
        let mode = await shell.run("chmod 755 docs/a.txt; stat -c %a docs/a.txt")
        let search = await shell.run("rg -n changed docs")
        let files = await shell.run("rg --files docs")
        let process = await shell.run("ps -o pid,comm")
        let lddVersion = await shell.run("ldd --version")
        let lddFile = await shell.run("ldd docs/a.txt")

        XCTAssertEqual(link.stdout, "changed\ndocs/a.txt\nchanged\n")
        XCTAssertEqual(link.stderr, "")
        XCTAssertEqual(link.exitCode, 0)
        XCTAssertEqual(mode.stdout, "755\n")
        XCTAssertEqual(mode.stderr, "")
        XCTAssertEqual(mode.exitCode, 0)
        XCTAssertEqual(search.stdout, "docs/a.txt:1:changed\n")
        XCTAssertEqual(search.stderr, "")
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertEqual(files.stdout, "docs/a.txt\n")
        XCTAssertEqual(files.stderr, "")
        XCTAssertEqual(files.exitCode, 0)
        XCTAssertEqual(process.stdout, "    PID COMMAND\n  12345 bash\n")
        XCTAssertEqual(lddVersion.stdout, "ldd (Debian GLIBC 2.36-9+deb12u14) 2.36\n")
        XCTAssertEqual(lddFile.stderr, "\tnot a dynamic executable\n")
        XCTAssertEqual(lddFile.exitCode, 1)
        XCTAssertFalse(link.stdout.contains(rootURL.path))
        XCTAssertFalse(search.stdout.contains(rootURL.path))
        XCTAssertFalse(files.stdout.contains(rootURL.path))
        XCTAssertFalse(lddFile.stderr.contains(rootURL.path))
    }
}

import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testMiscProcessNumericAndSearchCommandsUseWorkspaceFacade() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/b.md"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let date = await shell.run("date -u -d @0 '+%F %T'")
        let bc = await shell.run("printf 'scale=2; 1/4\\n' | bc")
        let numfmt = await shell.run("printf 'aa 1500 zz\\n' | numfmt --field=2 --to=si")
        let psInvalid = await shell.run("ps --bad-option")
        let timeoutInvalid = await shell.run("timeout --bad 1 true")
        let lddPlain = await shell.run("ldd docs/a.txt")
        let rgGlob = await shell.run("rg --files -g '*.txt' docs")
        let rgMissing = await shell.run("rg alpha missing")

        XCTAssertEqual(date.stdout, "1970-01-01 00:00:00\n")
        XCTAssertEqual(bc.stdout, ".25\n")
        XCTAssertEqual(numfmt.stdout, "aa 1.5K zz\n")
        XCTAssertEqual(psInvalid.exitCode, 1)
        XCTAssertTrue(psInvalid.stderr.contains("unknown gnu long option"))
        XCTAssertEqual(timeoutInvalid.exitCode, 125)
        XCTAssertEqual(
            timeoutInvalid.stderr,
            "timeout: unrecognized option '--bad'\nTry 'timeout --help' for more information.\n"
        )
        XCTAssertEqual(lddPlain.stderr, "\tnot a dynamic executable\n")
        XCTAssertEqual(lddPlain.exitCode, 1)
        XCTAssertEqual(rgGlob.stdout, "docs/a.txt\n")
        XCTAssertEqual(rgMissing.stderr, "missing: No such file or directory (os error 2)\n")
        XCTAssertEqual(rgMissing.exitCode, 2)
        XCTAssertFalse(lddPlain.stderr.contains(rootURL.path))
        XCTAssertFalse(rgGlob.stdout.contains(rootURL.path))
        XCTAssertFalse(rgMissing.stderr.contains(rootURL.path))
    }
}

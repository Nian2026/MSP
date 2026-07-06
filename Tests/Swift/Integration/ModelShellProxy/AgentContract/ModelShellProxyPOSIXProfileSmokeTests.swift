import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testPOSIXCoreProfileRunsAgainstWorkspaceFS() async throws {
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

        let pwd = await shell.run("pwd")
        let mkdir = await shell.run("mkdir -p docs/nested")
        let touch = await shell.run("touch docs/nested/empty.txt")
        let cat = await shell.run("cat -n docs/a.txt")
        let ls = await shell.run("ls docs")
        let stat = await shell.run("stat -c '%n %F %s' docs/a.txt")

        XCTAssertEqual(pwd.stdout, "/\n")
        XCTAssertEqual(mkdir.exitCode, 0)
        XCTAssertEqual(touch.exitCode, 0)
        XCTAssertEqual(cat.stdout, "     1\talpha\n     2\tbeta\n")
        XCTAssertEqual(ls.stdout, "a.txt\nnested\n")
        XCTAssertEqual(stat.stdout, "docs/a.txt regular file 11\n")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("docs/nested/empty.txt").path
            )
        )
    }

    func testPOSIXCoreProfileCanExcludeSelectedCommands() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore(excluding: ["sha256sum", "md5sum", "cksum"]))

        let missing = await shell.run("sha256sum --version")
        let find = await shell.run("find / -maxdepth 1 -type d")
        let ls = await shell.run("ls /")

        XCTAssertEqual(missing.exitCode, 127)
        XCTAssertEqual(missing.stderr, "sha256sum: command not found\n")
        XCTAssertEqual(find.exitCode, 0)
        XCTAssertEqual(ls.exitCode, 0)
    }

}

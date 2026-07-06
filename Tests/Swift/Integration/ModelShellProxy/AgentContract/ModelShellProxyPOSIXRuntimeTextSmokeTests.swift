import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testSedRunsScriptsFromStdinFilesAndWorkspaceScriptFiles() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "one\ntwo\nthree\n".write(
            to: rootURL.appendingPathComponent("docs/input.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "s/[0-9]+/#/g\n".write(
            to: rootURL.appendingPathComponent("script.sed"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let pipeline = await shell.run("printf 'alpha\\nbeta\\n' | sed 's/a/A/g'")
        let addressed = await shell.run("sed -n '2p' docs/input.txt")
        let scriptFile = await shell.run("printf 'a1\\nb22\\n' | sed -E -f script.sed")
        let inPlace = await shell.run("sed -i 's/two/TWO/' docs/input.txt; cat docs/input.txt")

        XCTAssertEqual(pipeline.stdout, "AlphA\nbetA\n")
        XCTAssertEqual(pipeline.stderr, "")
        XCTAssertEqual(pipeline.exitCode, 0)
        XCTAssertEqual(addressed.stdout, "two\n")
        XCTAssertEqual(addressed.stderr, "")
        XCTAssertEqual(addressed.exitCode, 0)
        XCTAssertEqual(scriptFile.stdout, "a#\nb#\n")
        XCTAssertEqual(scriptFile.stderr, "")
        XCTAssertEqual(scriptFile.exitCode, 0)
        XCTAssertEqual(inPlace.stdout, "one\nTWO\nthree\n")
        XCTAssertEqual(inPlace.stderr, "")
        XCTAssertEqual(inPlace.exitCode, 0)
        XCTAssertFalse(inPlace.stdout.contains(rootURL.path))
    }

    func testXargsTimeoutYesAndDoubleBracketUseSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let yes = await shell.run("yes ok | head -n 3")
        let xargs = await shell.run("printf 'a\\nb\\n' | xargs -n1 echo item")
        let replacement = await shell.run("printf 'left\\nright\\n' | xargs -I{} echo '<{}>'")
        let timeout = await shell.run("timeout 1 command printf 'done\\n'")
        let timeoutFailure = await shell.run("timeout 1 false")
        let timeoutMissing = await shell.run("timeout 1 no-such-cmd")
        let doubleBracket = await shell.run("[[ 3 -gt 2 ]]")

        XCTAssertEqual(yes.stdout, "ok\nok\nok\n")
        XCTAssertEqual(yes.stderr, "")
        XCTAssertEqual(yes.exitCode, 0)
        XCTAssertEqual(xargs.stdout, "item a\nitem b\n")
        XCTAssertEqual(xargs.stderr, "")
        XCTAssertEqual(xargs.exitCode, 0)
        XCTAssertEqual(replacement.stdout, "<left>\n<right>\n")
        XCTAssertEqual(replacement.stderr, "")
        XCTAssertEqual(replacement.exitCode, 0)
        XCTAssertEqual(timeout.stdout, "done\n")
        XCTAssertEqual(timeout.stderr, "")
        XCTAssertEqual(timeout.exitCode, 0)
        XCTAssertEqual(timeoutFailure.stdout, "")
        XCTAssertEqual(timeoutFailure.stderr, "")
        XCTAssertEqual(timeoutFailure.exitCode, 1)
        XCTAssertEqual(timeoutMissing.stdout, "")
        XCTAssertEqual(
            timeoutMissing.stderr,
            "timeout: failed to run command \u{2018}no-such-cmd\u{2019}: No such file or directory\n"
        )
        XCTAssertEqual(timeoutMissing.exitCode, 127)
        XCTAssertEqual(doubleBracket.stdout, "")
        XCTAssertEqual(doubleBracket.stderr, "")
        XCTAssertEqual(doubleBracket.exitCode, 0)
    }

}

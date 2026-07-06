import Foundation
import XCTest
import MSPApple
import ModelShellProxy

extension ModelShellProxyScriptExecutionTests {
    func testSourceRunsWorkspaceScriptsInCurrentShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try """
        echo "script:$0:$1:$2:$#"
        FOO=sourced
        made() { echo made:$FOO; }
        cd sub
        return 7
        echo never
        """.write(
            to: rootURL.appendingPathComponent("scripts/env.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "echo noargs:$1:$#\n".write(
            to: rootURL.appendingPathComponent("scripts/noargs.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "echo redirected\n".write(
            to: rootURL.appendingPathComponent("scripts/print.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "echo in-source\nreturn 3\necho never\n".write(
            to: rootURL.appendingPathComponent("scripts/return.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "FOO=from-source\ncd sub\n".write(
            to: rootURL.appendingPathComponent("scripts/state.sh"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let sourceState = await shell.run("set -- outer1 outer2; FOO=outer; source scripts/env.sh a b; printf 'status:%s FOO:%s args:%s/%s/%s\\n' \"$?\" \"$FOO\" \"$1\" \"$2\" \"$#\"; pwd; made")
        let dotNoArgs = await shell.run("cd /; set -- keep; . scripts/noargs.sh; printf 'after:%s/%s\\n' \"$1\" \"$#\"")
        let redirected = await shell.run("source scripts/print.sh > sourced.out; cat sourced.out")
        let sourceReturnInsideFunction = await shell.run("f() { . scripts/return.sh; echo after:$?; }; f; echo fstatus:$?")
        let missing = await shell.run(". missing.sh")
        let pipelineIsolation = await shell.run("cd /; FOO=outer; source scripts/state.sh | cat; printf '%s ' \"$FOO\"; pwd")
        let lookup = await shell.run("command -v source; type source; command -v .; type .")

        XCTAssertEqual(
            sourceState.stdout,
            "script:msp:a:b:2\nstatus:7 FOO:sourced args:outer1/outer2/2\n/sub\nmade:sourced\n"
        )
        XCTAssertEqual(sourceState.stderr, "")
        XCTAssertEqual(sourceState.exitCode, 0)
        XCTAssertEqual(dotNoArgs.stdout, "noargs:keep:1\nafter:keep/1\n")
        XCTAssertEqual(dotNoArgs.stderr, "")
        XCTAssertEqual(dotNoArgs.exitCode, 0)
        XCTAssertEqual(redirected.stdout, "redirected\n")
        XCTAssertEqual(redirected.stderr, "")
        XCTAssertEqual(redirected.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("sourced.out"), encoding: .utf8),
            "redirected\n"
        )
        XCTAssertEqual(sourceReturnInsideFunction.stdout, "in-source\nafter:3\nfstatus:0\n")
        XCTAssertEqual(sourceReturnInsideFunction.stderr, "")
        XCTAssertEqual(sourceReturnInsideFunction.exitCode, 0)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertTrue(missing.stderr.contains(".: missing.sh: No such file or directory\n"))
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(pipelineIsolation.stdout, "outer /\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(lookup.stdout, "source\nsource is a shell builtin\n.\n. is a shell builtin\n")
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertFalse(sourceState.stdout.contains(rootURL.path))
        XCTAssertFalse(missing.stderr.contains(rootURL.path))
    }

    func testDiagnosticContextRestoresAfterNestedRuntimeFrames() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try """
        from_file() {
          printf '<%s>\\n' "$(bash scripts/bad.sh 2>&1)"
        }
        from_file
        """.write(
            to: rootURL.appendingPathComponent("scripts/outer.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "if true; then echo missing\n".write(
            to: rootURL.appendingPathComponent("scripts/bad.sh"),
            atomically: true,
            encoding: .utf8
        )
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                workspace: workspace,
                shellDiagnosticProfile: .bash(scriptName: "/bin/bash")
            )
        ).enable(.posixCore)

        let nested = await shell.run("source scripts/outer.sh")
        let topLevelSyntaxError = await shell.run("if true; then echo top")

        XCTAssertTrue(nested.stdout.contains("scripts/bad.sh: line 3: syntax error: unexpected end of file"))
        XCTAssertEqual(nested.stderr, "")
        XCTAssertFalse(nested.stdout.contains(rootURL.path))
        XCTAssertEqual(nested.exitCode, 0)
        XCTAssertTrue(topLevelSyntaxError.stderr.contains("/bin/bash: line 2: syntax error: unexpected end of file\n"))
        XCTAssertFalse(topLevelSyntaxError.stderr.contains("scripts/outer.sh: line 1: syntax error: unexpected end of file\n"))
        XCTAssertFalse(topLevelSyntaxError.stderr.contains(rootURL.path))
        XCTAssertEqual(topLevelSyntaxError.exitCode, 2)
    }

}

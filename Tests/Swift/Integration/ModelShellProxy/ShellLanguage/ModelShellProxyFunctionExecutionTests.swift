import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyScriptExecutionTests {
    func testShellFunctionsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let basic = await shell.run("greet() { echo hi; }; greet")
        let arguments = await shell.run("show() { printf '%s/%s/%s/%s\\n' \"$0\" \"$1\" \"$2\" \"$#\"; }; show a b")
        let quotedSplat = await shell.run("forward() { printf '<%s>\\n' \"$@\"; }; forward 'a a' b")
        let embeddedQuotedSplat = await shell.run("wrap() { printf '<%s>\\n' pre\"$@\"post; }; wrap 'a a' b")
        let emptyQuotedSplat = await shell.run("none() { printf '<%s>\\n' \"$@\" pre\"$@\"post; }; none")
        let returnStopsBody = await shell.run("f() { echo before; return 7; echo after; }; f; echo status:$?")
        let returnOutsideFunction = await shell.run("return 3")
        let braceStatePersists = await shell.run("movein() { mkdir -p d; cd d; }; movein; pwd")
        let subshellBodyIsolatesCWD = await shell.run("localcwd() ( mkdir -p sub; cd sub; pwd ); localcwd; pwd; test -d sub && echo exists")
        let implicitForParameters = await shell.run("each() { for item; do echo \"[$item]\"; done; }; each a b")
        let definitionRedirection = await shell.run("logit() { echo hi; } > out.txt; logit; cat out.txt")
        let callRedirection = await shell.run("say() { echo hi; }; say > call.txt; cat call.txt")
        let callRedirectionBeforeCWDChange = await shell.run("cd /; writer() { mkdir -p fdir; cd fdir; echo hi; }; writer > fn.txt; pwd; cat /fn.txt; test -f /fdir/fn.txt && echo bad")
        let pipelineIsolation = await shell.run("f() { FOO=new; echo x; }; FOO=old; f | cat; printf '%s\\n' \"$FOO\"")
        let pipelineDefinitionIsolation = await shell.run("temp() { echo leaked; } | cat; temp")
        let commandSubstitutionDefinitionIsolation = await shell.run("printf '%s\\n' \"$(inner() { echo inside; }; inner)\"; inner")
        let commandBypassesFunction = await shell.run("echo() { command echo function; }; echo; command echo builtin")
        let builtinBypassesFunction = await shell.run("printf() { command echo function; }; printf; builtin printf 'builtin\\n'")

        XCTAssertEqual(basic.stdout, "hi\n")
        XCTAssertEqual(basic.stderr, "")
        XCTAssertEqual(basic.exitCode, 0)
        XCTAssertEqual(arguments.stdout, "show/a/b/2\n")
        XCTAssertEqual(arguments.stderr, "")
        XCTAssertEqual(arguments.exitCode, 0)
        XCTAssertEqual(quotedSplat.stdout, "<a a>\n<b>\n")
        XCTAssertEqual(quotedSplat.stderr, "")
        XCTAssertEqual(quotedSplat.exitCode, 0)
        XCTAssertEqual(embeddedQuotedSplat.stdout, "<prea a>\n<bpost>\n")
        XCTAssertEqual(embeddedQuotedSplat.stderr, "")
        XCTAssertEqual(embeddedQuotedSplat.exitCode, 0)
        XCTAssertEqual(emptyQuotedSplat.stdout, "<prepost>\n")
        XCTAssertEqual(emptyQuotedSplat.stderr, "")
        XCTAssertEqual(emptyQuotedSplat.exitCode, 0)
        XCTAssertEqual(returnStopsBody.stdout, "before\nstatus:7\n")
        XCTAssertEqual(returnStopsBody.stderr, "")
        XCTAssertEqual(returnStopsBody.exitCode, 0)
        XCTAssertEqual(returnOutsideFunction.stdout, "")
        XCTAssertEqual(returnOutsideFunction.stderr, "return: can only `return' from a function\n")
        XCTAssertEqual(returnOutsideFunction.exitCode, 2)
        XCTAssertEqual(braceStatePersists.stdout, "/d\n")
        XCTAssertEqual(braceStatePersists.stderr, "")
        XCTAssertEqual(braceStatePersists.exitCode, 0)
        XCTAssertEqual(subshellBodyIsolatesCWD.stdout, "/d/sub\n/d\nexists\n")
        XCTAssertEqual(subshellBodyIsolatesCWD.stderr, "")
        XCTAssertEqual(subshellBodyIsolatesCWD.exitCode, 0)
        XCTAssertEqual(implicitForParameters.stdout, "[a]\n[b]\n")
        XCTAssertEqual(implicitForParameters.stderr, "")
        XCTAssertEqual(implicitForParameters.exitCode, 0)
        XCTAssertEqual(definitionRedirection.stdout, "hi\n")
        XCTAssertEqual(definitionRedirection.stderr, "")
        XCTAssertEqual(definitionRedirection.exitCode, 0)
        XCTAssertEqual(callRedirection.stdout, "hi\n")
        XCTAssertEqual(callRedirection.stderr, "")
        XCTAssertEqual(callRedirection.exitCode, 0)
        XCTAssertEqual(callRedirectionBeforeCWDChange.stdout, "/fdir\nhi\n")
        XCTAssertEqual(callRedirectionBeforeCWDChange.stderr, "")
        XCTAssertEqual(callRedirectionBeforeCWDChange.exitCode, 1)
        XCTAssertEqual(pipelineIsolation.stdout, "x\nold\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(pipelineDefinitionIsolation.stdout, "")
        XCTAssertEqual(pipelineDefinitionIsolation.stderr, "temp: command not found\n")
        XCTAssertEqual(pipelineDefinitionIsolation.exitCode, 127)
        XCTAssertEqual(commandSubstitutionDefinitionIsolation.stdout, "inside\n")
        XCTAssertEqual(commandSubstitutionDefinitionIsolation.stderr, "inner: command not found\n")
        XCTAssertEqual(commandSubstitutionDefinitionIsolation.exitCode, 127)
        XCTAssertEqual(commandBypassesFunction.stdout, "function\nbuiltin\n")
        XCTAssertEqual(commandBypassesFunction.stderr, "")
        XCTAssertEqual(commandBypassesFunction.exitCode, 0)
        XCTAssertEqual(builtinBypassesFunction.stdout, "function\nbuiltin\n")
        XCTAssertEqual(builtinBypassesFunction.stderr, "")
        XCTAssertEqual(builtinBypassesFunction.exitCode, 0)
        XCTAssertFalse(basic.stdout.contains(rootURL.path))
        XCTAssertFalse(subshellBodyIsolatesCWD.stdout.contains(rootURL.path))
        XCTAssertFalse(definitionRedirection.stdout.contains(rootURL.path))
        XCTAssertFalse(callRedirection.stdout.contains(rootURL.path))
    }

    func testShellFunctionDefinitionRedirectionsCarryStandardInputClosedState() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let definitionClosesStdin = await shell.run("f() { cat; } <&-; f")
        let definitionReopensParentClosedStdin = await shell.run(
            "exec <&-; printf 'opened\\n' > input.txt; f() { cat; } < input.txt; f"
        )

        XCTAssertEqual(definitionClosesStdin.stdout, "")
        XCTAssertEqual(definitionClosesStdin.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(definitionClosesStdin.exitCode, 1)
        XCTAssertEqual(definitionReopensParentClosedStdin.stdout, "opened\n")
        XCTAssertEqual(definitionReopensParentClosedStdin.stderr, "")
        XCTAssertEqual(definitionReopensParentClosedStdin.exitCode, 0)
    }

}

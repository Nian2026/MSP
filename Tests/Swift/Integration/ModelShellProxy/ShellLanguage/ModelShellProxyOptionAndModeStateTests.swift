import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyShellStateTests {
    func testSetShellOptionsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "a".write(
            to: rootURL.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "b".write(
            to: rootURL.appendingPathComponent("b.txt"),
            atomically: true,
            encoding: .utf8
        )

        let globShell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let statusShell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let nounsetShell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let errexitShell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let suppressedOrShell = try ModelShellProxy()
            .enable(.posixCore)
        let failingAndTailShell = try ModelShellProxy()
            .enable(.posixCore)
        let conditionSuppressionShell = try ModelShellProxy()
            .enable(.posixCore)
        let pipefailErrexitShell = try ModelShellProxy()
            .enable(.posixCore)

        let noglob = await globShell.run("set -f; printf '<%s>\\n' *; set +f; printf '<%s>\\n' *")
        let pipelineIsolation = await globShell.run("set -f | cat; printf '<%s>\\n' *")
        let pipefail = await statusShell.run(
            "false | true; printf 'plain=%s\\n' $?; set -o pipefail; false | true; printf 'pipefail=%s\\n' $?; set +o pipefail; false | true; printf 'reset=%s\\n' $?"
        )
        let pipeStatus = await statusShell.run("""
        false
        printf 'single=%s:%s\\n' "${PIPESTATUS[0]}" "$?"
        false | true | false
        printf 'pipe=%s/%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "${PIPESTATUS[2]}" "$?"
        set -o pipefail
        false | true
        printf 'pipefail=%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        ! false | true
        printf 'neg=%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        """)
        let streamingBrokenPipeStatus = await statusShell.run("""
        set -o pipefail
        yes ok | head -n 1
        printf 'pipefail=%s/%s:%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        set +o pipefail
        yes ok | head -n 1
        printf 'plain=%s/%s:%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        """)
        let nounset = await nounsetShell.run("set -u; printf '%s\\n' ${MISSING:-fallback}; echo $MISSING; echo after")
        let optionFlags = await nounsetShell.run("set -efu -o pipefail; printf '%s\\n' $-")
        let simpleErrexit = await errexitShell.run("set -e; false; echo after")
        let suppressedOr = await suppressedOrShell.run("set -e; false || true; echo after")
        let failingAndTail = await failingAndTailShell.run("set -e; true && false; echo after")
        let conditionSuppression = await conditionSuppressionShell.run("set -e; if false; then echo bad; fi; echo after")
        let pipefailErrexit = await pipefailErrexitShell.run("set -e -o pipefail; false | true; echo after")

        XCTAssertEqual(noglob.stdout, "<*>\n<a.txt>\n<b.txt>\n")
        XCTAssertEqual(noglob.stderr, "")
        XCTAssertEqual(noglob.exitCode, 0)
        XCTAssertEqual(pipelineIsolation.stdout, "<a.txt>\n<b.txt>\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(pipefail.stdout, "plain=0\npipefail=1\nreset=0\n")
        XCTAssertEqual(pipefail.stderr, "")
        XCTAssertEqual(pipefail.exitCode, 0)
        XCTAssertEqual(pipeStatus.stdout, "single=1:1\npipe=1/0/1:1\npipefail=1/0:1\nneg=1/0:0\n")
        XCTAssertEqual(pipeStatus.stderr, "")
        XCTAssertEqual(pipeStatus.exitCode, 0)
        XCTAssertEqual(streamingBrokenPipeStatus.stdout, "ok\npipefail=141/0:141\nok\nplain=141/0:0\n")
        XCTAssertEqual(streamingBrokenPipeStatus.stderr, "")
        XCTAssertEqual(streamingBrokenPipeStatus.exitCode, 0)
        XCTAssertEqual(nounset.stdout, "fallback\n")
        XCTAssertEqual(nounset.stderr, "MISSING: unbound variable\n")
        XCTAssertEqual(nounset.exitCode, 127)
        XCTAssertEqual(optionFlags.stdout, "efhuBc\n")
        XCTAssertEqual(optionFlags.stderr, "")
        XCTAssertEqual(optionFlags.exitCode, 0)
        XCTAssertEqual(simpleErrexit.stdout, "")
        XCTAssertEqual(simpleErrexit.stderr, "")
        XCTAssertEqual(simpleErrexit.exitCode, 1)
        XCTAssertEqual(suppressedOr.stdout, "after\n")
        XCTAssertEqual(suppressedOr.stderr, "")
        XCTAssertEqual(suppressedOr.exitCode, 0)
        XCTAssertEqual(failingAndTail.stdout, "")
        XCTAssertEqual(failingAndTail.stderr, "")
        XCTAssertEqual(failingAndTail.exitCode, 1)
        XCTAssertEqual(conditionSuppression.stdout, "after\n")
        XCTAssertEqual(conditionSuppression.stderr, "")
        XCTAssertEqual(conditionSuppression.exitCode, 0)
        XCTAssertEqual(pipefailErrexit.stdout, "")
        XCTAssertEqual(pipefailErrexit.stderr, "")
        XCTAssertEqual(pipefailErrexit.exitCode, 1)
        XCTAssertFalse(nounset.stderr.contains(rootURL.path))
    }

    func testShoptRunsThroughSharedShellRuntimeAndPathnameExpansion() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "a".write(
            to: rootURL.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden".write(
            to: rootURL.appendingPathComponent(".hidden"),
            atomically: true,
            encoding: .utf8
        )
        try "case".write(
            to: rootURL.appendingPathComponent("Case.TXT"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("dir/sub"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("ext"),
            withIntermediateDirectories: true
        )
        try "x".write(
            to: rootURL.appendingPathComponent("dir/x.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "y".write(
            to: rootURL.appendingPathComponent("dir/sub/y.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "one".write(
            to: rootURL.appendingPathComponent("ext/a.md"),
            atomically: true,
            encoding: .utf8
        )
        try "two".write(
            to: rootURL.appendingPathComponent("ext/b.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden".write(
            to: rootURL.appendingPathComponent("ext/.hidden"),
            atomically: true,
            encoding: .utf8
        )

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let lookup = await shell.run("command -v shopt; type -t shopt")
        let defaultGlob = await shell.run("printf '<%s>\\n' *")
        let nullGlob = await shell.run("shopt -s nullglob; set -- missing*; printf 'null:%s\\n' $#")
        let failGlob = await shell.run("shopt -u nullglob; shopt -s failglob; printf '<%s>\\n' missing*; echo after")
        let resetFailGlob = await shell.run("shopt -u failglob")
        let dotGlob = await shell.run("shopt -s dotglob; printf '<%s>\\n' *")
        let noCaseGlob = await shell.run("shopt -s nocaseglob; printf '<%s>\\n' case.*")
        let quietAndPipelineIsolation = await shell.run("shopt -s nullglob; shopt -q nullglob; printf 'q:%s\\n' $?; shopt -u nullglob | cat; shopt -q nullglob; printf 'after:%s\\n' $?")
        let printForm = await shell.run("shopt -p nullglob failglob")
        let enableExtGlob = await shell.run("shopt -s extglob")
        let extGlob = await shell.run("printf '<%s>\\n' ext/!(*.tmp)")
        let arrayExtGlob = await shell.run("values=(ext/!(*.tmp)); printf '<%s>\\n' \"${values[@]}\"")
        let globStar = await shell.run("shopt -u nocaseglob; shopt -s globstar; printf '<%s>\\n' dir/**/*.txt")
        let invalid = await shell.run("shopt not_a_shell_option")

        XCTAssertEqual(lookup.stdout, "shopt\nbuiltin\n")
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertEqual(defaultGlob.stdout, "<Case.TXT>\n<a.txt>\n<dir>\n<ext>\n")
        XCTAssertEqual(defaultGlob.stderr, "")
        XCTAssertEqual(defaultGlob.exitCode, 0)
        XCTAssertEqual(nullGlob.stdout, "null:0\n")
        XCTAssertEqual(nullGlob.stderr, "")
        XCTAssertEqual(nullGlob.exitCode, 0)
        XCTAssertEqual(failGlob.stdout, "")
        XCTAssertEqual(failGlob.stderr, "no match: missing*\n")
        XCTAssertEqual(failGlob.exitCode, 1)
        XCTAssertEqual(resetFailGlob.exitCode, 0)
        XCTAssertEqual(dotGlob.stdout, "<.hidden>\n<Case.TXT>\n<a.txt>\n<dir>\n<ext>\n")
        XCTAssertEqual(dotGlob.stderr, "")
        XCTAssertEqual(dotGlob.exitCode, 0)
        XCTAssertEqual(noCaseGlob.stdout, "<Case.TXT>\n")
        XCTAssertEqual(noCaseGlob.stderr, "")
        XCTAssertEqual(noCaseGlob.exitCode, 0)
        XCTAssertEqual(quietAndPipelineIsolation.stdout, "q:0\nafter:0\n")
        XCTAssertEqual(quietAndPipelineIsolation.stderr, "")
        XCTAssertEqual(quietAndPipelineIsolation.exitCode, 0)
        XCTAssertEqual(printForm.stdout, "shopt -s nullglob\nshopt -u failglob\n")
        XCTAssertEqual(printForm.stderr, "")
        XCTAssertEqual(printForm.exitCode, 1)
        XCTAssertEqual(enableExtGlob.stdout, "")
        XCTAssertEqual(enableExtGlob.stderr, "")
        XCTAssertEqual(enableExtGlob.exitCode, 0)
        XCTAssertEqual(extGlob.stdout, "<ext/.hidden>\n<ext/a.md>\n<ext/b.txt>\n")
        XCTAssertEqual(extGlob.stderr, "")
        XCTAssertEqual(extGlob.exitCode, 0)
        XCTAssertEqual(arrayExtGlob.stdout, "<ext/.hidden>\n<ext/a.md>\n<ext/b.txt>\n")
        XCTAssertEqual(arrayExtGlob.stderr, "")
        XCTAssertEqual(arrayExtGlob.exitCode, 0)
        XCTAssertEqual(globStar.stdout, "<dir/sub/y.txt>\n<dir/x.txt>\n")
        XCTAssertEqual(globStar.stderr, "")
        XCTAssertEqual(globStar.exitCode, 0)
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertEqual(invalid.stderr, "shopt: not_a_shell_option: invalid shell option name\n")
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertFalse(failGlob.stderr.contains(rootURL.path))
    }

    func testTrapRunsThroughSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let lookup = await shell.run("command -v trap; type -t trap")
        let normal = await shell.run("trap 'echo cleanup' EXIT; echo before")
        let afterNormal = await shell.run("trap -p EXIT")
        let explicitExit = await shell.run("trap 'echo cleanup' EXIT; echo before; exit 7; echo never")
        let trapExitOverrides = await shell.run("trap 'echo cleanup; exit 9' EXIT; exit 7")
        let errexit = await shell.run("trap 'echo cleanup' EXIT; set -e; false; echo never")
        let cleared = await shell.run("trap 'echo bye' EXIT; trap - EXIT; echo hi")
        let zeroSignal = await shell.run("trap 'echo bye' 0; echo hi")
        let listing = await shell.run("trap 'echo bye' EXIT; trap 'echo int' INT; trap -p EXIT INT; trap - INT")
        let signalList = await shell.run("trap -l")
        let invalid = await shell.run("trap 'echo nope' WAT")
        let pipelineIsolation = await shell.run("trap 'echo parent' EXIT; trap 'echo child' EXIT | cat; echo after")

        XCTAssertEqual(lookup.stdout, "trap\nbuiltin\n")
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertEqual(normal.stdout, "before\ncleanup\n")
        XCTAssertEqual(normal.stderr, "")
        XCTAssertEqual(normal.exitCode, 0)
        XCTAssertEqual(afterNormal.stdout, "")
        XCTAssertEqual(afterNormal.stderr, "")
        XCTAssertEqual(afterNormal.exitCode, 0)
        XCTAssertEqual(explicitExit.stdout, "before\ncleanup\n")
        XCTAssertEqual(explicitExit.stderr, "")
        XCTAssertEqual(explicitExit.exitCode, 7)
        XCTAssertEqual(trapExitOverrides.stdout, "cleanup\n")
        XCTAssertEqual(trapExitOverrides.stderr, "")
        XCTAssertEqual(trapExitOverrides.exitCode, 9)
        XCTAssertEqual(errexit.stdout, "cleanup\n")
        XCTAssertEqual(errexit.stderr, "")
        XCTAssertEqual(errexit.exitCode, 1)
        XCTAssertEqual(cleared.stdout, "hi\n")
        XCTAssertEqual(cleared.stderr, "")
        XCTAssertEqual(cleared.exitCode, 0)
        XCTAssertEqual(zeroSignal.stdout, "hi\nbye\n")
        XCTAssertEqual(zeroSignal.stderr, "")
        XCTAssertEqual(zeroSignal.exitCode, 0)
        XCTAssertEqual(
            listing.stdout,
            "trap -- 'echo bye' EXIT\ntrap -- 'echo int' SIGINT\nbye\n"
        )
        XCTAssertEqual(listing.stderr, "")
        XCTAssertEqual(listing.exitCode, 0)
        XCTAssertTrue(signalList.stdout.contains(" 2) SIGINT"))
        XCTAssertEqual(signalList.stderr, "")
        XCTAssertEqual(signalList.exitCode, 0)
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertEqual(invalid.stderr, "trap: WAT: invalid signal specification\n")
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertEqual(pipelineIsolation.stdout, "after\nparent\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
    }

    func testUmaskRunsThroughSharedShellRuntimeAndWorkspaceCreationModes() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let defaultOutput = await shell.run("umask; umask -p; umask -S; command -v umask; type -t umask")
        let maskedCreation = await shell.run(
            "umask 077; : > redir.txt; touch touched.txt; mkdir dir; printf 'tee\\n' | tee tee.txt >/dev/null; stat -c %a redir.txt; stat -c %a touched.txt; stat -c %a dir; stat -c %a tee.txt"
        )
        let symbolicMode = await shell.run("umask u=rw,g=r,o=; umask; : > symbolic.txt; stat -c '%a' symbolic.txt")
        let isolatedPipeline = await shell.run("umask 077; umask 000 | cat; umask")
        let invalid = await shell.run("umask 888")

        XCTAssertEqual(defaultOutput.stdout, "0022\numask 0022\nu=rwx,g=rx,o=rx\numask\nbuiltin\n")
        XCTAssertEqual(defaultOutput.stderr, "")
        XCTAssertEqual(defaultOutput.exitCode, 0)
        XCTAssertEqual(
            maskedCreation.stdout,
            "600\n600\n700\n600\n"
        )
        XCTAssertEqual(maskedCreation.stderr, "")
        XCTAssertEqual(maskedCreation.exitCode, 0)
        XCTAssertEqual(symbolicMode.stdout, "0137\n640\n")
        XCTAssertEqual(symbolicMode.stderr, "")
        XCTAssertEqual(symbolicMode.exitCode, 0)
        XCTAssertEqual(isolatedPipeline.stdout, "0077\n")
        XCTAssertEqual(isolatedPipeline.stderr, "")
        XCTAssertEqual(isolatedPipeline.exitCode, 0)
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertEqual(invalid.stderr, "umask: 888: octal number out of range\n")
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertFalse(maskedCreation.stdout.contains(rootURL.path))
        XCTAssertFalse(invalid.stderr.contains(rootURL.path))
    }
}

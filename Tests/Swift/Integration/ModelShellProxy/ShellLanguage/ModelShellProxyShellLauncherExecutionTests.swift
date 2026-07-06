import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyScriptExecutionTests {
    func testShellLaunchersRunWorkspaceScriptsAsIsolatedRuntime() async throws {
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
        printf 'script:%s/%s/%s\\n' "$0" "$1" "$2"
        cd sub
        pwd
        """.write(
            to: rootURL.appendingPathComponent("scripts/run.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "echo good\n".write(
            to: rootURL.appendingPathComponent("scripts/good.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "if true; then echo missing\n".write(
            to: rootURL.appendingPathComponent("scripts/bad.sh"),
            atomically: true,
            encoding: .utf8
        )
        try """
        trap 'echo trap:$?' EXIT
        cat <<EOF
        alpha
        EOF
        false
        echo never
        """.write(
            to: rootURL.appendingPathComponent("scripts/heretrap.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "echo ${value/a/b}\n".write(
            to: rootURL.appendingPathComponent("scripts/badsubst.sh"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let inline = await shell.run(#"sh -c 'printf "%s/%s/%s\n" "$0" "$1" "$2"' name a b"#)
        let pathInline = await shell.run(#"/bin/sh -c 'printf "%s/%s/%s\n" "$0" "$1" "$2"' name a b"#)
        let script = await shell.run("sh scripts/run.sh A B; pwd")
        let stdinScript = await shell.run("printf 'echo stdin-script\\ncat\\n' | sh")
        let isolation = await shell.run(
            #"X=outer; f(){ echo outer-f; }; sh -c 'X=child; f(){ echo child-f; }; cd sub; printf "%s " "$X"; pwd; f'; printf "%s " "$X"; pwd; f"#
        )
        let syntaxGood = await shell.run("sh -n scripts/good.sh")
        let syntaxBad = await shell.run("sh -n scripts/bad.sh")
        let errexit = await shell.run("sh -e -c 'false; echo no'")
        let nounset = await shell.run("sh -u -c 'echo $MISSING; echo no'")
        let pipefail = await shell.run("sh -o pipefail -c 'false | true'")
        let bashLaunch = await shell.run("bash --noprofile --norc -c 'echo bash:$0:$1' shell arg")
        let zshLaunch = await shell.run("zsh -c 'echo zsh:$0:$1' shell arg")
        let bashVersionRedirection = await shell.run("bash --version > bash-version.txt; cat bash-version.txt")
        let hereDocTrap = await shell.run("sh -e scripts/heretrap.sh")
        let reusableAfterHereDocTrap = await shell.run("echo after-child")
        let dashBadSubstitution = await shell.run("sh scripts/badsubst.sh")
        let lookup = await shell.run("command -v sh; type sh; command -v bash; type bash; command -v zsh; type zsh")
        let hiddenLauncher = await shell.run("PATH=/nope sh -c 'echo hidden'")
        let explicitLauncher = await shell.run("PATH=/nope /bin/sh -c 'echo explicit'")

        XCTAssertEqual(inline.stdout, "name/a/b\n")
        XCTAssertEqual(inline.stderr, "")
        XCTAssertEqual(inline.exitCode, 0)
        XCTAssertEqual(pathInline.stdout, "name/a/b\n")
        XCTAssertEqual(pathInline.stderr, "")
        XCTAssertEqual(pathInline.exitCode, 0)
        XCTAssertEqual(script.stdout, "script:scripts/run.sh/A/B\n/sub\n/\n")
        XCTAssertEqual(script.stderr, "")
        XCTAssertEqual(script.exitCode, 0)
        XCTAssertEqual(stdinScript.stdout, "stdin-script\n")
        XCTAssertEqual(stdinScript.stderr, "")
        XCTAssertEqual(stdinScript.exitCode, 0)
        XCTAssertEqual(isolation.stdout, "child /sub\nchild-f\nouter /\nouter-f\n")
        XCTAssertEqual(isolation.stderr, "")
        XCTAssertEqual(isolation.exitCode, 0)
        XCTAssertEqual(syntaxGood.stdout, "")
        XCTAssertEqual(syntaxGood.stderr, "")
        XCTAssertEqual(syntaxGood.exitCode, 0)
        XCTAssertEqual(syntaxBad.stdout, "")
        XCTAssertNotEqual(syntaxBad.exitCode, 0)
        XCTAssertFalse(syntaxBad.stderr.isEmpty)
        XCTAssertEqual(errexit.stdout, "")
        XCTAssertEqual(errexit.stderr, "")
        XCTAssertEqual(errexit.exitCode, 1)
        XCTAssertEqual(nounset.stdout, "")
        XCTAssertTrue(nounset.stderr.contains("MISSING: unbound variable\n"))
        XCTAssertEqual(nounset.exitCode, 127)
        XCTAssertEqual(pipefail.stdout, "")
        XCTAssertEqual(pipefail.stderr, "")
        XCTAssertEqual(pipefail.exitCode, 1)
        XCTAssertEqual(bashLaunch.stdout, "bash:shell:arg\n")
        XCTAssertEqual(bashLaunch.stderr, "")
        XCTAssertEqual(bashLaunch.exitCode, 0)
        XCTAssertEqual(zshLaunch.stdout, "zsh:shell:arg\n")
        XCTAssertEqual(zshLaunch.stderr, "")
        XCTAssertEqual(zshLaunch.exitCode, 0)
        XCTAssertEqual(
            bashVersionRedirection.stdout,
            "GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)\n"
        )
        XCTAssertEqual(bashVersionRedirection.stderr, "")
        XCTAssertEqual(bashVersionRedirection.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("bash-version.txt"), encoding: .utf8),
            "GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)\n"
        )
        XCTAssertEqual(hereDocTrap.stdout, "alpha\ntrap:1\n")
        XCTAssertEqual(hereDocTrap.stderr, "")
        XCTAssertEqual(hereDocTrap.exitCode, 1)
        XCTAssertEqual(reusableAfterHereDocTrap.stdout, "after-child\n")
        XCTAssertEqual(reusableAfterHereDocTrap.stderr, "")
        XCTAssertEqual(reusableAfterHereDocTrap.exitCode, 0)
        XCTAssertEqual(dashBadSubstitution.stdout, "")
        XCTAssertEqual(dashBadSubstitution.stderr, "scripts/badsubst.sh: 1: Bad substitution\n")
        XCTAssertEqual(dashBadSubstitution.exitCode, 2)
        XCTAssertEqual(
            lookup.stdout,
            "/usr/bin/sh\nsh is /usr/bin/sh\n/usr/bin/bash\nbash is /usr/bin/bash\n/usr/bin/zsh\nzsh is /usr/bin/zsh\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertEqual(hiddenLauncher.stdout, "")
        XCTAssertEqual(hiddenLauncher.stderr, "sh: command not found\n")
        XCTAssertEqual(hiddenLauncher.exitCode, 127)
        XCTAssertEqual(explicitLauncher.stdout, "explicit\n")
        XCTAssertEqual(explicitLauncher.stderr, "")
        XCTAssertEqual(explicitLauncher.exitCode, 0)
        XCTAssertFalse(script.stdout.contains(rootURL.path))
        XCTAssertFalse(syntaxBad.stderr.contains(rootURL.path))
        XCTAssertFalse(nounset.stderr.contains(rootURL.path))
        XCTAssertFalse(hereDocTrap.stdout.contains(rootURL.path))
        XCTAssertFalse(dashBadSubstitution.stderr.contains(rootURL.path))
    }

}

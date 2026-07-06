import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyShellStateTests {
    func testEvalAndShiftRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("d"),
            withIntermediateDirectories: true
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let evalStatusAndState = await shell.run("false; eval 'printf \"status:%s\\n\" \"$?\"; FOO=bar'; echo \"$FOO\"")
        let evalDirectory = await shell.run("eval 'cd /d; INNER=ok'; pwd; echo \"$INNER\"")
        let evalRedirection = await shell.run("eval 'echo one; echo two' > eval.txt; cat eval.txt")
        let evalReturn = await shell.run("f() { echo before; eval 'return 6'; echo after; }; f; echo status:$?")
        let evalExit = await shell.run("eval 'echo before; exit 5; echo after'; echo never")
        let shiftOnce = await shell.run("f() { shift; printf '<%s>/<%s>/%s\\n' \"$1\" \"$2\" \"$#\"; }; f a b c")
        let shiftTwice = await shell.run("f() { shift 2; printf '<%s>/%s\\n' \"$1\" \"$#\"; }; f a b c")
        let shiftInPipelineIsIsolated = await shell.run("f() { shift | cat; printf '<%s>/%s\\n' \"$1\" \"$#\"; }; f a b")
        let shiftOutOfRange = await shell.run("f() { shift 9; echo after; }; f a; echo done")
        let lookup = await shell.run("command -v eval; type eval; command -v shift; type shift")

        XCTAssertEqual(evalStatusAndState.stdout, "status:1\nbar\n")
        XCTAssertEqual(evalStatusAndState.stderr, "")
        XCTAssertEqual(evalStatusAndState.exitCode, 0)
        XCTAssertEqual(evalDirectory.stdout, "/d\nok\n")
        XCTAssertEqual(evalDirectory.stderr, "")
        XCTAssertEqual(evalDirectory.exitCode, 0)
        XCTAssertEqual(evalRedirection.stdout, "one\ntwo\n")
        XCTAssertEqual(evalRedirection.stderr, "")
        XCTAssertEqual(evalRedirection.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("d/eval.txt"), encoding: .utf8),
            "one\ntwo\n"
        )
        XCTAssertEqual(evalReturn.stdout, "before\nstatus:6\n")
        XCTAssertEqual(evalReturn.stderr, "")
        XCTAssertEqual(evalReturn.exitCode, 0)
        XCTAssertEqual(evalExit.stdout, "before\n")
        XCTAssertEqual(evalExit.stderr, "")
        XCTAssertEqual(evalExit.exitCode, 5)
        XCTAssertEqual(shiftOnce.stdout, "<b>/<c>/2\n")
        XCTAssertEqual(shiftOnce.stderr, "")
        XCTAssertEqual(shiftOnce.exitCode, 0)
        XCTAssertEqual(shiftTwice.stdout, "<c>/1\n")
        XCTAssertEqual(shiftTwice.stderr, "")
        XCTAssertEqual(shiftTwice.exitCode, 0)
        XCTAssertEqual(shiftInPipelineIsIsolated.stdout, "<a>/2\n")
        XCTAssertEqual(shiftInPipelineIsIsolated.stderr, "")
        XCTAssertEqual(shiftInPipelineIsIsolated.exitCode, 0)
        XCTAssertEqual(shiftOutOfRange.stdout, "after\ndone\n")
        XCTAssertEqual(shiftOutOfRange.stderr, "shift: shift count out of range\n")
        XCTAssertEqual(shiftOutOfRange.exitCode, 0)
        XCTAssertEqual(
            lookup.stdout,
            "eval\neval is a shell builtin\nshift\nshift is a shell builtin\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertFalse(evalRedirection.stdout.contains(rootURL.path))
    }

    func testSetUnsetLocalAndReadRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "tail".write(
            to: rootURL.appendingPathComponent("no-newline.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let setParameters = await shell.run("set -- a 'b b' c; printf '%s/%s/%s\\n' \"$1\" \"$2\" \"$#\"; set --; printf 'empty:%s\\n' \"$#\"")
        let unsetVariable = await shell.run("FOO=bar; unset FOO; printf '<%s>\\n' \"$FOO\"")
        let unsetFunction = await shell.run("gone() { echo bad; }; unset -f gone; gone; echo after")
        let localRestores = await shell.run("VALUE=outer; f() { local VALUE=inner EMPTY; printf '%s/%s\\n' \"$VALUE\" \"$EMPTY\"; }; f; printf '%s/%s\\n' \"$VALUE\" \"$EMPTY\"")
        let localNested = await shell.run("NAME=global; outer() { local NAME=outer; inner() { local NAME=inner; echo $NAME; }; inner; echo $NAME; }; outer; echo $NAME")
        let localOutsideFunction = await shell.run("local X=1; echo after")
        let localArrayState = await shell.run("""
        arr=(outer)
        declare -A map
        map[k]=outer
        f() {
          local -a arr=(inner "two words")
          local -A map=( [k]=inner [new]=value )
          printf 'in:%s/%s/%s/%s\\n' "${arr[0]}" "${arr[1]}" "${map[k]}" "${map[new]}"
        }
        f
        printf 'out:%s/%s/%s\\n' "${arr[0]}" "${map[k]}" "${map[new]:-missing}"
        """)
        let localNamerefState = await shell.run("""
        target=outer
        other=before
        declare -n link=target
        f() {
          local -n link=other
          link=changed
          printf 'in:%s/%s/%s\\n' "$link" "$target" "$other"
        }
        f
        printf 'out:%s/%s/%s\\n' "$link" "$target" "$other"
        """)
        let readFields = await shell.run("read -r FIRST REST <<< 'one two three'; printf '<%s>/<%s>\\n' \"$FIRST\" \"$REST\"")
        let readDefaultReply = await shell.run("read <<< 'reply value'; printf '<%s>\\n' \"$REPLY\"")
        let readCharacterCount = await shell.run("read -n 3 PART <<< abcdef; printf '<%s>:%s\\n' \"$PART\" \"$?\"")
        let readDelimiter = await shell.run("read -d : PART <<< 'x:y:z'; printf '<%s>:%s\\n' \"$PART\" \"$?\"")
        let readEOFStatusStillAssigns = await shell.run("read -r PART < no-newline.txt; printf '<%s>:%s\\n' \"$PART\" \"$?\"")
        let readPipelineIsolation = await shell.run("printf 'pipe\\n' | read PIPEVALUE; printf '<%s>\\n' \"$PIPEVALUE\"")
        let lookup = await shell.run("command -v set; type set; command -v unset; type unset; command -v local; type local; command -v read; type read")

        XCTAssertEqual(setParameters.stdout, "a/b b/3\nempty:0\n")
        XCTAssertEqual(setParameters.stderr, "")
        XCTAssertEqual(setParameters.exitCode, 0)
        XCTAssertEqual(unsetVariable.stdout, "<>\n")
        XCTAssertEqual(unsetVariable.stderr, "")
        XCTAssertEqual(unsetVariable.exitCode, 0)
        XCTAssertEqual(unsetFunction.stdout, "after\n")
        XCTAssertEqual(unsetFunction.stderr, "gone: command not found\n")
        XCTAssertEqual(unsetFunction.exitCode, 0)
        XCTAssertEqual(localRestores.stdout, "inner/\nouter/\n")
        XCTAssertEqual(localRestores.stderr, "")
        XCTAssertEqual(localRestores.exitCode, 0)
        XCTAssertEqual(localNested.stdout, "inner\nouter\nglobal\n")
        XCTAssertEqual(localNested.stderr, "")
        XCTAssertEqual(localNested.exitCode, 0)
        XCTAssertEqual(localOutsideFunction.stdout, "after\n")
        XCTAssertEqual(localOutsideFunction.stderr, "local: can only be used in a function\n")
        XCTAssertEqual(localOutsideFunction.exitCode, 0)
        XCTAssertEqual(localArrayState.stdout, "in:inner/two words/inner/value\nout:outer/outer/missing\n")
        XCTAssertEqual(localArrayState.stderr, "")
        XCTAssertEqual(localArrayState.exitCode, 0)
        XCTAssertEqual(localNamerefState.stdout, "in:changed/outer/changed\nout:outer/outer/changed\n")
        XCTAssertEqual(localNamerefState.stderr, "")
        XCTAssertEqual(localNamerefState.exitCode, 0)
        XCTAssertEqual(readFields.stdout, "<one>/<two three>\n")
        XCTAssertEqual(readFields.stderr, "")
        XCTAssertEqual(readFields.exitCode, 0)
        XCTAssertEqual(readDefaultReply.stdout, "<reply value>\n")
        XCTAssertEqual(readDefaultReply.stderr, "")
        XCTAssertEqual(readDefaultReply.exitCode, 0)
        XCTAssertEqual(readCharacterCount.stdout, "<abc>:0\n")
        XCTAssertEqual(readCharacterCount.stderr, "")
        XCTAssertEqual(readCharacterCount.exitCode, 0)
        XCTAssertEqual(readDelimiter.stdout, "<x>:0\n")
        XCTAssertEqual(readDelimiter.stderr, "")
        XCTAssertEqual(readDelimiter.exitCode, 0)
        XCTAssertEqual(readEOFStatusStillAssigns.stdout, "<tail>:1\n")
        XCTAssertEqual(readEOFStatusStillAssigns.stderr, "")
        XCTAssertEqual(readEOFStatusStillAssigns.exitCode, 0)
        XCTAssertEqual(readPipelineIsolation.stdout, "<>\n")
        XCTAssertEqual(readPipelineIsolation.stderr, "")
        XCTAssertEqual(readPipelineIsolation.exitCode, 0)
        XCTAssertEqual(
            lookup.stdout,
            "set\nset is a shell builtin\nunset\nunset is a shell builtin\nlocal\nlocal is a shell builtin\nread\nread is a shell builtin\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertFalse(readEOFStatusStillAssigns.stdout.contains(rootURL.path))
    }

    func testAliasAndUnaliasRunThroughSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let lifecycle = await shell.run("""
        alias greet='printf "hi there"'
        alias short=echo
        alias greet
        alias missing
        alias
        unalias short
        alias short
        unalias -a
        alias
        printf 'status:%s\\n' "$?"
        """)
        let pipelineIsolation = await shell.run("alias base=echo; alias pipe=cat | cat; alias")
        let lookup = await shell.run("command -v alias; type alias; command -v unalias; type unalias")

        XCTAssertEqual(
            lifecycle.stdout,
            """
            alias greet='printf "hi there"'
            alias greet='printf "hi there"'
            alias short='echo'
            status:0
            """
            + "\n"
        )
        XCTAssertEqual(
            lifecycle.stderr,
            """
            alias: missing: not found
            alias: short: not found
            """
            + "\n"
        )
        XCTAssertEqual(lifecycle.exitCode, 0)
        XCTAssertEqual(pipelineIsolation.stdout, "alias base='echo'\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(
            lookup.stdout,
            "alias\nalias is a shell builtin\nunalias\nunalias is a shell builtin\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
    }
}

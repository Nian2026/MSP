import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyScriptExecutionTests {
    func testSemicolonSeparatedCommandsRunSequentially() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "one\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("pwd; echo marker; cat docs/a.txt; false")

        XCTAssertEqual(result.stdout, "/\nmarker\none\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
    }

    func testLogicalListsShortCircuitThroughSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let andSkipped = await shell.run("false && echo no; echo after")
        let andRuns = await shell.run("true && echo yes")
        let orRuns = await shell.run("false || echo fallback")
        let orSkipped = await shell.run("true || echo no; echo after")
        let combined = await shell.run("false && echo no || echo yes")
        let negatedAndRuns = await shell.run("! false && echo yes")
        let negatedOrRuns = await shell.run("! true || echo fallback")
        let negatedPipelineRuns = await shell.run("! printf 'alpha\\n' | grep beta && echo missing")

        XCTAssertEqual(andSkipped.stdout, "after\n")
        XCTAssertEqual(andSkipped.stderr, "")
        XCTAssertEqual(andSkipped.exitCode, 0)
        XCTAssertEqual(andRuns.stdout, "yes\n")
        XCTAssertEqual(andRuns.stderr, "")
        XCTAssertEqual(andRuns.exitCode, 0)
        XCTAssertEqual(orRuns.stdout, "fallback\n")
        XCTAssertEqual(orRuns.stderr, "")
        XCTAssertEqual(orRuns.exitCode, 0)
        XCTAssertEqual(orSkipped.stdout, "after\n")
        XCTAssertEqual(orSkipped.stderr, "")
        XCTAssertEqual(orSkipped.exitCode, 0)
        XCTAssertEqual(combined.stdout, "yes\n")
        XCTAssertEqual(combined.stderr, "")
        XCTAssertEqual(combined.exitCode, 0)
        XCTAssertEqual(negatedAndRuns.stdout, "yes\n")
        XCTAssertEqual(negatedAndRuns.stderr, "")
        XCTAssertEqual(negatedAndRuns.exitCode, 0)
        XCTAssertEqual(negatedOrRuns.stdout, "fallback\n")
        XCTAssertEqual(negatedOrRuns.stderr, "")
        XCTAssertEqual(negatedOrRuns.exitCode, 0)
        XCTAssertEqual(negatedPipelineRuns.stdout, "missing\n")
        XCTAssertEqual(negatedPipelineRuns.stderr, "")
        XCTAssertEqual(negatedPipelineRuns.exitCode, 0)
    }

    func testGroupAndSubshellCompoundCommandsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let groupEnvironment = await shell.run("{ FOO=bar; }; printf '%s\\n' $FOO")
        let groupDirectory = await shell.run("{ mkdir -p d; cd d; }; pwd")
        let subshellIsolation = await shell.run("( FOO=sub; mkdir -p inner; cd inner ); printf '<%s> ' \"$FOO\"; pwd")
        let subshellFileSystemMutation = await shell.run("test -d inner && echo exists")
        let redirectedGroup = await shell.run("{ echo one; echo two; } > out.txt; cat out.txt")
        let redirectedGroupBeforeCWDChange = await shell.run("mkdir -p /redir; cd /redir; { mkdir -p child; cd child; echo hi; } > out.txt; pwd; cat /redir/out.txt; test -f /redir/child/out.txt && echo bad")
        let pipelineIsolation = await shell.run("FOO=old; { FOO=new; echo x; } | cat; printf '%s\\n' $FOO")
        let logicalList = await shell.run("{ false; } || echo fallback")

        XCTAssertEqual(groupEnvironment.stdout, "bar\n")
        XCTAssertEqual(groupEnvironment.stderr, "")
        XCTAssertEqual(groupEnvironment.exitCode, 0)
        XCTAssertEqual(groupDirectory.stdout, "/d\n")
        XCTAssertEqual(groupDirectory.stderr, "")
        XCTAssertEqual(groupDirectory.exitCode, 0)
        XCTAssertEqual(subshellIsolation.stdout, "<bar> /d\n")
        XCTAssertEqual(subshellIsolation.stderr, "")
        XCTAssertEqual(subshellIsolation.exitCode, 0)
        XCTAssertEqual(subshellFileSystemMutation.stdout, "exists\n")
        XCTAssertEqual(subshellFileSystemMutation.stderr, "")
        XCTAssertEqual(subshellFileSystemMutation.exitCode, 0)
        XCTAssertEqual(redirectedGroup.stdout, "one\ntwo\n")
        XCTAssertEqual(redirectedGroup.stderr, "")
        XCTAssertEqual(redirectedGroup.exitCode, 0)
        XCTAssertEqual(redirectedGroupBeforeCWDChange.stdout, "/redir/child\nhi\n")
        XCTAssertEqual(redirectedGroupBeforeCWDChange.stderr, "")
        XCTAssertEqual(redirectedGroupBeforeCWDChange.exitCode, 1)
        XCTAssertEqual(pipelineIsolation.stdout, "x\nold\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(logicalList.stdout, "fallback\n")
        XCTAssertEqual(logicalList.stderr, "")
        XCTAssertEqual(logicalList.exitCode, 0)
        XCTAssertFalse(redirectedGroup.stdout.contains(rootURL.path))
    }

    func testStructuredCompoundCommandsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "a\nb\n".write(
            to: rootURL.appendingPathComponent("docs/input.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let ifBranch = await shell.run("if test -f docs/input.txt; then echo yes; elif true; then echo no; else echo maybe; fi")
        let ifState = await shell.run("if true; then mkdir -p ctl; cd ctl; fi; pwd")
        let ifRedirection = await shell.run("if true; then echo redirected; fi > if.txt; cat if.txt")
        let whileLoop = await shell.run("COUNT=0; while (( COUNT < 3 )); do printf '%s ' $COUNT; (( COUNT++ )); done; echo done")
        let untilLoop = await shell.run("COUNT=0; until (( COUNT >= 2 )); do echo u$COUNT; (( COUNT++ )); done")
        let forEach = await shell.run("for item in alpha beta; do echo $item; done; printf '<%s>\\n' \"$item\"")
        let cStyleFor = await shell.run("for (( i=0; i < 3; i++ )); do printf '%s ' $i; done; echo end")
        let caseOf = await shell.run("VALUE=beta; case $VALUE in alpha) echo A ;; b*) echo B ;; *) echo Z ;; esac")
        let caseContinueMatching = await shell.run("case x in x) echo first ;;& x) echo second ;; esac")
        let whileRead = await shell.run("cat /docs/input.txt | while read item; do echo \"[$item]\"; done; printf '<%s>\\n' \"$item\"")

        XCTAssertEqual(ifBranch.stdout, "yes\n")
        XCTAssertEqual(ifBranch.stderr, "")
        XCTAssertEqual(ifBranch.exitCode, 0)
        XCTAssertEqual(ifState.stdout, "/ctl\n")
        XCTAssertEqual(ifState.stderr, "")
        XCTAssertEqual(ifState.exitCode, 0)
        XCTAssertEqual(ifRedirection.stdout, "redirected\n")
        XCTAssertEqual(ifRedirection.stderr, "")
        XCTAssertEqual(ifRedirection.exitCode, 0)
        XCTAssertEqual(whileLoop.stdout, "0 1 2 done\n")
        XCTAssertEqual(whileLoop.stderr, "")
        XCTAssertEqual(whileLoop.exitCode, 0)
        XCTAssertEqual(untilLoop.stdout, "u0\nu1\n")
        XCTAssertEqual(untilLoop.stderr, "")
        XCTAssertEqual(untilLoop.exitCode, 0)
        XCTAssertEqual(forEach.stdout, "alpha\nbeta\n<beta>\n")
        XCTAssertEqual(forEach.stderr, "")
        XCTAssertEqual(forEach.exitCode, 0)
        XCTAssertEqual(cStyleFor.stdout, "0 1 2 end\n")
        XCTAssertEqual(cStyleFor.stderr, "")
        XCTAssertEqual(cStyleFor.exitCode, 0)
        XCTAssertEqual(caseOf.stdout, "B\n")
        XCTAssertEqual(caseOf.stderr, "")
        XCTAssertEqual(caseOf.exitCode, 0)
        XCTAssertEqual(caseContinueMatching.stdout, "first\nsecond\n")
        XCTAssertEqual(caseContinueMatching.stderr, "")
        XCTAssertEqual(caseContinueMatching.exitCode, 0)
        XCTAssertEqual(whileRead.stdout, "[a]\n[b]\n<beta>\n")
        XCTAssertEqual(whileRead.stderr, "")
        XCTAssertEqual(whileRead.exitCode, 0)
        XCTAssertFalse(ifRedirection.stdout.contains(rootURL.path))
        XCTAssertFalse(whileRead.stdout.contains(rootURL.path))
    }

    func testNestedCompoundBodiesExecuteFromParsedStructure() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let whileReadNestedIf = await shell.run("""
        mkdir -p source target
        touch source/a source/b
        printf 'source/a\\nsource/missing\\nsource/b\\n' > input.txt
        moved=0; skipped=0; failed=0
        while IFS= read -r p; do
          b=${p##*/}
          if [ -e "source/$b" ]; then
            if mv "source/$b" target/ 2>/dev/null; then
              moved=$((moved+1))
            else
              failed=$((failed+1))
            fi
          else
            skipped=$((skipped+1))
          fi
        done < input.txt
        printf 'moved:%s skipped:%s failed:%s\\n' "$moved" "$skipped" "$failed"
        test -f target/a && test -f target/b && echo moved-files
        """)
        let functionNestedIf = await shell.run("""
        choose() {
          if true; then
            if true; then echo function-inner; else echo function-inner-else; fi
          else
            echo function-outer-else
          fi
        }
        choose
        """)
        let forAndCaseNestedIf = await shell.run("""
        for item in a b; do
          if [ "$item" = b ]; then
            if true; then echo for-$item; fi
          fi
        done
        case beta in
          b*) if true; then if true; then echo case-beta; fi; fi ;;
          *) echo case-other ;;
        esac
        """)

        XCTAssertEqual(whileReadNestedIf.stdout, "moved:2 skipped:1 failed:0\nmoved-files\n")
        XCTAssertEqual(whileReadNestedIf.stderr, "")
        XCTAssertEqual(whileReadNestedIf.exitCode, 0)
        XCTAssertEqual(functionNestedIf.stdout, "function-inner\n")
        XCTAssertEqual(functionNestedIf.stderr, "")
        XCTAssertEqual(functionNestedIf.exitCode, 0)
        XCTAssertEqual(forAndCaseNestedIf.stdout, "for-b\ncase-beta\n")
        XCTAssertEqual(forAndCaseNestedIf.stderr, "")
        XCTAssertEqual(forAndCaseNestedIf.exitCode, 0)
    }

    func testLoopControlAndExitRunThroughSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let breakLoop = await shell.run("for item in a b c; do echo $item; break; echo never; done; echo after")
        let continueLoop = await shell.run("for item in a b; do echo before-$item; continue; echo never; done; echo after")
        let nestedBreak = await shell.run("for outer in 1 2; do for inner in a b; do echo $outer$inner; break 2; echo never; done; echo never-outer; done; echo done")
        let nestedContinue = await shell.run("for outer in 1 2; do for inner in a b; do echo $outer$inner; continue 2; echo never; done; echo never-outer; done; echo done")
        let cStyleContinueRunsUpdate = await shell.run("for (( i=0; i < 3; i++ )); do echo $i; continue; echo never; done; echo done")
        let caseBodyContinuesLoop = await shell.run("for item in a b; do case $item in a) continue ;; esac; echo $item; done")
        let breakOutsideLoop = await shell.run("break; echo after")
        let continueOutsideLoop = await shell.run("continue; echo after")
        let exitStopsCurrentRun = await shell.run("echo before; exit 7; echo after")
        let exitWithoutArgumentUsesLastStatus = await shell.run("false; exit")
        let exitInCommandSubstitutionIsIsolated = await shell.run(#"printf '<%s>\n' "$(echo sub; exit 5)"; echo after"#)
        let exited = await shell.run("exit 4")
        let reusableAfterExit = await shell.run("echo alive")

        XCTAssertEqual(breakLoop.stdout, "a\nafter\n")
        XCTAssertEqual(breakLoop.stderr, "")
        XCTAssertEqual(breakLoop.exitCode, 0)
        XCTAssertEqual(continueLoop.stdout, "before-a\nbefore-b\nafter\n")
        XCTAssertEqual(continueLoop.stderr, "")
        XCTAssertEqual(continueLoop.exitCode, 0)
        XCTAssertEqual(nestedBreak.stdout, "1a\ndone\n")
        XCTAssertEqual(nestedBreak.stderr, "")
        XCTAssertEqual(nestedBreak.exitCode, 0)
        XCTAssertEqual(nestedContinue.stdout, "1a\n2a\ndone\n")
        XCTAssertEqual(nestedContinue.stderr, "")
        XCTAssertEqual(nestedContinue.exitCode, 0)
        XCTAssertEqual(cStyleContinueRunsUpdate.stdout, "0\n1\n2\ndone\n")
        XCTAssertEqual(cStyleContinueRunsUpdate.stderr, "")
        XCTAssertEqual(cStyleContinueRunsUpdate.exitCode, 0)
        XCTAssertEqual(caseBodyContinuesLoop.stdout, "b\n")
        XCTAssertEqual(caseBodyContinuesLoop.stderr, "")
        XCTAssertEqual(caseBodyContinuesLoop.exitCode, 0)
        XCTAssertEqual(breakOutsideLoop.stdout, "after\n")
        XCTAssertEqual(breakOutsideLoop.stderr, "break: only meaningful in a loop\n")
        XCTAssertEqual(breakOutsideLoop.exitCode, 0)
        XCTAssertEqual(continueOutsideLoop.stdout, "after\n")
        XCTAssertEqual(continueOutsideLoop.stderr, "continue: only meaningful in a loop\n")
        XCTAssertEqual(continueOutsideLoop.exitCode, 0)
        XCTAssertEqual(exitStopsCurrentRun.stdout, "before\n")
        XCTAssertEqual(exitStopsCurrentRun.stderr, "")
        XCTAssertEqual(exitStopsCurrentRun.exitCode, 7)
        XCTAssertEqual(exitWithoutArgumentUsesLastStatus.stdout, "")
        XCTAssertEqual(exitWithoutArgumentUsesLastStatus.stderr, "")
        XCTAssertEqual(exitWithoutArgumentUsesLastStatus.exitCode, 1)
        XCTAssertEqual(exitInCommandSubstitutionIsIsolated.stdout, "<sub>\nafter\n")
        XCTAssertEqual(exitInCommandSubstitutionIsIsolated.stderr, "")
        XCTAssertEqual(exitInCommandSubstitutionIsIsolated.exitCode, 0)
        XCTAssertEqual(exited.stdout, "")
        XCTAssertEqual(exited.stderr, "")
        XCTAssertEqual(exited.exitCode, 4)
        XCTAssertEqual(reusableAfterExit.stdout, "alive\n")
        XCTAssertEqual(reusableAfterExit.stderr, "")
        XCTAssertEqual(reusableAfterExit.exitCode, 0)
    }

}

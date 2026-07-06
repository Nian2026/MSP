import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyExpansionTests: ModelShellProxyIntegrationTestCase {
    func testExpansionUsesCurrentShellStateAndWorkspaceFS() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "beta\n".write(
            to: rootURL.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let parameterAndSplitting = await shell.run("NAME='two words'; printf '<%s>\\n' \"$NAME\" $NAME")
        let ifsSplitting = await shell.run("oldIFS=$IFS; IFS=:; words='left::right'; set -- $words; printf 'IFS:%s|%s|%s|%s\\n' \"$#\" \"$1\" \"$2\" \"$3\"; IFS=$oldIFS")
        let globSeesCreatedFile = await shell.run("touch later.txt; printf '<%s>\\n' *.txt")
        let ifsRead = await shell.run("printf 'a:1\\nbeta:two words\\n' > pairs.txt; while IFS=: read -r key val; do printf 'ROW:%s=%s\\n' \"$key\" \"$val\"; done < pairs.txt")
        let redirectionTargetExpands = await shell.run("TARGET=expanded.txt; printf hi > \"$TARGET\"; cat expanded.txt")
        let statusExpandsAtExecutionTime = await shell.run("false; printf 'status=%s\\n' $?")
        let arithmeticUsesCurrentEnvironment = await shell.run("COUNT=5; printf 'value=%s cmp=%s\\n' $((COUNT + 2 * 3)) $((COUNT > 3 && 2 < 4))")
        let arithmeticRedirectionTarget = await shell.run("N=2; printf ok > item-$((N + 1)).txt; cat item-3.txt")
        let arithmeticDivideByZero = await shell.run("printf '%s\\n' $((1 / 0))")

        XCTAssertEqual(parameterAndSplitting.stdout, "<two words>\n<two>\n<words>\n")
        XCTAssertEqual(parameterAndSplitting.stderr, "")
        XCTAssertEqual(parameterAndSplitting.exitCode, 0)
        XCTAssertEqual(ifsSplitting.stdout, "IFS:3|left||right\n")
        XCTAssertEqual(ifsSplitting.stderr, "")
        XCTAssertEqual(ifsSplitting.exitCode, 0)
        XCTAssertEqual(ifsRead.stdout, "ROW:a=1\nROW:beta=two words\n")
        XCTAssertEqual(ifsRead.stderr, "")
        XCTAssertEqual(ifsRead.exitCode, 0)
        XCTAssertEqual(globSeesCreatedFile.stdout, "<a.txt>\n<later.txt>\n")
        XCTAssertEqual(globSeesCreatedFile.stderr, "")
        XCTAssertEqual(globSeesCreatedFile.exitCode, 0)
        XCTAssertEqual(redirectionTargetExpands.stdout, "hi")
        XCTAssertEqual(redirectionTargetExpands.stderr, "")
        XCTAssertEqual(redirectionTargetExpands.exitCode, 0)
        XCTAssertEqual(statusExpandsAtExecutionTime.stdout, "status=1\n")
        XCTAssertEqual(statusExpandsAtExecutionTime.stderr, "")
        XCTAssertEqual(statusExpandsAtExecutionTime.exitCode, 0)
        XCTAssertEqual(arithmeticUsesCurrentEnvironment.stdout, "value=11 cmp=1\n")
        XCTAssertEqual(arithmeticUsesCurrentEnvironment.stderr, "")
        XCTAssertEqual(arithmeticUsesCurrentEnvironment.exitCode, 0)
        XCTAssertEqual(arithmeticRedirectionTarget.stdout, "ok")
        XCTAssertEqual(arithmeticRedirectionTarget.stderr, "")
        XCTAssertEqual(arithmeticRedirectionTarget.exitCode, 0)
        XCTAssertEqual(arithmeticDivideByZero.stdout, "")
        XCTAssertEqual(arithmeticDivideByZero.stderr, "arithmetic expansion: division by zero\n")
        XCTAssertEqual(arithmeticDivideByZero.exitCode, 1)
        XCTAssertFalse(globSeesCreatedFile.stdout.contains(rootURL.path))
        XCTAssertFalse(redirectionTargetExpands.stdout.contains(rootURL.path))
        XCTAssertFalse(arithmeticRedirectionTarget.stdout.contains(rootURL.path))
    }

    func testCommandSubstitutionRunsThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "from-file\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let quoted = await shell.run(#"printf 'x=%s\n' "$(printf 'a\n')""#)
        let unquotedSplitting = await shell.run(#"printf '<%s>\n' $(printf 'a b\n')"#)
        let quotedPreservesField = await shell.run(#"printf '<%s>\n' "$(printf 'a b\n')""#)
        let backticks = await shell.run(#"printf '%s\n' `printf legacy`"#)
        let stripsTrailingNewlines = await shell.run(#"printf '<%s>\n' "$(printf 'one\n\n')""#)
        let workspaceFile = await shell.run(#"printf '%s\n' "$(cat docs/a.txt)""#)
        let substitutionStderr = await shell.run(#"printf 'ok:%s\n' "$(missing-sub)""#)
        let inheritedStatus = await shell.run(#"false; printf 'status=%s\n' "$(printf '%s' $?)""#)
        let isolatedState = await shell.run(#"mkdir -p sub; printf '%s|%s\n' "$(cd sub; pwd)" "$PWD""#)
        let quotedPipeline = await shell.run(#"item=gamma; printf 'OTHER:%s\n' "$(printf '%s' "$item" | sed 's/a/A/g')""#)
        let loopQuotedPipeline = await shell.run(#"""
        printf 'alpha\nbeta\ngamma\n' > docs/items.txt
        while IFS= read -r item; do
          case "$item" in
            gamma) printf 'OTHER:%s\n' "$(printf '%s' "$item" | sed 's/a/A/g')" ;;
          esac
        done < docs/items.txt
        """#)
        let closedStdin = await shell.run(#"exec <&-; printf '<%s>\n' "$(cat)""#)

        XCTAssertEqual(quoted.stdout, "x=a\n")
        XCTAssertEqual(quoted.stderr, "")
        XCTAssertEqual(quoted.exitCode, 0)
        XCTAssertEqual(unquotedSplitting.stdout, "<a>\n<b>\n")
        XCTAssertEqual(unquotedSplitting.stderr, "")
        XCTAssertEqual(unquotedSplitting.exitCode, 0)
        XCTAssertEqual(quotedPreservesField.stdout, "<a b>\n")
        XCTAssertEqual(quotedPreservesField.stderr, "")
        XCTAssertEqual(quotedPreservesField.exitCode, 0)
        XCTAssertEqual(backticks.stdout, "legacy\n")
        XCTAssertEqual(backticks.stderr, "")
        XCTAssertEqual(backticks.exitCode, 0)
        XCTAssertEqual(stripsTrailingNewlines.stdout, "<one>\n")
        XCTAssertEqual(stripsTrailingNewlines.stderr, "")
        XCTAssertEqual(stripsTrailingNewlines.exitCode, 0)
        XCTAssertEqual(workspaceFile.stdout, "from-file\n")
        XCTAssertEqual(workspaceFile.stderr, "")
        XCTAssertEqual(workspaceFile.exitCode, 0)
        XCTAssertEqual(substitutionStderr.stdout, "ok:\n")
        XCTAssertEqual(substitutionStderr.stderr, "missing-sub: command not found\n")
        XCTAssertEqual(substitutionStderr.exitCode, 0)
        XCTAssertEqual(inheritedStatus.stdout, "status=1\n")
        XCTAssertEqual(inheritedStatus.stderr, "")
        XCTAssertEqual(inheritedStatus.exitCode, 0)
        XCTAssertEqual(isolatedState.stdout, "/sub|/\n")
        XCTAssertEqual(isolatedState.stderr, "")
        XCTAssertEqual(isolatedState.exitCode, 0)
        XCTAssertEqual(quotedPipeline.stdout, "OTHER:gAmmA\n")
        XCTAssertEqual(quotedPipeline.stderr, "")
        XCTAssertEqual(quotedPipeline.exitCode, 0)
        XCTAssertEqual(loopQuotedPipeline.stdout, "OTHER:gAmmA\n")
        XCTAssertEqual(loopQuotedPipeline.stderr, "")
        XCTAssertEqual(loopQuotedPipeline.exitCode, 0)
        XCTAssertEqual(closedStdin.stdout, "<>\n")
        XCTAssertEqual(closedStdin.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(closedStdin.exitCode, 0)
        XCTAssertFalse(workspaceFile.stdout.contains(rootURL.path))
        XCTAssertFalse(substitutionStderr.stderr.contains(rootURL.path))
        XCTAssertFalse(isolatedState.stdout.contains(rootURL.path))
    }

    func testProcessSubstitutionRunsThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let inputFileArgument = await shell.run("cat <(printf 'alpha\\nbeta\\n')")
        let diffInputs = await shell.run("diff <(printf 'same\\n') <(printf 'same\\n'); echo status:$?")
        let stdinRedirection = await shell.run("cat < <(printf 'stdin\\n')")
        let outputRedirection = await shell.run("printf 'routed\\n' > >(cat > out.txt); cat out.txt")
        let visibleOutput = await shell.run("printf visible > >(cat)")
        let persistentFD = await shell.run("exec 3> >(cat > persistent.txt); printf persistent >&3; exec 3>&-; cat persistent.txt")
        let substitutionStderr = await shell.run("cat <(missing-process-sub)")
        let tempCleanup = await shell.run("ls / | grep '^tmp$'")
        let closedStdin = await shell.run("exec <&-; cat < <(cat)")

        XCTAssertEqual(inputFileArgument.stdout, "alpha\nbeta\n")
        XCTAssertEqual(inputFileArgument.stderr, "")
        XCTAssertEqual(inputFileArgument.exitCode, 0)
        XCTAssertEqual(diffInputs.stdout, "status:0\n")
        XCTAssertEqual(diffInputs.stderr, "")
        XCTAssertEqual(diffInputs.exitCode, 0)
        XCTAssertEqual(stdinRedirection.stdout, "stdin\n")
        XCTAssertEqual(stdinRedirection.stderr, "")
        XCTAssertEqual(stdinRedirection.exitCode, 0)
        XCTAssertEqual(outputRedirection.stdout, "routed\n")
        XCTAssertEqual(outputRedirection.stderr, "")
        XCTAssertEqual(outputRedirection.exitCode, 0)
        XCTAssertEqual(visibleOutput.stdout, "visible")
        XCTAssertEqual(visibleOutput.stderr, "")
        XCTAssertEqual(visibleOutput.exitCode, 0)
        XCTAssertEqual(persistentFD.stdout, "persistent")
        XCTAssertEqual(persistentFD.stderr, "")
        XCTAssertEqual(persistentFD.exitCode, 0)
        XCTAssertEqual(substitutionStderr.stdout, "")
        XCTAssertEqual(substitutionStderr.stderr, "missing-process-sub: command not found\n")
        XCTAssertEqual(substitutionStderr.exitCode, 0)
        XCTAssertEqual(tempCleanup.stdout, "")
        XCTAssertEqual(tempCleanup.stderr, "")
        XCTAssertEqual(tempCleanup.exitCode, 1)
        XCTAssertEqual(closedStdin.stdout, "")
        XCTAssertEqual(closedStdin.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(closedStdin.exitCode, 0)
        XCTAssertFalse(inputFileArgument.stdout.contains(rootURL.path))
        XCTAssertFalse(substitutionStderr.stderr.contains(rootURL.path))
    }

    func testProcessSubstitutionPreservesExistingTemporaryDirectory() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp"),
            withIntermediateDirectories: true
        )
        try "keep\n".write(
            to: rootURL.appendingPathComponent("tmp/keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("cat <(printf 'ok\\n') > out.txt; ls / | grep '^tmp$'; cat /tmp/keep.txt")

        XCTAssertEqual(result.stdout, "tmp\nkeep\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testAdvancedStringParameterExpansionRunsThroughSharedShellRuntime() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run(
            #"WORD=AlphaBetaAlpha.txt; PATHVAL=/tmp/work/report.final.txt; REPEAT=foofoo; MIX=aBc; printf '%s\n' "${#WORD}" "${WORD:5:4}" "${WORD: -4}" "${PATHVAL##*/}" "${PATHVAL%.*}" "${PATHVAL%%.*}" "${REPEAT/foo/bar}" "${REPEAT//foo/bar}" "${MIX^}" "${MIX^^}" "${MIX,}" "${MIX,,}""#
        )

        XCTAssertEqual(
            result.stdout,
            """
            18
            Beta
            .txt
            report.final.txt
            /tmp/work/report.final
            /tmp/work/report
            barfoo
            barbar
            ABc
            ABC
            aBc
            abc

            """
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testDefaultAssignmentParameterExpansionMutatesShellState() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let scalar = await shell.run(#"printf '%s/%s\n' "${MISSING:=fallback}" "$MISSING"; printf 'after:%s\n' "$MISSING""#)
        let nameref = await shell.run(#"declare -n ref=target; printf '%s/%s\n' "${ref:=value}" "$target"; printf 'after:%s\n' "$target""#)
        let indexedArray = await shell.run(#"printf '%s/%s\n' "${arr[1]:=item}" "${arr[1]}"; printf 'after:%s\n' "${arr[1]}""#)
        let associativeArray = await shell.run(#"declare -A map; printf '%s/%s\n' "${map[key]:=entry}" "${map[key]}"; printf 'after:%s\n' "${map[key]}""#)

        XCTAssertEqual(scalar.stdout, "fallback/fallback\nafter:fallback\n")
        XCTAssertEqual(scalar.stderr, "")
        XCTAssertEqual(scalar.exitCode, 0)
        XCTAssertEqual(nameref.stdout, "value/value\nafter:value\n")
        XCTAssertEqual(nameref.stderr, "")
        XCTAssertEqual(nameref.exitCode, 0)
        XCTAssertEqual(indexedArray.stdout, "item/item\nafter:item\n")
        XCTAssertEqual(indexedArray.stderr, "")
        XCTAssertEqual(indexedArray.exitCode, 0)
        XCTAssertEqual(associativeArray.stdout, "entry/entry\nafter:entry\n")
        XCTAssertEqual(associativeArray.stderr, "")
        XCTAssertEqual(associativeArray.exitCode, 0)
    }

    func testArithmeticCommandRunsThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let zero = await shell.run("(( 0 ))")
        let nonzero = await shell.run("(( 2 ))")
        let updates = await shell.run("COUNT=1; (( COUNT += 2, COUNT++ )); printf '%s\\n' $COUNT")
        let prefixUpdate = await shell.run("(( ++COUNT )); printf '%s\\n' $COUNT")
        let logical = await shell.run("(( 0 )) || echo zero; (( 2 )) && echo nonzero")
        let substitution = await shell.run("N=1; (( N += $(printf 2) )); printf '%s\\n' $N")
        let pipelineDoesNotLeakState = await shell.run("PIPE=1; (( PIPE=5 )) | cat; printf '%s\\n' $PIPE")
        let redirection = await shell.run("(( 1 )) > out.txt; stat -c %s out.txt")
        let divideByZero = await shell.run("COUNT=4; (( COUNT /= 0 )); printf '%s\\n' $COUNT")
        let indexedArrayLvalues = await shell.run("""
        arr=(1 2)
        i=1
        (( arr[i] += 5, arr[2] = arr[0] + arr[1], arr[2]++ ))
        printf '%s/%s/%s/%s\\n' "${arr[0]}" "${arr[1]}" "${arr[2]}" "$(( arr[i] + arr[2] ))"
        """)
        let associativeArrayLvalues = await shell.run("""
        declare -A counts
        k=json
        (( counts[$k]++, counts["pdf"] += 2 ))
        printf '%s/%s/%s\\n' "${counts[json]}" "${counts[pdf]}" "$(( counts[$k] + counts[pdf] ))"
        """)
        let namerefArrayLvalue = await shell.run("""
        declare -A totals
        declare -n ref=totals
        kind=md
        (( ref[$kind] += 4 ))
        printf '%s\\n' "${totals[md]}"
        """)
        let cStyleForArrayMutation = await shell.run("""
        arr=(0 0 0)
        for (( i=0; i < 3; i++ )); do (( arr[i] += i + 1 )); done
        printf '%s/%s/%s\\n' "${arr[0]}" "${arr[1]}" "${arr[2]}"
        """)
        let pipelineArrayIsolation = await shell.run("""
        declare -A scoped
        scoped[k]=1
        (( scoped[k] += 9 )) | cat
        printf '%s\\n' "${scoped[k]}"
        """)

        XCTAssertEqual(zero.stdout, "")
        XCTAssertEqual(zero.stderr, "")
        XCTAssertEqual(zero.exitCode, 1)
        XCTAssertEqual(nonzero.stdout, "")
        XCTAssertEqual(nonzero.stderr, "")
        XCTAssertEqual(nonzero.exitCode, 0)
        XCTAssertEqual(updates.stdout, "4\n")
        XCTAssertEqual(updates.stderr, "")
        XCTAssertEqual(updates.exitCode, 0)
        XCTAssertEqual(prefixUpdate.stdout, "5\n")
        XCTAssertEqual(prefixUpdate.stderr, "")
        XCTAssertEqual(prefixUpdate.exitCode, 0)
        XCTAssertEqual(logical.stdout, "zero\nnonzero\n")
        XCTAssertEqual(logical.stderr, "")
        XCTAssertEqual(logical.exitCode, 0)
        XCTAssertEqual(substitution.stdout, "3\n")
        XCTAssertEqual(substitution.stderr, "")
        XCTAssertEqual(substitution.exitCode, 0)
        XCTAssertEqual(pipelineDoesNotLeakState.stdout, "1\n")
        XCTAssertEqual(pipelineDoesNotLeakState.stderr, "")
        XCTAssertEqual(pipelineDoesNotLeakState.exitCode, 0)
        XCTAssertEqual(redirection.stdout, "0\n")
        XCTAssertEqual(redirection.stderr, "")
        XCTAssertEqual(redirection.exitCode, 0)
        XCTAssertEqual(divideByZero.stdout, "4\n")
        XCTAssertEqual(divideByZero.stderr, "arithmetic expansion: division by zero\n")
        XCTAssertEqual(divideByZero.exitCode, 0)
        XCTAssertEqual(indexedArrayLvalues.stdout, "1/7/9/16\n")
        XCTAssertEqual(indexedArrayLvalues.stderr, "")
        XCTAssertEqual(indexedArrayLvalues.exitCode, 0)
        XCTAssertEqual(associativeArrayLvalues.stdout, "1/2/3\n")
        XCTAssertEqual(associativeArrayLvalues.stderr, "")
        XCTAssertEqual(associativeArrayLvalues.exitCode, 0)
        XCTAssertEqual(namerefArrayLvalue.stdout, "4\n")
        XCTAssertEqual(namerefArrayLvalue.stderr, "")
        XCTAssertEqual(namerefArrayLvalue.exitCode, 0)
        XCTAssertEqual(cStyleForArrayMutation.stdout, "1/2/3\n")
        XCTAssertEqual(cStyleForArrayMutation.stderr, "")
        XCTAssertEqual(cStyleForArrayMutation.exitCode, 0)
        XCTAssertEqual(pipelineArrayIsolation.stdout, "1\n")
        XCTAssertEqual(pipelineArrayIsolation.stderr, "")
        XCTAssertEqual(pipelineArrayIsolation.exitCode, 0)
        XCTAssertFalse(redirection.stdout.contains(rootURL.path))
        XCTAssertFalse(divideByZero.stderr.contains(rootURL.path))
        XCTAssertFalse(associativeArrayLvalues.stdout.contains(rootURL.path))
    }

}

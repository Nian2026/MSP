import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyShellStateTests {
    func testIndexedArraysAndMapfileRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "zero\none\ntwo\nthree\n".write(
            to: rootURL.appendingPathComponent("input.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let arrayBasics = await shell.run("""
        items=(alpha 'two words')
        items+=(gamma)
        printf '<%s>\\n' "${items[@]}"
        printf 'first:%s count:%s star:%s scalar:%s\\n' "${items[0]}" "${#items[@]}" "${items[*]}" "$items"
        printf 'idx:%s\\n' "${!items[@]}"
        """)
        let unsetArray = await shell.run("unset items; printf 'after:%s/%s\\n' \"${#items[@]}\" \"${items[0]}\"")
        let pipelineIsolation = await shell.run("items=(parent); items=(child) | cat; printf '<%s>\\n' \"${items[@]}\"")
        let mapfile = await shell.run("mapfile -t lines < input.txt; printf '<%s>\\n' \"${lines[@]}\"; printf 'count:%s first:%s\\n' \"${#lines[@]}\" \"$lines\"")
        let mapfileOrigin = await shell.run("lines=(keep); mapfile -t -s 1 -n 2 -O 1 lines < input.txt; printf '<%s>\\n' \"${lines[@]}\"")
        let readarrayAlias = await shell.run("readarray -t alias < input.txt; printf '%s/%s/%s\\n' \"${alias[0]}\" \"${alias[3]}\" \"${#alias[@]}\"")
        let subscriptMutation = await shell.run("""
        arr=(a b c)
        arr[1]=BRAVO
        arr[5]=tail
        arr[5]+=!
        i=2
        X='hello world'
        arr[$i]="$X"
        printf 'count:%s indices:%s scalar:%s missing:%s\\n' "${#arr[@]}" "${!arr[*]}" "$arr" "${arr[3]}"
        printf '<%s>\\n' "${arr[@]}"
        """)
        let subscriptPipelineIsolation = await shell.run("arr=(parent); arr[0]=child | cat; printf '<%s>\\n' \"${arr[@]}\"")
        let lookup = await shell.run("command -v mapfile; type mapfile; command -v readarray; type readarray")

        XCTAssertEqual(
            arrayBasics.stdout,
            "<alpha>\n<two words>\n<gamma>\nfirst:alpha count:3 star:alpha two words gamma scalar:alpha\nidx:0\nidx:1\nidx:2\n"
        )
        XCTAssertEqual(arrayBasics.stderr, "")
        XCTAssertEqual(arrayBasics.exitCode, 0)
        XCTAssertEqual(unsetArray.stdout, "after:0/\n")
        XCTAssertEqual(unsetArray.stderr, "")
        XCTAssertEqual(unsetArray.exitCode, 0)
        XCTAssertEqual(pipelineIsolation.stdout, "<parent>\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(mapfile.stdout, "<zero>\n<one>\n<two>\n<three>\ncount:4 first:zero\n")
        XCTAssertEqual(mapfile.stderr, "")
        XCTAssertEqual(mapfile.exitCode, 0)
        XCTAssertEqual(mapfileOrigin.stdout, "<keep>\n<one>\n<two>\n")
        XCTAssertEqual(mapfileOrigin.stderr, "")
        XCTAssertEqual(mapfileOrigin.exitCode, 0)
        XCTAssertEqual(readarrayAlias.stdout, "zero/three/4\n")
        XCTAssertEqual(readarrayAlias.stderr, "")
        XCTAssertEqual(readarrayAlias.exitCode, 0)
        XCTAssertEqual(
            subscriptMutation.stdout,
            "count:4 indices:0 1 2 5 scalar:a missing:\n<a>\n<BRAVO>\n<hello world>\n<tail!>\n"
        )
        XCTAssertEqual(subscriptMutation.stderr, "")
        XCTAssertEqual(subscriptMutation.exitCode, 0)
        XCTAssertEqual(subscriptPipelineIsolation.stdout, "<parent>\n")
        XCTAssertEqual(subscriptPipelineIsolation.stderr, "")
        XCTAssertEqual(subscriptPipelineIsolation.exitCode, 0)
        XCTAssertEqual(
            lookup.stdout,
            "mapfile\nmapfile is a shell builtin\nreadarray\nreadarray is a shell builtin\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertFalse(mapfile.stdout.contains(rootURL.path))
    }

    func testDeclareAndTypesetRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let scalarDeclarations = await shell.run("declare x=1 y='two words'; printf '%s/%s\\n' \"$x\" \"$y\"")
        let indexedArrayDeclaration = await shell.run("""
        declare -a arr=(alpha 'two words')
        printf '<%s>\\n' "${arr[@]}"
        printf 'scalar:%s count:%s\\n' "$arr" "${#arr[@]}"
        """)
        let typesetAlias = await shell.run("typeset -a alias=(zero one); printf '%s/%s/%s\\n' \"${alias[0]}\" \"${alias[1]}\" \"${#alias[@]}\"")
        let declarationPrint = await shell.run("declare -p arr x")
        let pipelineIsolation = await shell.run("declare scoped=parent; declare scoped=child | cat; printf '%s\\n' \"$scoped\"")
        let lookup = await shell.run("command -v declare; type declare; command -v typeset; type typeset")
        let invalidName = await shell.run("declare 1bad")

        XCTAssertEqual(scalarDeclarations.stdout, "1/two words\n")
        XCTAssertEqual(scalarDeclarations.stderr, "")
        XCTAssertEqual(scalarDeclarations.exitCode, 0)
        XCTAssertEqual(
            indexedArrayDeclaration.stdout,
            "<alpha>\n<two words>\nscalar:alpha count:2\n"
        )
        XCTAssertEqual(indexedArrayDeclaration.stderr, "")
        XCTAssertEqual(indexedArrayDeclaration.exitCode, 0)
        XCTAssertEqual(typesetAlias.stdout, "zero/one/2\n")
        XCTAssertEqual(typesetAlias.stderr, "")
        XCTAssertEqual(typesetAlias.exitCode, 0)
        XCTAssertEqual(
            declarationPrint.stdout,
            "declare -a arr=(\"alpha\" \"two words\")\ndeclare -- x=\"1\"\n"
        )
        XCTAssertEqual(declarationPrint.stderr, "")
        XCTAssertEqual(declarationPrint.exitCode, 0)
        XCTAssertEqual(pipelineIsolation.stdout, "parent\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(
            lookup.stdout,
            "declare\ndeclare is a shell builtin\ntypeset\ntypeset is a shell builtin\n"
        )
        XCTAssertEqual(lookup.stderr, "")
        XCTAssertEqual(lookup.exitCode, 0)
        XCTAssertEqual(invalidName.stdout, "")
        XCTAssertEqual(invalidName.stderr, "declare: `1bad': not a valid identifier\n")
        XCTAssertEqual(invalidName.exitCode, 1)
        XCTAssertFalse(declarationPrint.stdout.contains(rootURL.path))
    }

    func testAssociativeArraysAndNamerefsRunThroughSharedShellRuntime() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let associative = await shell.run("""
        declare -A labels=( ["/course 2026"]="Course Data" ["/downloads"]="Downloads" )
        labels["/course 2026"]+=!
        p="/downloads"
        printf '%s|%s|%s\\n' "${labels[/course 2026]}" "${labels[$p]}" "${labels[/missing]:-none}"
        printf 'keys:%s\\n' "${!labels[*]}"
        printf '<%s>\\n' "${labels[@]}" | sort
        declare -p labels
        """)
        let namerefScalar = await shell.run("""
        target=before
        declare -n ref=target
        ref=after
        printf '%s/%s\\n' "$target" "$ref"
        declare -p ref
        """)
        let namerefArray = await shell.run("""
        declare -A amap
        declare -n mapref=amap
        mapref[key]=value
        printf '%s/%s\\n' "${amap[key]}" "${mapref[key]}"
        """)
        let defaultOperation = await shell.run("declare -A counts; k=json; printf '%s\\n' \"${counts[$k]:-0}\"")
        let pipelineIsolation = await shell.run("declare -A scoped; scoped[k]=parent; scoped[k]=child | cat; printf '%s\\n' \"${scoped[k]}\"")
        let invalidNameref = await shell.run("declare -n bad=1bad")

        XCTAssertEqual(
            associative.stdout,
            """
            Course Data!|Downloads|none
            keys:/course 2026 /downloads
            <Course Data!>
            <Downloads>
            declare -A labels=([/course 2026]="Course Data!" [/downloads]="Downloads")
            """
            + "\n"
        )
        XCTAssertEqual(associative.stderr, "")
        XCTAssertEqual(associative.exitCode, 0)
        XCTAssertEqual(
            namerefScalar.stdout,
            "after/after\ndeclare -n ref=\"target\"\n"
        )
        XCTAssertEqual(namerefScalar.stderr, "")
        XCTAssertEqual(namerefScalar.exitCode, 0)
        XCTAssertEqual(namerefArray.stdout, "value/value\n")
        XCTAssertEqual(namerefArray.stderr, "")
        XCTAssertEqual(namerefArray.exitCode, 0)
        XCTAssertEqual(defaultOperation.stdout, "0\n")
        XCTAssertEqual(defaultOperation.stderr, "")
        XCTAssertEqual(defaultOperation.exitCode, 0)
        XCTAssertEqual(pipelineIsolation.stdout, "parent\n")
        XCTAssertEqual(pipelineIsolation.stderr, "")
        XCTAssertEqual(pipelineIsolation.exitCode, 0)
        XCTAssertEqual(invalidNameref.stdout, "")
        XCTAssertEqual(invalidNameref.stderr, "declare: `1bad': invalid variable name for name reference\n")
        XCTAssertEqual(invalidNameref.exitCode, 2)
        XCTAssertFalse(associative.stdout.contains(rootURL.path))
    }
}

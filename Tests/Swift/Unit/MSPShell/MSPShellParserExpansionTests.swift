import MSPShell
import XCTest

extension MSPShellParserTests {
    func testExpandsParametersWordSplittingAndPathnamesThroughSharedLayer() throws {
        let expansion = MSPShellExpansionContext(
            environment: [
                "NAME": "two words",
                "PATTERN": "*.txt",
                "COUNT": "5"
            ],
            currentDirectory: "/",
            pathnameCandidates: [
                "/a.txt",
                "/b.md",
                "/nested/c.txt"
            ]
        )

        let parsed = try MSPShellParser()
            .parseExecutableInvocation("printf '%s\\n' \"$NAME\" $NAME $PATTERN \"*.txt\" $((COUNT + 2 * 3))")
            .expanded(in: expansion)

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(parsed.arguments, ["%s\\n", "two words", "two", "words", "a.txt", "*.txt", "11"])

        XCTAssertEqual(mspShellFieldSplit("left::right", ifs: ":"), ["left", "", "right"])
        let ifsParsed = try MSPShellParser()
            .parseExecutableInvocation("set -- $WORDS")
            .expanded(in: MSPShellExpansionContext(environment: ["WORDS": "left::right"], ifs: ":"))
        XCTAssertEqual(ifsParsed.arguments, ["--", "left", "", "right"])
    }

    @available(*, deprecated, message: "This test intentionally exercises the deprecated parser expansion API.")
    func testDeprecatedParserExpansionConvenienceStaysAvailableThroughUmbrellaImport() throws {
        let parsed = try MSPShellParser().parseExecutableInvocation(
            "printf '%s\\n' $NAME",
            expansion: MSPShellExpansionContext(environment: ["NAME": "two words"])
        )

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(parsed.arguments, ["%s\\n", "two", "words"])
    }

    func testExpandsQuotedPositionalParametersAsShellFieldsThroughSharedLayer() throws {
        let expansion = MSPShellExpansionContext(
            positionalParameters: ["a a", "b"]
        )

        let parsed = try MSPShellParser()
            .parseExecutableInvocation(#"printf '<%s>\n' "$@" pre"$@"post "$*" $@"#)
            .expanded(in: expansion)

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(
            parsed.arguments,
            [
                "<%s>\\n",
                "a a",
                "b",
                "prea a",
                "bpost",
                "a a b",
                "a",
                "a",
                "b"
            ]
        )

        let empty = try MSPShellParser()
            .parseExecutableInvocation(#"printf '<%s>\n' "$@" pre"$@"post"#)
            .expanded(in: MSPShellExpansionContext(positionalParameters: []))

        XCTAssertEqual(empty.arguments, ["<%s>\\n", "prepost"])
    }

    func testExpandsAdvancedStringParametersThroughSharedLayer() throws {
        let expansion = MSPShellExpansionContext(
            environment: [
                "WORD": "AlphaBetaAlpha.txt",
                "PATHVAL": "/tmp/work/report.final.txt",
                "REPEAT": "foofoo",
                "MIX": "aBc"
            ]
        )

        let parsed = try MSPShellParser()
            .parseExecutableInvocation(#"printf '%s\n' "${#WORD}" "${WORD:5:4}" "${WORD: -4}" "${PATHVAL##*/}" "${PATHVAL%.*}" "${PATHVAL%%.*}" "${REPEAT/foo/bar}" "${REPEAT//foo/bar}" "${MIX^}" "${MIX^^}" "${MIX,}" "${MIX,,}""#)
            .expanded(in: expansion)

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(
            parsed.arguments,
            [
                "%s\\n",
                "18",
                "Beta",
                ".txt",
                "report.final.txt",
                "/tmp/work/report.final",
                "/tmp/work/report",
                "barfoo",
                "barbar",
                "ABc",
                "ABC",
                "aBc",
                "abc"
            ]
        )
    }

    func testSyncExpansionPreservesCommandSubstitutionSyntax() throws {
        let parsed = try MSPShellParser()
            .parseExecutableInvocation(#"printf '%s\n' "$(echo "$WORD")" "`echo $WORD`" "$((N + 2))" "${WORD}""#)
            .expanded(in: MSPShellExpansionContext(environment: ["N": "3", "WORD": "alpha"]))

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(
            parsed.arguments,
            ["%s\\n", #"$(echo "$WORD")"#, "`echo $WORD`", "5", "alpha"]
        )
    }

    func testQuotedStarExpansionUsesIFSFirstCharacter() throws {
        let parsed = try MSPShellParser()
            .parseExecutableInvocation(#"printf '%s\n' "$*" "${items[*]}""#)
            .expanded(in: MSPShellExpansionContext(
                arrays: ["items": MSPShellIndexedArray(["x", "y"])],
                positionalParameters: ["a", "b"],
                ifs: ":,"
            ))

        XCTAssertEqual(parsed.commandName, "printf")
        XCTAssertEqual(parsed.arguments, ["%s\\n", "a:b", "x:y"])
    }
}

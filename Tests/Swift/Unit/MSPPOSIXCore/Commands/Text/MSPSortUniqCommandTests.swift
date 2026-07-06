import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPSortUniqCommandTests: XCTestCase {
    func testSortSupportsCommonGNUOrderingOptions() async throws {
        let basic = await runCommand("sort", [], standardInput: Data("b\na\nc\n".utf8))
        let unique = await runCommand("sort", ["-u"], standardInput: Data("b\na\nb\n".utf8))
        let numericReverse = await runCommand("sort", ["-nr"], standardInput: Data("2\n10\n1\n".utf8))
        let fieldKey = await runCommand("sort", ["-t", "|", "-k", "2,2n"], standardInput: Data("b|10\na|2\nc|1\n".utf8))
        let checkFailure = await runCommand("sort", ["-c"], standardInput: Data("b\na\n".utf8))
        let quietCheckFailure = await runCommand("sort", ["-C"], standardInput: Data("b\na\n".utf8))
        let longQuietCheckFailure = await runCommand("sort", ["--check=quiet"], standardInput: Data("b\na\n".utf8))
        let badCheck = await runCommand("sort", ["--check=nope"], standardInput: Data("a\n".utf8))
        let stableNumeric = await runCommand("sort", ["-n", "-s"], standardInput: Data("2 b\n2 a\n1 c\n".utf8))
        let stableCheck = await runCommand("sort", ["-n", "-s", "-c"], standardInput: Data("2 b\n2 a\n".utf8))
        let help = await runCommand("sort", ["--help"])
        let version = await runCommand("sort", ["--version"])

        XCTAssertEqual(basic.stdout, "a\nb\nc\n")
        XCTAssertEqual(unique.stdout, "a\nb\n")
        XCTAssertEqual(numericReverse.stdout, "10\n2\n1\n")
        XCTAssertEqual(fieldKey.stdout, "c|1\na|2\nb|10\n")
        XCTAssertEqual(checkFailure.exitCode, 1)
        XCTAssertEqual(checkFailure.stderr, "sort: -:2: disorder: a\n")
        XCTAssertEqual(quietCheckFailure.stderr, "")
        XCTAssertEqual(quietCheckFailure.exitCode, 1)
        XCTAssertEqual(longQuietCheckFailure.stderr, "")
        XCTAssertEqual(longQuietCheckFailure.exitCode, 1)
        XCTAssertEqual(
            badCheck.stderr,
            """
            sort: invalid argument \u{2018}nope\u{2019} for \u{2018}--check\u{2019}
            Valid arguments are:
              - \u{2018}quiet\u{2019}, \u{2018}silent\u{2019}
              - \u{2018}diagnose-first\u{2019}
            Try 'sort --help' for more information.

            """
        )
        XCTAssertEqual(badCheck.exitCode, 1)
        XCTAssertEqual(stableNumeric.stdout, "1 c\n2 b\n2 a\n")
        XCTAssertEqual(stableCheck.exitCode, 0)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: sort [OPTION]... [FILE]...\n"))
        XCTAssertEqual(version.stdout, "sort (GNU coreutils) 9.1\n")
    }

    func testJoinSupportsHeaderZeroTerminatedCheckOrderAndAutoFormat() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/left.csv": Data("id,name,kind\n1,A,x\n2,B\n".utf8),
            "/right.csv": Data("id,color\n1,red\n3,blue\n".utf8),
            "/left-z.txt": Data("1 a\u{0}2 b\u{0}".utf8),
            "/right-z.txt": Data("1 x\u{0}3 y\u{0}".utf8),
            "/unsorted-left.txt": Data("2 b\n1 a\n".utf8),
            "/unsorted-header-left.txt": Data("id value\n2 b\n1 a\n".utf8),
            "/whole-left.txt": Data("a b\nc d\n".utf8),
            "/whole-right.txt": Data("a b\nx y\n".utf8),
            "/nul-sep-left.txt": Data("1\u{0}a\n".utf8),
            "/nul-sep-right.txt": Data("1\u{0}x\n".utf8),
            "/default-disorder-left.txt": Data("a left\nc late\nb disorder\n".utf8),
            "/default-disorder-right.txt": Data("b right\n".utf8),
            "/right.txt": Data("1 x\n2 y\n".utf8)
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let auto = await runCommand(
            "join",
            ["-t", ",", "--header", "-a", "1", "-a", "2", "-e", "NA", "-o", "auto", "/left.csv", "/right.csv"],
            workspace: workspace
        )
        let zeroTerminated = await runCommand(
            "join",
            ["-z", "/left-z.txt", "/right-z.txt"],
            workspace: workspace
        )
        let checkOrder = await runCommand(
            "join",
            ["--check-order", "/unsorted-left.txt", "/right.txt"],
            workspace: workspace
        )
        let headerCheckOrder = await runCommand(
            "join",
            ["--header", "--check-order", "/unsorted-header-left.txt", "/right.txt"],
            workspace: workspace
        )
        let noCheckOrder = await runCommand(
            "join",
            ["--nocheck-order", "/unsorted-left.txt", "/right.txt"],
            workspace: workspace
        )
        let wholeLineSeparator = await runCommand(
            "join",
            ["-t", "", "/whole-left.txt", "/whole-right.txt"],
            workspace: workspace
        )
        let multiCharacterSeparator = await runCommand(
            "join",
            ["-t", "ab", "/left.csv", "/right.csv"],
            workspace: workspace
        )
        let nulFieldSeparator = await runCommand(
            "join",
            ["-t", "\\0", "/nul-sep-left.txt", "/nul-sep-right.txt"],
            workspace: workspace
        )
        let bothStdin = await runCommand(
            "join",
            ["-", "-"],
            workspace: workspace,
            standardInput: Data("a\n".utf8)
        )
        let defaultDisorder = await runCommand(
            "join",
            ["/default-disorder-left.txt", "/default-disorder-right.txt"],
            workspace: workspace
        )
        let help = await runCommand("join", ["--help"], workspace: workspace)
        let version = await runCommand("join", ["--version"], workspace: workspace)

        XCTAssertEqual(auto.stdout, "id,name,kind,color\n1,A,x,red\n2,B,NA,NA\n3,NA,NA,blue\n")
        XCTAssertEqual(zeroTerminated.stdoutData, Data("1 a x\u{0}".utf8))
        XCTAssertEqual(checkOrder.stderr, "join: /unsorted-left.txt:2: is not sorted: 1 a\n")
        XCTAssertEqual(checkOrder.exitCode, 1)
        XCTAssertEqual(headerCheckOrder.stderr, "join: /unsorted-header-left.txt:3: is not sorted: 1 a\n")
        XCTAssertEqual(headerCheckOrder.exitCode, 1)
        XCTAssertEqual(noCheckOrder.exitCode, 0)
        XCTAssertEqual(wholeLineSeparator.stdout, "a b\n")
        XCTAssertEqual(multiCharacterSeparator.stderr, "join: multi-character tab \u{2018}ab\u{2019}\n")
        XCTAssertEqual(multiCharacterSeparator.exitCode, 1)
        XCTAssertEqual(nulFieldSeparator.stdoutData, Data("1\u{0}a\u{0}x\n".utf8))
        XCTAssertEqual(bothStdin.stderr, "join: both files cannot be standard input: No such file or directory\n")
        XCTAssertEqual(bothStdin.exitCode, 1)
        XCTAssertEqual(defaultDisorder.stdout, "")
        XCTAssertEqual(defaultDisorder.stderr, "join: /default-disorder-left.txt:3: is not sorted: b disorder\njoin: input is not in sorted order\n")
        XCTAssertEqual(defaultDisorder.exitCode, 1)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: join [OPTION]... FILE1 FILE2\n"))
        XCTAssertEqual(version.stdout, "join (GNU coreutils) 9.1\n")
    }

    func testSortUniqueUsesSortKeyEquivalenceLikeGNUCoreutils() async throws {
        let keyUnique = await runCommand(
            "sort",
            ["-u", "-t", "|", "-k", "2,2n"],
            standardInput: Data("b|2\na|2\nc|1\n".utf8)
        )
        let numericUnique = await runCommand(
            "sort",
            ["-n", "-u"],
            standardInput: Data("2 b\n2 a\n1 c\n".utf8)
        )
        let foldUnique = await runCommand(
            "sort",
            ["-f", "-u"],
            standardInput: Data("b\nA\na\n".utf8)
        )

        XCTAssertEqual(keyUnique.stdout, "c|1\nb|2\n")
        XCTAssertEqual(numericUnique.stdout, "1 c\n2 b\n")
        XCTAssertEqual(foldUnique.stdout, "A\nb\n")
    }

    func testSortCanWriteOutputThroughWorkspaceFS() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/input.txt": Data("b\na\n".utf8)
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let result = await runCommand(
            "sort",
            ["-o", "/sorted.txt", "/input.txt"],
            workspace: workspace
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(fileSystem.files["/sorted.txt"], Data("a\nb\n".utf8))
    }

    func testSortSupportsFiles0FromWorkspaceAndStdinLists() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/a.txt": Data("delta\nalpha\n".utf8),
            "/b.txt": Data("charlie\nbravo\n".utf8),
            "/list0": Data("/a.txt\u{0}/b.txt\u{0}".utf8),
            "/empty": Data()
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let workspaceList = await runCommand(
            "sort",
            ["--files0-from", "/list0"],
            workspace: workspace
        )
        let stdinList = await runCommand(
            "sort",
            ["--files0-from=-"],
            workspace: workspace,
            standardInput: Data("/b.txt\u{0}/a.txt\u{0}".utf8)
        )
        let mixedOperands = await runCommand(
            "sort",
            ["--files0-from", "/list0", "/a.txt"],
            workspace: workspace
        )
        let emptyList = await runCommand(
            "sort",
            ["--files0-from", "/empty"],
            workspace: workspace
        )
        let emptyName = await runCommand(
            "sort",
            ["--files0-from=-"],
            workspace: workspace,
            standardInput: Data("/a.txt\u{0}\u{0}".utf8)
        )
        let stdinMember = await runCommand(
            "sort",
            ["--files0-from=-"],
            workspace: workspace,
            standardInput: Data("-\u{0}".utf8)
        )

        XCTAssertEqual(workspaceList.stdout, "alpha\nbravo\ncharlie\ndelta\n")
        XCTAssertEqual(workspaceList.stderr, "")
        XCTAssertEqual(workspaceList.exitCode, 0)
        XCTAssertEqual(stdinList.stdout, "alpha\nbravo\ncharlie\ndelta\n")
        XCTAssertEqual(stdinList.stderr, "")
        XCTAssertEqual(stdinList.exitCode, 0)
        XCTAssertEqual(
            mixedOperands.stderr,
            """
            sort: extra operand '/a.txt'
            file operands cannot be combined with --files0-from
            Try 'sort --help' for more information.

            """
        )
        XCTAssertEqual(mixedOperands.exitCode, 2)
        XCTAssertEqual(emptyList.stderr, "sort: no input from '/empty'\n")
        XCTAssertEqual(emptyList.exitCode, 2)
        XCTAssertEqual(emptyName.stderr, "sort: -:2: invalid zero-length file name\n")
        XCTAssertEqual(emptyName.exitCode, 2)
        XCTAssertEqual(stdinMember.stderr, "sort: when reading file names from stdin, no file name of '-' allowed\n")
        XCTAssertEqual(stdinMember.exitCode, 2)
    }

    func testSortSupportsAdditionalGNUComparisonModes() async throws {
        let ignoreLeadingBlanks = await runCommand("sort", ["-b"], standardInput: Data(" b\na\n".utf8))
        let ignoreNonprinting = await runCommand("sort", ["-i"], standardInput: Data("a\u{1}z\naay\n".utf8))
        let month = await runCommand("sort", ["-M"], standardInput: Data("Feb\nJan\nbad\nDec\n".utf8))
        let version = await runCommand("sort", ["-V"], standardInput: Data("v2\nv10\nv1\n".utf8))
        let generalNumeric = await runCommand("sort", ["--sort=general-numeric"], standardInput: Data("1e3\n20\n-5\n".utf8))
        let sortWordMonth = await runCommand("sort", ["--sort=month"], standardInput: Data("Mar\nJan\n".utf8))

        XCTAssertEqual(ignoreLeadingBlanks.stdout, "a\n b\n")
        XCTAssertEqual(ignoreNonprinting.stdout, "aay\na\u{1}z\n")
        XCTAssertEqual(month.stdout, "bad\nJan\nFeb\nDec\n")
        XCTAssertEqual(version.stdout, "v1\nv2\nv10\n")
        XCTAssertEqual(generalNumeric.stdout, "-5\n20\n1e3\n")
        XCTAssertEqual(sortWordMonth.stdout, "Jan\nMar\n")
    }

    func testSortKeyRangesHonorGNUCharacterOffsetsAndPerKeyModifiers() async throws {
        let defaultSeparatorColumn = await runCommand(
            "sort",
            ["-k", "1.7,1.7"],
            standardInput: Data("a b c 2 d\npq rs 1 t\n".utf8)
        )
        let explicitSeparatorColumn = await runCommand(
            "sort",
            ["-t", "|", "-k", "2.2,2.2"],
            standardInput: Data("r1|b2|x\nr2|a9|x\nr3|c1|x\n".utf8)
        )
        let pos1NumericModifier = await runCommand(
            "sort",
            ["-t", "|", "-k", "2n,2"],
            standardInput: Data("b|10\na|2\nc|1\n".utf8)
        )
        let inheritedGlobalNumericModifier = await runCommand(
            "sort",
            ["-n", "-t", "|", "-k", "2,2"],
            standardInput: Data("b|10\na|2\nc|1\n".utf8)
        )
        let reversedLastResort = await runCommand(
            "sort",
            ["-r", "-t", "|", "-k", "2,2n"],
            standardInput: Data("a|1\nb|1\n".utf8)
        )

        XCTAssertEqual(defaultSeparatorColumn.stdout, "pq rs 1 t\na b c 2 d\n")
        XCTAssertEqual(explicitSeparatorColumn.stdout, "r3|c1|x\nr1|b2|x\nr2|a9|x\n")
        XCTAssertEqual(pos1NumericModifier.stdout, "c|1\na|2\nb|10\n")
        XCTAssertEqual(inheritedGlobalNumericModifier.stdout, "c|1\na|2\nb|10\n")
        XCTAssertEqual(reversedLastResort.stdout, "b|1\na|1\n")
    }

    func testSortAcceptsGNUPerformanceKnobsForInMemorySort() async throws {
        let result = await runCommand(
            "sort",
            ["--batch-size=2", "--parallel=2", "-S", "1M", "-T", "tmpdir"],
            standardInput: Data("b\na\n".utf8)
        )

        XCTAssertEqual(result.stdout, "a\nb\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSortSupportsRandomOrderingWithWorkspaceRandomSource() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/seed": Data("0123456789abcdef-extra".utf8)
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let shortOption = await runCommand(
            "sort",
            ["-R", "--random-source", "/seed"],
            workspace: workspace,
            standardInput: Data("a\nb\na\nc\n".utf8)
        )
        let sortWord = await runCommand(
            "sort",
            ["--sort=random", "--random-source=/seed"],
            workspace: workspace,
            standardInput: Data("alpha\nbeta\ngamma\n".utf8)
        )

        XCTAssertEqual(shortOption.stdout, "b\na\na\nc\n")
        XCTAssertEqual(shortOption.stderr, "")
        XCTAssertEqual(shortOption.exitCode, 0)
        XCTAssertEqual(sortWord.stdout, "gamma\nalpha\nbeta\n")
        XCTAssertEqual(sortWord.stderr, "")
        XCTAssertEqual(sortWord.exitCode, 0)
    }

    func testSortDebugAnnotatesStdoutAndValidatesIncompatibleOptions() async throws {
        let debug = await runCommand(
            "sort",
            ["--debug"],
            standardInput: Data("b\ta\n".utf8)
        )
        let checkDebug = await runCommand(
            "sort",
            ["-c", "--debug"],
            standardInput: Data("a\n".utf8)
        )
        let outputDebug = await runCommand(
            "sort",
            ["-o", "/out", "--debug"],
            standardInput: Data("a\n".utf8)
        )

        XCTAssertEqual(debug.stdout, "b>a\n___\n")
        XCTAssertEqual(debug.stderr, "sort: text ordering performed using \u{2018}C.UTF-8\u{2019} sorting rules\n")
        XCTAssertEqual(debug.exitCode, 0)
        XCTAssertEqual(checkDebug.stderr, "sort: options '-c --debug' are incompatible\n")
        XCTAssertEqual(checkDebug.exitCode, 2)
        XCTAssertEqual(outputDebug.stderr, "sort: options '-o --debug' are incompatible\n")
        XCTAssertEqual(outputDebug.exitCode, 2)
    }

    func testSortValidatesGNUBufferSizeSuffixesAndOrderingCompatibility() async throws {
        let bytes = await runCommand("sort", ["-S", "10b"], standardInput: Data("b\na\n".utf8))
        let percent = await runCommand("sort", ["--buffer-size=1%"], standardInput: Data("b\na\n".utf8))
        let invalidSuffix = await runCommand("sort", ["-S", "1Q"], standardInput: Data("a\n".utf8))
        let incompatible = await runCommand("sort", ["-nR"], standardInput: Data("1\n2\n".utf8))

        XCTAssertEqual(bytes.stdout, "a\nb\n")
        XCTAssertEqual(bytes.exitCode, 0)
        XCTAssertEqual(percent.stdout, "a\nb\n")
        XCTAssertEqual(percent.exitCode, 0)
        XCTAssertEqual(invalidSuffix.stderr, "sort: invalid suffix in -S argument '1Q'\n")
        XCTAssertEqual(invalidSuffix.exitCode, 2)
        XCTAssertEqual(incompatible.stderr, "sort: options '-nR' are incompatible\n")
        XCTAssertEqual(incompatible.exitCode, 2)
    }

    func testSortMergeMergesPresortedInputsWithoutResortingEachFile() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/left.txt": Data("b\na\n".utf8),
            "/right.txt": Data("c\n".utf8),
            "/sorted-left.txt": Data("a\nc\n".utf8),
            "/sorted-right.txt": Data("b\nd\n".utf8)
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let unsortedLeft = await runCommand(
            "sort",
            ["-m", "/left.txt", "/right.txt"],
            workspace: workspace
        )
        let presorted = await runCommand(
            "sort",
            ["--merge", "/sorted-left.txt", "/sorted-right.txt"],
            workspace: workspace
        )

        XCTAssertEqual(unsortedLeft.stdout, "b\na\nc\n")
        XCTAssertEqual(unsortedLeft.stderr, "")
        XCTAssertEqual(unsortedLeft.exitCode, 0)
        XCTAssertEqual(presorted.stdout, "a\nb\nc\nd\n")
        XCTAssertEqual(presorted.stderr, "")
        XCTAssertEqual(presorted.exitCode, 0)
    }

    func testSortValidatesAndParsesGNUFieldSeparators() async throws {
        let nulSeparator = await runCommand(
            "sort",
            ["-t", "\\0", "-k", "2,2n"],
            standardInput: Data("b\u{0}10\na\u{0}2\n".utf8)
        )
        let emptySeparator = await runCommand(
            "sort",
            ["-t", ""],
            standardInput: Data("b\na\n".utf8)
        )
        let multiCharacterSeparator = await runCommand(
            "sort",
            ["-t", "xx"],
            standardInput: Data("bxx2\naxx1\n".utf8)
        )

        XCTAssertEqual(nulSeparator.stdoutData, Data("a\u{0}2\nb\u{0}10\n".utf8))
        XCTAssertEqual(nulSeparator.stderr, "")
        XCTAssertEqual(nulSeparator.exitCode, 0)
        XCTAssertEqual(emptySeparator.stderr, "sort: empty tab\n")
        XCTAssertEqual(emptySeparator.exitCode, 2)
        XCTAssertEqual(multiCharacterSeparator.stderr, "sort: multi-character tab \u{2018}xx\u{2019}\n")
        XCTAssertEqual(multiCharacterSeparator.exitCode, 2)
    }

    func testUniqSkipAndCheckCharacterCountsAreByteBased() async throws {
        let eAcute = Data("éA\nèA\n".utf8)
        let skipOneByte = await runCommand("uniq", ["-s", "1"], standardInput: eAcute)
        let checkOneByte = await runCommand("uniq", ["-w", "1"], standardInput: eAcute)

        XCTAssertEqual(skipOneByte.stdoutData, eAcute)
        XCTAssertEqual(checkOneByte.stdoutData, Data("éA\n".utf8))
    }

    func testUniqIgnoreCaseAndZeroTerminatedFieldSkipsStayByteBased() async throws {
        let nonASCIICasePair = Data("Ä\nä\n".utf8)
        let ignoreCase = await runCommand("uniq", ["-i"], standardInput: nonASCIICasePair)
        let zeroTerminatedNewlineFields = await runCommand(
            "uniq",
            ["-z", "-f", "1"],
            standardInput: Data("A\nx\0B\ny\0".utf8)
        )

        XCTAssertEqual(ignoreCase.stdoutData, nonASCIICasePair)
        XCTAssertEqual(zeroTerminatedNewlineFields.stdoutData, Data("A\nx\0B\ny\0".utf8))
    }

    func testUniqSupportsCountsFiltersAndComparisonOptions() async throws {
        let counts = await runCommand("uniq", ["-c"], standardInput: Data("a\na\nb\n".utf8))
        let repeated = await runCommand("uniq", ["-d"], standardInput: Data("a\na\nb\n".utf8))
        let unique = await runCommand("uniq", ["-u"], standardInput: Data("a\na\nb\n".utf8))
        let ignoreCase = await runCommand("uniq", ["-i"], standardInput: Data("A\na\nb\n".utf8))
        let checkChars = await runCommand("uniq", ["-w", "1"], standardInput: Data("aa\nab\nb\n".utf8))
        let skipFields = await runCommand("uniq", ["-f", "1"], standardInput: Data("1 same\n2 same\n3 other\n".utf8))
        let skipChars = await runCommand("uniq", ["-s", "2"], standardInput: Data("xxA\nyyA\nzzB\n".utf8))
        let obsoleteSkipFields = await runCommand("uniq", ["-1"], standardInput: Data("1 same\n2 same\n3 other\n".utf8))
        let obsoleteSkipChars = await runCommand("uniq", ["+2"], standardInput: Data("xxA\nyyA\nzzB\n".utf8))
        let grouped = await runCommand("uniq", ["--group"], standardInput: Data("a\na\nb\nc\nc\n".utf8))
        let allRepeatedSeparate = await runCommand("uniq", ["--all-repeated=separate"], standardInput: Data("a\na\nb\nc\nc\n".utf8))
        let allRepeatedPrepend = await runCommand("uniq", ["--all-repeated=prepend"], standardInput: Data("a\na\nb\nc\nc\n".utf8))
        let groupAppend = await runCommand("uniq", ["--group=append"], standardInput: Data("a\na\nb\n".utf8))
        let groupBoth = await runCommand("uniq", ["--group=both"], standardInput: Data("a\na\nb\n".utf8))
        let groupConflict = await runCommand("uniq", ["--group", "-d"], standardInput: Data("a\na\n".utf8))
        let badGroup = await runCommand("uniq", ["--group=bad"], standardInput: Data("a\n".utf8))
        let badAllRepeated = await runCommand("uniq", ["--all-repeated=bad"], standardInput: Data("a\n".utf8))
        let help = await runCommand("uniq", ["--help"])
        let version = await runCommand("uniq", ["--version"])

        XCTAssertEqual(counts.stdout, "      2 a\n      1 b\n")
        XCTAssertEqual(repeated.stdout, "a\n")
        XCTAssertEqual(unique.stdout, "b\n")
        XCTAssertEqual(ignoreCase.stdout, "A\nb\n")
        XCTAssertEqual(checkChars.stdout, "aa\nb\n")
        XCTAssertEqual(skipFields.stdout, "1 same\n3 other\n")
        XCTAssertEqual(skipChars.stdout, "xxA\nzzB\n")
        XCTAssertEqual(obsoleteSkipFields.stdout, "1 same\n3 other\n")
        XCTAssertEqual(obsoleteSkipChars.stdout, "xxA\nzzB\n")
        XCTAssertEqual(grouped.stdout, "a\na\n\nb\n\nc\nc\n")
        XCTAssertEqual(allRepeatedSeparate.stdout, "a\na\n\nc\nc\n")
        XCTAssertEqual(allRepeatedPrepend.stdout, "\na\na\n\nc\nc\n")
        XCTAssertEqual(groupAppend.stdout, "a\na\n\nb\n\n")
        XCTAssertEqual(groupBoth.stdout, "\na\na\n\nb\n\n")
        XCTAssertEqual(
            groupConflict.stderr,
            """
            uniq: --group is mutually exclusive with -c/-d/-D/-u
            Try 'uniq --help' for more information.

            """
        )
        XCTAssertEqual(groupConflict.exitCode, 1)
        XCTAssertEqual(
            badGroup.stderr,
            """
            uniq: invalid argument \u{2018}bad\u{2019} for \u{2018}--group\u{2019}
            Valid arguments are:
              - \u{2018}prepend\u{2019}
              - \u{2018}append\u{2019}
              - \u{2018}separate\u{2019}
              - \u{2018}both\u{2019}
            Try 'uniq --help' for more information.

            """
        )
        XCTAssertEqual(badGroup.exitCode, 1)
        XCTAssertEqual(
            badAllRepeated.stderr,
            """
            uniq: invalid argument \u{2018}bad\u{2019} for \u{2018}--all-repeated\u{2019}
            Valid arguments are:
              - \u{2018}none\u{2019}
              - \u{2018}prepend\u{2019}
              - \u{2018}separate\u{2019}
            Try 'uniq --help' for more information.

            """
        )
        XCTAssertEqual(badAllRepeated.exitCode, 1)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: uniq [OPTION]... [INPUT [OUTPUT]]\n"))
        XCTAssertEqual(version.stdout, "uniq (GNU coreutils) 9.1\n")
    }

    func testUniqCanWriteOutputOperandThroughWorkspaceFS() async throws {
        let fileSystem = MutableTextWorkspaceFileSystem(files: [
            "/input.txt": Data("a\na\nb\n".utf8)
        ])
        let workspace = MutableTextWorkspace(fileSystem: fileSystem)

        let result = await runCommand(
            "uniq",
            ["/input.txt", "/output.txt"],
            workspace: workspace
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(fileSystem.files["/output.txt"], Data("a\nb\n".utf8))
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data = Data()
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(workspace: workspace, standardInput: standardInput)
        )
    }
}

private final class MutableTextWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    let mutableFileSystem: MutableTextWorkspaceFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { mutableFileSystem }

    init(fileSystem: MutableTextWorkspaceFileSystem) {
        self.mutableFileSystem = fileSystem
    }
}

private final class MutableTextWorkspaceFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if files[virtualPath] != nil {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile)
        }
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "mkdir")
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "touch")
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "remove")
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "copy")
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "move")
    }
}

import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPDataAndTextCommandTests: XCTestCase {
    func testBase64ChecksumsAndHexDumpMatchCommonLinuxOutputs() async throws {
        let input = Data("hello".utf8)

        let base64 = await runCommand("base64", ["-w", "0"], standardInput: input)
        let decoded = await runCommand("base64", ["-d"], standardInput: Data("aGVsbG8=".utf8))
        let decodedInvalid = await runCommand("base64", ["-d"], standardInput: Data("aGVsbG8=!\n".utf8))
        let decodedIgnoreGarbage = await runCommand("base64", ["-di"], standardInput: Data("aG Vs bG8=!!\n".utf8))
        let cksum = await runCommand("cksum", [], standardInput: Data("abc".utf8))
        let md5 = await runCommand("md5sum", [], standardInput: input)
        let sha1 = await runCommand("sha1sum", [], standardInput: input)
        let sha256 = await runCommand("sha256sum", [], standardInput: input)
        let xxd = await runCommand("xxd", ["-p"], standardInput: Data("ABC\n".utf8))
        let xxdColumns = await runCommand("xxd", ["-c4"], standardInput: Data("ABCD".utf8))
        let xxdGarbageGroup = await runCommand("xxd", ["-g", "nope"], standardInput: Data("ABCD".utf8))

        XCTAssertEqual(base64.stdout, "aGVsbG8=")
        XCTAssertEqual(decoded.stdout, "hello")
        XCTAssertEqual(decodedInvalid.stdout, "hello")
        XCTAssertEqual(decodedInvalid.stderr, "base64: invalid input\n")
        XCTAssertEqual(decodedInvalid.exitCode, 1)
        XCTAssertEqual(decodedIgnoreGarbage.stdout, "hello")
        XCTAssertEqual(decodedIgnoreGarbage.stderr, "")
        XCTAssertEqual(decodedIgnoreGarbage.exitCode, 0)
        XCTAssertEqual(cksum.stdout, "1219131554 3\n")
        XCTAssertEqual(md5.stdout, "5d41402abc4b2a76b9719d911017c592  -\n")
        XCTAssertEqual(sha1.stdout, "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d  -\n")
        XCTAssertEqual(
            sha256.stdout,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  -\n"
        )
        XCTAssertEqual(xxd.stdout, "4142430a\n")
        XCTAssertEqual(xxdColumns.stdout, "00000000: 4142 4344  ABCD\n")
        XCTAssertEqual(xxdGarbageGroup.stdout, "00000000: 41424344                          ABCD\n")
    }

    func testDigestCommandsVerifyChecksumFiles() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/bytes.txt": Data("abc".utf8),
            "/ok.md5": Data("900150983cd24fb0d6963f7d28e17f72  bytes.txt\n".utf8),
            "/bad.md5": Data("00000000000000000000000000000000  bytes.txt\n".utf8),
            "/malformed.md5": Data("badline\n".utf8),
            "/missing.md5": Data("900150983cd24fb0d6963f7d28e17f72  missing\n".utf8),
            "/mixed.md5": Data("badline\n900150983cd24fb0d6963f7d28e17f72  bytes.txt\n".utf8)
        ])

        let binary = await runCommand("md5sum", ["-b"], standardInput: Data("abc".utf8))
        let ok = await runCommand("md5sum", ["-c", "ok.md5"], workspace: workspace)
        let bad = await runCommand("md5sum", ["--check", "bad.md5"], workspace: workspace)
        let status = await runCommand("md5sum", ["--status", "-c", "bad.md5"], workspace: workspace)
        let malformed = await runCommand("md5sum", ["-c", "malformed.md5"], workspace: workspace)
        let statusMalformed = await runCommand("md5sum", ["--status", "-c", "malformed.md5"], workspace: workspace)
        let missing = await runCommand("md5sum", ["-c", "missing.md5"], workspace: workspace)
        let statusMissing = await runCommand("md5sum", ["--status", "-c", "missing.md5"], workspace: workspace)
        let mixed = await runCommand("md5sum", ["-c", "mixed.md5"], workspace: workspace)
        let stdin = await runCommand(
            "md5sum",
            ["-c"],
            workspace: workspace,
            standardInput: Data("900150983cd24fb0d6963f7d28e17f72  bytes.txt\n".utf8)
        )

        XCTAssertEqual(binary.stdout, "900150983cd24fb0d6963f7d28e17f72 *-\n")
        XCTAssertEqual(ok.stdout, "bytes.txt: OK\n")
        XCTAssertEqual(ok.stderr, "")
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertEqual(bad.stdout, "bytes.txt: FAILED\n")
        XCTAssertEqual(bad.stderr, "md5sum: WARNING: 1 computed checksum did NOT match\n")
        XCTAssertEqual(bad.exitCode, 1)
        XCTAssertEqual(status.stdout, "")
        XCTAssertEqual(status.stderr, "")
        XCTAssertEqual(status.exitCode, 1)
        XCTAssertEqual(malformed.stdout, "")
        XCTAssertEqual(malformed.stderr, "md5sum: malformed.md5: no properly formatted checksum lines found\n")
        XCTAssertEqual(malformed.exitCode, 1)
        XCTAssertEqual(statusMalformed.stdout, "")
        XCTAssertEqual(statusMalformed.stderr, "md5sum: malformed.md5: no properly formatted checksum lines found\n")
        XCTAssertEqual(statusMalformed.exitCode, 1)
        XCTAssertEqual(missing.stdout, "missing: FAILED open or read\n")
        XCTAssertEqual(
            missing.stderr,
            "md5sum: missing: No such file or directory\nmd5sum: WARNING: 1 listed file could not be read\n"
        )
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(statusMissing.stdout, "")
        XCTAssertEqual(statusMissing.stderr, "md5sum: missing: No such file or directory\n")
        XCTAssertEqual(statusMissing.exitCode, 1)
        XCTAssertEqual(mixed.stdout, "bytes.txt: OK\n")
        XCTAssertEqual(mixed.stderr, "md5sum: WARNING: 1 line is improperly formatted\n")
        XCTAssertEqual(mixed.exitCode, 0)
        XCTAssertEqual(stdin.stdout, "bytes.txt: OK\n")
        XCTAssertEqual(stdin.stderr, "")
        XCTAssertEqual(stdin.exitCode, 0)
    }

    func testTextSelectionMergeNumberTranslateAndCompareCommands() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/left.txt": Data("a\nb\nc\n".utf8),
            "/right.txt": Data("b\nc\nd\n".utf8),
            "/same.txt": Data("abc\n".utf8),
            "/other.txt": Data("abd\n".utf8),
            "/longer.txt": Data("abc\nx".utf8)
        ])

        let cut = await runCommand("cut", ["-d", ":", "-f", "2"], standardInput: Data("a:b:c\n".utf8))
        let paste = await runCommand("paste", ["-d", ",", "-s"], standardInput: Data("a\nb\n".utf8))
        let nl = await runCommand("nl", [], standardInput: Data("a\n\nb\n".utf8))
        let tr = await runCommand("tr", ["a-z", "A-Z"], standardInput: Data("abc 123\n".utf8))
        let comm = await runCommand("comm", ["/left.txt", "/right.txt"], workspace: workspace)
        let cmpDifferent = await runCommand("cmp", ["/same.txt", "/other.txt"], workspace: workspace)
        let cmpEOF = await runCommand("cmp", ["/same.txt", "/longer.txt"], workspace: workspace)
        let cmpSilent = await runCommand("cmp", ["-s", "/same.txt", "/same.txt"], workspace: workspace)
        let cmpMissing = await runCommand("cmp", ["/missing.txt", "/same.txt"], workspace: workspace)
        let cmpSilentMissing = await runCommand("cmp", ["-s", "/missing.txt", "/same.txt"], workspace: workspace)

        XCTAssertEqual(cut.stdout, "b\n")
        XCTAssertEqual(paste.stdout, "a,b\n")
        XCTAssertEqual(nl.stdout, "     1\ta\n       \n     2\tb\n")
        XCTAssertEqual(tr.stdout, "ABC 123\n")
        XCTAssertEqual(comm.stdout, "a\n\t\tb\n\t\tc\n\td\n")
        XCTAssertEqual(cmpDifferent.stdout, "/same.txt /other.txt differ: byte 3, line 1\n")
        XCTAssertEqual(cmpDifferent.exitCode, 1)
        XCTAssertEqual(cmpEOF.stderr, "cmp: EOF on /same.txt after byte 4, line 1\n")
        XCTAssertEqual(cmpEOF.exitCode, 1)
        XCTAssertEqual(cmpSilent.exitCode, 0)
        XCTAssertEqual(cmpMissing.stderr, "cmp: /missing.txt: No such file or directory\n")
        XCTAssertEqual(cmpMissing.exitCode, 2)
        XCTAssertEqual(cmpSilentMissing.stderr, "")
        XCTAssertEqual(cmpSilentMissing.exitCode, 2)
    }

    func testStreamTextUtilitiesMatchGNUCoreutilsEdgeCases() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/tac-a.txt": Data("1a\n1b\n".utf8),
            "/tac-b.txt": Data("2a\n2b\n".utf8),
            "/comm-a.txt": Data("b\na\n".utf8),
            "/comm-b.txt": Data("a\nb\n".utf8)
        ])

        let tac = await runCommand("tac", ["/tac-a.txt", "/tac-b.txt"], workspace: workspace)
        let teeStdout = await runCommand("tee", ["/dev/stdout"], standardInput: Data("x".utf8))
        let teeStderr = await runCommand("tee", ["/dev/stderr"], standardInput: Data("x\n".utf8))
        let pasteEmptyDelimiter = await runCommand(
            "paste",
            ["-d", "\\0,", "-", "-", "-"],
            standardInput: Data("a\nb\nc\n".utf8)
        )
        let trDeleteSqueeze = await runCommand("tr", ["-d", "-s", "ab", "X"], standardInput: Data("aabbcc".utf8))
        let trComplement = await runCommand("tr", ["-c", "0-9", "X"], standardInput: Data("a1b2".utf8))
        let commUnsorted = await runCommand("comm", ["/comm-a.txt", "/comm-b.txt"], workspace: workspace)

        XCTAssertEqual(tac.stdout, "1b\n1a\n2b\n2a\n")
        XCTAssertEqual(teeStdout.stdout, "xx")
        XCTAssertEqual(teeStdout.stderr, "")
        XCTAssertEqual(teeStderr.stdout, "x\n")
        XCTAssertEqual(teeStderr.stderr, "x\n")
        XCTAssertEqual(pasteEmptyDelimiter.stdout, "ab,c\n")
        XCTAssertEqual(trDeleteSqueeze.stdout, "cc")
        XCTAssertEqual(trComplement.stdout, "X1X2")
        XCTAssertEqual(commUnsorted.stdout, "\ta\n\t\tb\na\n")
        XCTAssertEqual(
            commUnsorted.stderr,
            "comm: file 1 is not in sorted order\ncomm: input is not in sorted order\n"
        )
        XCTAssertEqual(commUnsorted.exitCode, 1)
    }

    func testSearchJoinDiffNumericAndOctalCommands() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/names.txt": Data("1 apple\n2 banana\n".utf8),
            "/colors.txt": Data("1 red\n2 yellow\n".utf8),
            "/empty-left.csv": Data(",left\nA,aye\n".utf8),
            "/empty-right.csv": Data(",right\nA,aaa\n".utf8),
            "/case-left.txt": Data("A left\n".utf8),
            "/case-right.txt": Data("a right\n".utf8),
            "/alpha.txt": Data("alpha\n".utf8),
            "/beta.txt": Data("beta\nalpha\n".utf8),
            "/old.txt": Data("a\nb\n".utf8),
            "/new.txt": Data("a\nc\n".utf8)
        ])

        let grep = await runCommand("grep", ["-in", "alpha"], standardInput: Data("Alpha\nbeta\n".utf8))
        let grepCount = await runCommand("grep", ["-c", "a"], standardInput: Data("a\nb\na\n".utf8))
        let grepNullList = await runCommand("grep", ["-lZ", "alpha", "/alpha.txt", "/beta.txt"], workspace: workspace)
        let grepNullPrefix = await runCommand("grep", ["-HZ", "alpha", "/alpha.txt", "/beta.txt"], workspace: workspace)
        let join = await runCommand("join", ["/names.txt", "/colors.txt"], workspace: workspace)
        let joinEmptyKey = await runCommand("join", ["-t,", "/empty-left.csv", "/empty-right.csv"], workspace: workspace)
        let joinIgnoreCase = await runCommand("join", ["-i", "/case-left.txt", "/case-right.txt"], workspace: workspace)
        let diff = await runCommand("diff", ["-u", "/old.txt", "/new.txt"], workspace: workspace)
        let simpleDiff = await runCommand("diff", ["/old.txt", "/new.txt"], workspace: workspace)
        let diffMissing = await runCommand("diff", ["/missing.txt", "/new.txt"], workspace: workspace)
        let numfmt = await runCommand("numfmt", ["--to=iec"], standardInput: Data("1024\n1000\n".utf8))
        let od = await runCommand("od", ["-An", "-tx1"], standardInput: Data("AB".utf8))

        XCTAssertEqual(grep.stdout, "1:Alpha\n")
        XCTAssertEqual(grep.exitCode, 0)
        XCTAssertEqual(grepCount.stdout, "2\n")
        XCTAssertEqual(grepNullList.stdout, "/alpha.txt\0/beta.txt\0")
        XCTAssertEqual(grepNullPrefix.stdout, "/alpha.txt\0alpha\n/beta.txt\0alpha\n")
        XCTAssertEqual(join.stdout, "1 apple red\n2 banana yellow\n")
        XCTAssertEqual(joinEmptyKey.stdout, ",left,right\nA,aye,aaa\n")
        XCTAssertEqual(joinIgnoreCase.stdout, "A left right\n")
        XCTAssertEqual(
            diff.stdout,
            """
            --- /old.txt
            +++ /new.txt
            @@ -1,2 +1,2 @@
             a
            -b
            +c

            """
        )
        XCTAssertEqual(diff.exitCode, 1)
        XCTAssertEqual(simpleDiff.stdout, "2c2\n< b\n---\n> c\n")
        XCTAssertEqual(simpleDiff.exitCode, 1)
        XCTAssertEqual(diffMissing.stderr, "diff: /missing.txt: No such file or directory\n")
        XCTAssertEqual(diffMissing.exitCode, 2)
        XCTAssertEqual(numfmt.stdout, "1.0K\n1000\n")
        XCTAssertEqual(od.stdout, " 41 42\n")
    }

    func testFileAndStatMatchGNUObservableFormats() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/ascii.txt": Data("hello\n".utf8),
            "/utf8.txt": Data([0x68, 0xc3, 0xa9, 0x0a]),
            "/empty": Data(),
            "/binary": Data([0xff]),
            "/bytes.txt": Data("abc".utf8)
        ])

        let ascii = await runCommand("file", ["-b", "ascii.txt"], workspace: workspace)
        let asciiMime = await runCommand("file", ["-i", "ascii.txt"], workspace: workspace)
        let utf8MimeType = await runCommand("file", ["--mime-type", "utf8.txt"], workspace: workspace)
        let empty = await runCommand("file", ["empty"], workspace: workspace)
        let binary = await runCommand("file", ["-b", "binary"], workspace: workspace)
        let missing = await runCommand("file", ["missing"], workspace: workspace)
        let statFormat = await runCommand("stat", ["-c", "%n\\n", "bytes.txt"], workspace: workspace)
        let statPrintfNewline = await runCommand("stat", ["--printf", "%n\\n", "bytes.txt"], workspace: workspace)
        let statPrintfNoNewline = await runCommand("stat", ["--printf", "%n", "bytes.txt"], workspace: workspace)

        XCTAssertEqual(ascii.stdout, "ASCII text\n")
        XCTAssertEqual(asciiMime.stdout, "ascii.txt: text/plain; charset=us-ascii\n")
        XCTAssertEqual(utf8MimeType.stdout, "utf8.txt: text/plain\n")
        XCTAssertEqual(empty.stdout, "empty: empty\n")
        XCTAssertEqual(binary.stdout, "very short file (no magic)\n")
        XCTAssertEqual(missing.stdout, "missing: cannot open `missing' (No such file or directory)\n")
        XCTAssertEqual(missing.stderr, "")
        XCTAssertEqual(missing.exitCode, 0)
        XCTAssertEqual(statFormat.stdout, "bytes.txt\\n\n")
        XCTAssertEqual(statPrintfNewline.stdout, "bytes.txt\n")
        XCTAssertEqual(statPrintfNoNewline.stdout, "bytes.txt")
    }

    func testPrintfMatchesGNUIntegerConversionsAndDiagnostics() async throws {
        let numeric = await runCommand("printf", ["%x %X %o %u\n", "31", "31", "8", "-1"])
        let quotedCharacter = await runCommand("printf", ["%d %x\n", "'A", "\"A"])
        let invalid = await runCommand("printf", ["%d|%x\n", "123abc", "08"])

        XCTAssertEqual(numeric.stdout, "1f 1F 10 18446744073709551615\n")
        XCTAssertEqual(numeric.stderr, "")
        XCTAssertEqual(numeric.exitCode, 0)
        XCTAssertEqual(quotedCharacter.stdout, "65 41\n")
        XCTAssertEqual(invalid.stdout, "123|0\n")
        XCTAssertEqual(
            invalid.stderr,
            "printf: \u{2018}123abc\u{2019}: value not completely converted\nprintf: \u{2018}08\u{2019}: value not completely converted\n"
        )
        XCTAssertEqual(invalid.exitCode, 1)
    }

    func testDuUsesCallerVisiblePathsInOutput() async throws {
        let workspace = TextCommandWorkspace(files: [
            "/bytes.txt": Data("abc".utf8)
        ])

        let result = await runCommand("du", ["-b", "bytes.txt"], workspace: workspace)

        XCTAssertEqual(result.stdout, "3\tbytes.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testDateSupportsGNUDateSelectionAndISOFormats() async throws {
        let formatted = await runCommand(
            "date",
            ["-u", "-d", "@0", "+%F %T %z %:z %e %D %j %u %w %y"]
        )
        let isoShort = await runCommand("date", ["-u", "-d", "@0", "-Iseconds"])
        let isoLong = await runCommand("date", ["--utc", "--date=@0", "--iso-8601=ns"])
        let rfcSeconds = await runCommand("date", ["-u", "--date", "@0", "--rfc-3339=seconds"])
        let rfcNanoseconds = await runCommand("date", ["-u", "-d@0", "--rfc-3339=ns"])
        let zoneTokens = await runCommand("date", ["-u", "-d", "@0", "+%Z %::z %:::z"])
        let invalidDate = await runCommand("date", ["-d", "nope"])

        XCTAssertEqual(formatted.stdout, "1970-01-01 00:00:00 +0000 +00:00  1 01/01/70 001 4 4 70\n")
        XCTAssertEqual(isoShort.stdout, "1970-01-01T00:00:00+00:00\n")
        XCTAssertEqual(isoLong.stdout, "1970-01-01T00:00:00,000000000+00:00\n")
        XCTAssertEqual(rfcSeconds.stdout, "1970-01-01 00:00:00+00:00\n")
        XCTAssertEqual(rfcNanoseconds.stdout, "1970-01-01 00:00:00.000000000+00:00\n")
        XCTAssertEqual(zoneTokens.stdout, "UTC +00:00:00 +00\n")
        XCTAssertEqual(invalidDate.stdout, "")
        XCTAssertEqual(invalidDate.stderr, "date: invalid date \u{2018}nope\u{2019}\n")
        XCTAssertEqual(invalidDate.exitCode, 1)
    }

    func testNumfmtMatchesGNUFieldWhitespaceAndInvalidNumber() async throws {
        let field = await runCommand(
            "numfmt",
            ["--field=2", "--to=si"],
            standardInput: Data("aa 1500 zz\n".utf8)
        )
        let invalid = await runCommand("numfmt", ["--to=si"], standardInput: Data("abc\n".utf8))
        let invalidField = await runCommand(
            "numfmt",
            ["--field=2", "--to=si"],
            standardInput: Data("aa abc zz\n".utf8)
        )

        XCTAssertEqual(field.stdout, "aa 1.5K zz\n")
        XCTAssertEqual(field.stderr, "")
        XCTAssertEqual(field.exitCode, 0)
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertEqual(invalid.stderr, "numfmt: invalid number: \u{2018}abc\u{2019}\n")
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertEqual(invalidField.stdout, "aa ")
        XCTAssertEqual(invalidField.stderr, "numfmt: invalid number: \u{2018}abc\u{2019}\n")
        XCTAssertEqual(invalidField.exitCode, 2)
    }

    func testSeqMatchesGNUCoreutilsNumericFormattingAndErrors() async throws {
        let one = await runCommand("seq", ["3"])
        let descendingWithoutStep = await runCommand("seq", ["3", "1"])
        let descending = await runCommand("seq", ["3", "-1", "1"])
        let decimal = await runCommand("seq", ["0", ".1", ".3"])
        let decimalToInteger = await runCommand("seq", [".8", ".1", "1"])
        let separator = await runCommand("seq", ["-s,", "1", "3"])
        let emptySeparator = await runCommand("seq", ["-s", "", "1", "3"])
        let format = await runCommand("seq", ["-f", "item:%04.1f", "1", "2"])
        let formatSuffix = await runCommand("seq", ["-f", "x%g!", "1", "3"])
        let equalWidth = await runCommand("seq", ["-w", "8", "10"])
        let equalWidthDecimal = await runCommand("seq", ["-w", "0", ".5", "1"])
        let equalWidthNegative = await runCommand("seq", ["-w", "-2", "2"])
        let zeroIncrement = await runCommand("seq", ["1", "0", "3"])
        let extraOperand = await runCommand("seq", ["1", "2", "3", "4"])
        let badOperand = await runCommand("seq", ["nope"])
        let formatEqualWidth = await runCommand("seq", ["-w", "-f", "%g", "1", "3"])
        let help = await runCommand("seq", ["--help"])
        let version = await runCommand("seq", ["--version"])
        let overFormerGuard = await runCommand("seq", ["1", "100001"])

        XCTAssertEqual(one.stdout, "1\n2\n3\n")
        XCTAssertEqual(descendingWithoutStep.stdout, "")
        XCTAssertEqual(descending.stdout, "3\n2\n1\n")
        XCTAssertEqual(decimal.stdout, "0.0\n0.1\n0.2\n0.3\n")
        XCTAssertEqual(decimalToInteger.stdout, "0.8\n0.9\n1.0\n")
        XCTAssertEqual(separator.stdout, "1,2,3\n")
        XCTAssertEqual(emptySeparator.stdout, "123\n")
        XCTAssertEqual(format.stdout, "item:01.0\nitem:02.0\n")
        XCTAssertEqual(formatSuffix.stdout, "x1!\nx2!\nx3!\n")
        XCTAssertEqual(equalWidth.stdout, "08\n09\n10\n")
        XCTAssertEqual(equalWidthDecimal.stdout, "0.0\n0.5\n1.0\n")
        XCTAssertEqual(equalWidthNegative.stdout, "-2\n-1\n00\n01\n02\n")

        XCTAssertEqual(zeroIncrement.stdout, "")
        XCTAssertEqual(zeroIncrement.stderr, "seq: invalid Zero increment value: \u{2018}0\u{2019}\nTry 'seq --help' for more information.\n")
        XCTAssertEqual(zeroIncrement.exitCode, 1)
        XCTAssertEqual(extraOperand.stderr, "seq: extra operand \u{2018}4\u{2019}\nTry 'seq --help' for more information.\n")
        XCTAssertEqual(extraOperand.exitCode, 1)
        XCTAssertEqual(badOperand.stderr, "seq: invalid floating point argument: \u{2018}nope\u{2019}\nTry 'seq --help' for more information.\n")
        XCTAssertEqual(badOperand.exitCode, 1)
        XCTAssertEqual(formatEqualWidth.stderr, "seq: format string may not be specified when printing equal width strings\nTry 'seq --help' for more information.\n")
        XCTAssertEqual(formatEqualWidth.exitCode, 1)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: seq"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("seq (GNU coreutils) 9.1"))
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertTrue(overFormerGuard.stdout.hasSuffix("100000\n100001\n"))
        XCTAssertEqual(overFormerGuard.exitCode, 0)
    }

    func testOdMatchesGNUCoreutilsIntegerFormatOutput() async throws {
        let tx1c = await runCommand("od", ["-An", "-tx1c"], standardInput: Data("A\n".utf8))
        let defaultOctal = await runCommand("od", [], standardInput: Data("abc".utf8))
        let decimalAddress = await runCommand("od", ["-Ad", "-tx1"], standardInput: Data("ABCD".utf8))
        let hexAddress = await runCommand("od", ["-Ax", "-tx1"], standardInput: Data("ABCD".utf8))
        let skipLimit = await runCommand("od", ["-An", "-tx1", "-j1", "-N3"], standardInput: Data("abcdef".utf8))
        let width = await runCommand("od", ["-An", "-tx1", "-w4"], standardInput: Data("abcdef".utf8))
        let optionalWidth = await runCommand("od", ["-An", "-tx1", "-w"], standardInput: Data("abcdef".utf8))
        let oldByteOctal = await runCommand("od", ["-An", "-b"], standardInput: Data("AB".utf8))
        let oldChar = await runCommand("od", ["-An", "-c"], standardInput: Data("A\n".utf8))
        let oldUnsignedDecimal = await runCommand("od", ["-An", "-d"], standardInput: Data("ABCD".utf8))
        let oldOctal = await runCommand("od", ["-An", "-o"], standardInput: Data("ABCD".utf8))
        let oldHex = await runCommand("od", ["-An", "-x"], standardInput: Data("ABCD".utf8))
        let unsignedByte = await runCommand("od", ["-An", "-tu1"], standardInput: Data("ABC".utf8))
        let signedByte = await runCommand("od", ["-An", "-td1"], standardInput: Data([0xff, 0x80, 0x01]))
        let hexTwo = await runCommand("od", ["-An", "-tx2"], standardInput: Data("ABCD".utf8))
        let hexFour = await runCommand("od", ["-An", "-tx4"], standardInput: Data("ABCD".utf8))
        let hexTrailer = await runCommand("od", ["-An", "-tx1z"], standardInput: Data("A\nB".utf8))
        let multiFormat = await runCommand("od", ["-An", "-tx1", "-tc"], standardInput: Data("AB".utf8))
        let bigEndian = await runCommand(
            "od",
            ["-An", "-tx2", "--endian=big"],
            standardInput: Data("AB".utf8)
        )
        let duplicate = await runCommand(
            "od",
            ["-An", "-tx1"],
            standardInput: Data(repeating: 0x41, count: 48)
        )

        XCTAssertEqual(tx1c.stdout, "  41  0a\n   A  \\n\n")
        XCTAssertEqual(defaultOctal.stdout, "0000000 061141 000143\n0000003\n")
        XCTAssertEqual(decimalAddress.stdout, "0000000 41 42 43 44\n0000004\n")
        XCTAssertEqual(hexAddress.stdout, "000000 41 42 43 44\n000004\n")
        XCTAssertEqual(skipLimit.stdout, " 62 63 64\n")
        XCTAssertEqual(width.stdout, " 61 62 63 64\n 65 66\n")
        XCTAssertEqual(optionalWidth.stdout, " 61 62 63 64 65 66\n")
        XCTAssertEqual(oldByteOctal.stdout, " 101 102\n")
        XCTAssertEqual(oldChar.stdout, "   A  \\n\n")
        XCTAssertEqual(oldUnsignedDecimal.stdout, " 16961 17475\n")
        XCTAssertEqual(oldOctal.stdout, " 041101 042103\n")
        XCTAssertEqual(oldHex.stdout, " 4241 4443\n")
        XCTAssertEqual(unsignedByte.stdout, "  65  66  67\n")
        XCTAssertEqual(signedByte.stdout, "   -1 -128    1\n")
        XCTAssertEqual(hexTwo.stdout, " 4241 4443\n")
        XCTAssertEqual(hexFour.stdout, " 44434241\n")
        XCTAssertEqual(hexTrailer.stdout, " 41 0a 42                                         >A.B<\n")
        XCTAssertEqual(multiFormat.stdout, "  41  42\n   A   B\n")
        XCTAssertEqual(bigEndian.stdout, " 4142\n")
        XCTAssertEqual(duplicate.stdout, " 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41 41\n*\n")
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
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: standardInput,
                availableCommandNames: registry.commandNames
            )
        )
    }
}

private struct TextCommandWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = TextCommandWorkspaceFileSystem(files: files)
    }
}

private struct TextCommandWorkspaceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
        }
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
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
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "write")
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

import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPDataComparisonMetadataOracleTests: XCTestCase {
    func testDataDumpEncodingAndChecksumCommandsMatchStableGNUOracle() async throws {
        let workspace = WorkerDWorkspace(files: [
            "/abc.txt": Data("abc".utf8),
            "/hello.b64": Data("aGVsbG8=".utf8)
        ])

        let odStdin = await runCommand("od", ["-An", "-tx1c"], workspace: workspace, standardInput: Data("A\n".utf8))
        let odFile = await runCommand("od", ["abc.txt"], workspace: workspace)
        let odSkip = await runCommand("od", ["-j9", "abc.txt"], workspace: workspace)
        let xxdStdin = await runCommand("xxd", ["-p"], standardInput: Data("ABC\n".utf8))
        let xxdFile = await runCommand("xxd", ["abc.txt"], workspace: workspace)
        let xxdMissing = await runCommand("xxd", ["missing"], workspace: workspace)
        let xxdLength = await runCommand("xxd", ["-l", "2", "abc.txt"], workspace: workspace)
        let xxdPlainEmpty = await runCommand("xxd", ["-p"], standardInput: Data())
        let xxdPlainZeroLength = await runCommand("xxd", ["-p", "-l", "0"], standardInput: Data("abc".utf8))
        let xxdReversePlain = await runCommand("xxd", ["-r", "-p"], standardInput: Data("41424344".utf8))
        let xxdPlainAlias = await runCommand("xxd", ["-ps"], standardInput: Data("ABC\n".utf8))
        let xxdUppercase = await runCommand("xxd", ["-p", "-u"], standardInput: Data([0xab, 0xcd]))
        let xxdHelp = await runCommand("xxd", ["-h"])
        let xxdVersion = await runCommand("xxd", ["-v"])
        let base64Stdin = await runCommand("base64", ["-w0"], standardInput: Data("hello".utf8))
        let base64FileDecode = await runCommand("base64", ["-d", "hello.b64"], workspace: workspace)
        let base64Invalid = await runCommand("base64", ["-d"], standardInput: Data("!!!!".utf8))
        let base64Missing = await runCommand("base64", ["missing"], workspace: workspace)
        let base64InvalidWrap = await runCommand("base64", ["-w", "nope", "abc.txt"], workspace: workspace)
        let base64Help = await runCommand("base64", ["--help"])
        let base64Version = await runCommand("base64", ["--version"])
        let md5Stdin = await runCommand("md5sum", [], standardInput: Data("hello".utf8))
        let md5Empty = await runCommand("md5sum", [], standardInput: Data())
        let md5File = await runCommand("md5sum", ["abc.txt"], workspace: workspace)
        let md5Missing = await runCommand("md5sum", ["missing"], workspace: workspace)
        let sha1File = await runCommand("sha1sum", ["abc.txt"], workspace: workspace)
        let sha256File = await runCommand("sha256sum", ["abc.txt"], workspace: workspace)
        let cksumStdin = await runCommand("cksum", [], standardInput: Data("abc".utf8))
        let cksumFile = await runCommand("cksum", ["abc.txt"], workspace: workspace)
        let cksumTag = await runCommand("cksum", ["--tag", "abc.txt"], workspace: workspace)
        let cksumMissing = await runCommand("cksum", ["missing"], workspace: workspace)
        let odInvalidAddress = await runCommand("od", ["-A", "q", "abc.txt"], workspace: workspace)
        let odInvalidReadBytes = await runCommand("od", ["-N", "nope", "abc.txt"], workspace: workspace)
        let odHelp = await runCommand("od", ["--help"])
        let odVersion = await runCommand("od", ["--version"])

        XCTAssertEqual(odStdin.stdout, "  41  0a\n   A  \\n\n")
        XCTAssertEqual(odFile.stdout, "0000000 061141 000143\n0000003\n")
        XCTAssertEqual(odSkip.stdout, "")
        XCTAssertEqual(odSkip.stderr, "od: cannot skip past end of combined input\n")
        XCTAssertEqual(odSkip.exitCode, 1)
        XCTAssertEqual(xxdStdin.stdout, "4142430a\n")
        XCTAssertEqual(xxdFile.stdout, "00000000: 6162 63                                  abc\n")
        XCTAssertEqual(xxdMissing.stdout, "")
        XCTAssertEqual(xxdMissing.stderr, "xxd: missing: No such file or directory\n")
        XCTAssertEqual(xxdMissing.exitCode, 2)
        XCTAssertEqual(xxdLength.stdout, "00000000: 6162                                     ab\n")
        XCTAssertEqual(xxdPlainEmpty.stdout, "")
        XCTAssertEqual(xxdPlainEmpty.exitCode, 0)
        XCTAssertEqual(xxdPlainZeroLength.stdout, "")
        XCTAssertEqual(xxdPlainZeroLength.exitCode, 0)
        XCTAssertEqual(xxdReversePlain.stdoutData, Data("ABCD".utf8))
        XCTAssertEqual(xxdReversePlain.exitCode, 0)
        XCTAssertEqual(xxdPlainAlias.stdout, "4142430a\n")
        XCTAssertEqual(xxdUppercase.stdout, "ABCD\n")
        XCTAssertTrue(xxdHelp.stdout.hasPrefix("Usage: xxd [options] [infile [outfile]]\n"))
        XCTAssertEqual(xxdVersion.stdout, "xxd 2022-01-14 by Juergen Weigert et al.\n")
        XCTAssertEqual(base64Stdin.stdout, "aGVsbG8=")
        XCTAssertEqual(base64FileDecode.stdoutData, Data("hello".utf8))
        XCTAssertEqual(base64Invalid.stdout, "")
        XCTAssertEqual(base64Invalid.stderr, "base64: invalid input\n")
        XCTAssertEqual(base64Invalid.exitCode, 1)
        XCTAssertEqual(base64Missing.stderr, "base64: missing: No such file or directory\n")
        XCTAssertEqual(base64Missing.exitCode, 1)
        XCTAssertEqual(base64InvalidWrap.stderr, "base64: invalid wrap size: \u{2018}nope\u{2019}\n")
        XCTAssertEqual(base64InvalidWrap.exitCode, 1)
        XCTAssertTrue(base64Help.stdout.hasPrefix("Usage: base64 [OPTION]... [FILE]\n"))
        XCTAssertEqual(base64Version.stdout, "base64 (GNU coreutils) 9.1\n")
        XCTAssertEqual(md5Stdin.stdout, "5d41402abc4b2a76b9719d911017c592  -\n")
        XCTAssertEqual(md5Empty.stdout, "d41d8cd98f00b204e9800998ecf8427e  -\n")
        XCTAssertEqual(md5File.stdout, "900150983cd24fb0d6963f7d28e17f72  abc.txt\n")
        XCTAssertEqual(md5Missing.stderr, "md5sum: missing: No such file or directory\n")
        XCTAssertEqual(md5Missing.exitCode, 1)
        XCTAssertEqual(sha1File.stdout, "a9993e364706816aba3e25717850c26c9cd0d89d  abc.txt\n")
        XCTAssertEqual(sha256File.stdout, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt\n")
        XCTAssertEqual(cksumStdin.stdout, "1219131554 3\n")
        XCTAssertEqual(cksumFile.stdout, "1219131554 3 abc.txt\n")
        XCTAssertEqual(cksumTag.stdout, "1219131554 3 abc.txt\n")
        XCTAssertEqual(cksumTag.exitCode, 0)
        XCTAssertEqual(cksumMissing.stderr, "cksum: missing: No such file or directory\n")
        XCTAssertEqual(cksumMissing.exitCode, 1)
        XCTAssertEqual(odInvalidAddress.stderr, "od: invalid output address radix 'q'; it must be one character from [doxn]\n")
        XCTAssertEqual(odInvalidAddress.exitCode, 1)
        XCTAssertEqual(odInvalidReadBytes.stderr, "od: invalid -N argument 'nope'\n")
        XCTAssertEqual(odInvalidReadBytes.exitCode, 1)
        XCTAssertTrue(odHelp.stdout.hasPrefix("Usage: od [OPTION]... [FILE]...\n"))
        XCTAssertEqual(odVersion.stdout, "od (GNU coreutils) 9.1\n")
    }

    func testComparisonCommandsMatchStableGNUOracle() async throws {
        let fixedDate = Date(timeIntervalSince1970: 0)
        let workspace = WorkerDWorkspace(files: [
            "/abc.txt": Data("abc".utf8),
            "/abd.txt": Data("abd".utf8),
            "/longer.txt": Data("abc\nx".utf8),
            "/old.txt": Data("a\nb\n".utf8),
            "/new.txt": Data("a\nc\n".utf8),
            "/one-old.txt": Data("a\n".utf8),
            "/one-new.txt": Data("b\n".utf8),
            "/bin-a": Data([0x61, 0x00, 0x62]),
            "/bin-b": Data([0x61, 0x00, 0x63])
        ], metadata: [
            "/old.txt": WorkerDFileMetadata(modificationDate: fixedDate),
            "/new.txt": WorkerDFileMetadata(modificationDate: fixedDate),
            "/one-old.txt": WorkerDFileMetadata(modificationDate: fixedDate),
            "/one-new.txt": WorkerDFileMetadata(modificationDate: fixedDate)
        ])

        let cmpSame = await runCommand("cmp", ["abc.txt", "abc.txt"], workspace: workspace)
        let cmpDiff = await runCommand("cmp", ["abc.txt", "abd.txt"], workspace: workspace)
        let cmpVerbose = await runCommand("cmp", ["-l", "abc.txt", "abd.txt"], workspace: workspace)
        let cmpVerboseSilent = await runCommand("cmp", ["-l", "-s", "abc.txt", "abd.txt"], workspace: workspace)
        let cmpEOF = await runCommand("cmp", ["abc.txt", "longer.txt"], workspace: workspace)
        let cmpMissing = await runCommand("cmp", ["missing", "abc.txt"], workspace: workspace)
        let cmpBytesLimit = await runCommand("cmp", ["-n", "2", "abc.txt", "abd.txt"], workspace: workspace)
        let cmpIgnoreInitial = await runCommand("cmp", ["-i", "1:1", "abc.txt", "abd.txt"], workspace: workspace)
        let cmpOperandSkips = await runCommand("cmp", ["abc.txt", "abd.txt", "2", "2"], workspace: workspace)
        let cmpDefaultStdin = await runCommand(
            "cmp",
            ["abc.txt"],
            workspace: workspace,
            standardInput: Data("abd".utf8)
        )
        let diffSimple = await runCommand("diff", ["old.txt", "new.txt"], workspace: workspace)
        let diffUnified = await runCommand("diff", ["-u", "old.txt", "new.txt"], workspace: workspace)
        let diffUnifiedSingleLine = await runCommand("diff", ["-u", "one-old.txt", "one-new.txt"], workspace: workspace)
        let diffStdin = await runCommand(
            "diff",
            ["-", "new.txt"],
            workspace: workspace,
            standardInput: Data("a\nb\n".utf8)
        )
        let diffMissing = await runCommand("diff", ["missing", "new.txt"], workspace: workspace)
        let diffBinary = await runCommand("diff", ["bin-a", "bin-b"], workspace: workspace)
        let diffHelp = await runCommand("diff", ["--help"])
        let diffVersion = await runCommand("diff", ["-v"])

        XCTAssertEqual(cmpSame.stdout, "")
        XCTAssertEqual(cmpSame.stderr, "")
        XCTAssertEqual(cmpSame.exitCode, 0)
        XCTAssertEqual(cmpDiff.stdout, "abc.txt abd.txt differ: byte 3, line 1\n")
        XCTAssertEqual(cmpDiff.stderr, "")
        XCTAssertEqual(cmpDiff.exitCode, 1)
        XCTAssertEqual(cmpVerbose.stdout, "3 143 144\n")
        XCTAssertEqual(cmpVerbose.stderr, "")
        XCTAssertEqual(cmpVerbose.exitCode, 1)
        XCTAssertEqual(cmpVerboseSilent.stderr, "cmp: options -l and -s are incompatible\n")
        XCTAssertEqual(cmpVerboseSilent.exitCode, 2)
        XCTAssertEqual(cmpEOF.stdout, "")
        XCTAssertEqual(cmpEOF.stderr, "cmp: EOF on abc.txt after byte 3, in line 1\n")
        XCTAssertEqual(cmpEOF.exitCode, 1)
        XCTAssertEqual(cmpMissing.stderr, "cmp: missing: No such file or directory\n")
        XCTAssertEqual(cmpMissing.exitCode, 2)
        XCTAssertEqual(cmpBytesLimit.stdout, "")
        XCTAssertEqual(cmpBytesLimit.exitCode, 0)
        XCTAssertEqual(cmpIgnoreInitial.stdout, "abc.txt abd.txt differ: byte 2, line 1\n")
        XCTAssertEqual(cmpIgnoreInitial.exitCode, 1)
        XCTAssertEqual(cmpOperandSkips.stdout, "abc.txt abd.txt differ: byte 1, line 1\n")
        XCTAssertEqual(cmpOperandSkips.exitCode, 1)
        XCTAssertEqual(cmpDefaultStdin.stdout, "abc.txt - differ: byte 3, line 1\n")
        XCTAssertEqual(cmpDefaultStdin.stderr, "")
        XCTAssertEqual(cmpDefaultStdin.exitCode, 1)
        XCTAssertEqual(diffSimple.stdout, "2c2\n< b\n---\n> c\n")
        XCTAssertEqual(diffSimple.stderr, "")
        XCTAssertEqual(diffSimple.exitCode, 1)
        XCTAssertEqual(
            diffUnified.stdout,
            """
            --- old.txt\t1970-01-01 00:00:00.000000000 +0000
            +++ new.txt\t1970-01-01 00:00:00.000000000 +0000
            @@ -1,2 +1,2 @@
             a
            -b
            +c

            """
        )
        XCTAssertEqual(diffUnified.exitCode, 1)
        XCTAssertTrue(diffUnifiedSingleLine.stdout.contains("@@ -1 +1 @@\n"))
        XCTAssertEqual(diffUnifiedSingleLine.exitCode, 1)
        XCTAssertEqual(diffStdin.stdout, "2c2\n< b\n---\n> c\n")
        XCTAssertEqual(diffStdin.exitCode, 1)
        XCTAssertEqual(diffMissing.stdout, "")
        XCTAssertEqual(diffMissing.stderr, "diff: missing: No such file or directory\n")
        XCTAssertEqual(diffMissing.exitCode, 2)
        XCTAssertEqual(diffBinary.stdout, "Binary files bin-a and bin-b differ\n")
        XCTAssertEqual(diffBinary.stderr, "")
        XCTAssertEqual(diffBinary.exitCode, 1)
        XCTAssertTrue(diffHelp.stdout.hasPrefix("Usage: diff [OPTION]... FILES\n"))
        XCTAssertEqual(diffHelp.exitCode, 0)
        XCTAssertEqual(diffVersion.stdout, "diff (GNU diffutils) 3.8\n")
        XCTAssertEqual(diffVersion.exitCode, 0)
    }

    func testCmpUsesRangeReadsAndStopsAfterFirstDifference() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/left.bin": Data("abc".utf8) + Data(repeating: 0x78, count: 100_000),
            "/right.bin": Data("abd".utf8) + Data(repeating: 0x78, count: 100_000)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let result = await runCommand("cmp", ["left.bin", "right.bin"], workspace: workspace)

        XCTAssertEqual(result.stdout, "left.bin right.bin differ: byte 3, line 1\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 2)
    }

    func testDiffQuietUsesRangeReadsAndStopsAfterFirstDifference() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/left.bin": Data("a".utf8) + Data(repeating: 0x78, count: 100_000),
            "/right.bin": Data("b".utf8) + Data(repeating: 0x78, count: 100_000)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let result = await runCommand("diff", ["-q", "left.bin", "right.bin"], workspace: workspace)

        XCTAssertEqual(result.stdout, "Files left.bin and right.bin differ\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 2)
    }

    func testDiffMaterializesFileOperandsThroughRangeReads() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/old.txt": Data("a\nb\n".utf8),
            "/new.txt": Data("a\nc\n".utf8)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let result = await runCommand("diff", ["old.txt", "new.txt"], workspace: workspace)

        XCTAssertEqual(result.stdout, "2c2\n< b\n---\n> c\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 0)
    }

    func testMetadataCommandsMatchStableGNUOracle() async throws {
        let fixedDate = Date(timeIntervalSince1970: 0)
        let workspace = WorkerDWorkspace(files: [
            "/abc.txt": Data("abc".utf8),
            "/ascii-nl.txt": Data("hello\n".utf8),
            "/empty": Data(),
            "/file-list.txt": Data("abc.txt\nempty\n".utf8),
            "/onebyte.bin": Data([0xff]),
            "/nul.bin": Data([0x61, 0x00, 0x62])
        ], metadata: [
            "/abc.txt": WorkerDFileMetadata(modificationDate: fixedDate, permissions: 0o640)
        ])

        let fileASCII = await runCommand("file", ["abc.txt"], workspace: workspace)
        let fileBriefASCII = await runCommand("file", ["-b", "abc.txt"], workspace: workspace)
        let fileASCIINewline = await runCommand("file", ["ascii-nl.txt"], workspace: workspace)
        let fileEmpty = await runCommand("file", ["empty"], workspace: workspace)
        let fileBinary = await runCommand("file", ["onebyte.bin"], workspace: workspace)
        let fileNulBinary = await runCommand("file", ["nul.bin"], workspace: workspace)
        let fileNulBinaryBrief = await runCommand("file", ["-b", "nul.bin"], workspace: workspace)
        let fileNulBinaryMime = await runCommand("file", ["-i", "nul.bin"], workspace: workspace)
        let fileMissing = await runCommand("file", ["missing"], workspace: workspace)
        let fileMimeEncoding = await runCommand("file", ["--mime-encoding", "abc.txt"], workspace: workspace)
        let fileSeparator = await runCommand("file", ["-F", " =>", "abc.txt"], workspace: workspace)
        let filePrint0 = await runCommand("file", ["-0", "abc.txt"], workspace: workspace)
        let fileFilesFrom = await runCommand("file", ["-f", "file-list.txt"], workspace: workspace)
        let fileStdin = await runCommand("file", ["-"], workspace: workspace, standardInput: Data("stdin\n".utf8))
        let fileProbeLimit = await runCommand("file", ["-P", "bytes=1", "ascii-nl.txt"], workspace: workspace)
        let fileBadExclude = await runCommand("file", ["-e", "bogus", "abc.txt"], workspace: workspace)
        let fileUnsupportedCompile = await runCommand("file", ["-C"], workspace: workspace)
        let statFormat = await runCommand("stat", ["-c", "%n %s %F", "abc.txt"], workspace: workspace)
        let statPrintf = await runCommand("stat", ["--printf", "%n\\n", "abc.txt"], workspace: workspace)
        let statIdentity = await runCommand("stat", ["--cached=always", "-c", "%u:%U:%g:%G", "abc.txt"], workspace: workspace)
        let statVirtualMetadata = await runCommand("stat", ["-c", "%C:%d:%D:%m:%r:%R:%w:%W", "abc.txt"], workspace: workspace)
        let statVersion = await runCommand("stat", ["--version"], workspace: workspace)
        let statHelp = await runCommand("stat", ["--help"], workspace: workspace)
        let statFileSystem = await runCommand("stat", ["-f", "-c", "%T", "."], workspace: workspace)
        let statTerse = await runCommand("stat", ["-t", "abc.txt"], workspace: workspace)
        let statDefault = await runCommand("stat", ["abc.txt"], workspace: workspace)
        let statMissing = await runCommand("stat", ["-c", "%n", "missing"], workspace: workspace)

        XCTAssertEqual(fileASCII.stdout, "abc.txt: ASCII text, with no line terminators\n")
        XCTAssertEqual(fileBriefASCII.stdout, "ASCII text, with no line terminators\n")
        XCTAssertEqual(fileASCIINewline.stdout, "ascii-nl.txt: ASCII text\n")
        XCTAssertEqual(fileEmpty.stdout, "empty: empty\n")
        XCTAssertEqual(fileBinary.stdout, "onebyte.bin: very short file (no magic)\n")
        XCTAssertEqual(fileNulBinary.stdout, "nul.bin: data\n")
        XCTAssertEqual(fileNulBinaryBrief.stdout, "data\n")
        XCTAssertEqual(fileNulBinaryMime.stdout, "nul.bin: application/octet-stream; charset=binary\n")
        XCTAssertEqual(fileMissing.stdout, "missing: cannot open `missing' (No such file or directory)\n")
        XCTAssertEqual(fileMissing.stderr, "")
        XCTAssertEqual(fileMissing.exitCode, 0)
        XCTAssertEqual(fileMimeEncoding.stdout, "abc.txt: us-ascii\n")
        XCTAssertEqual(fileSeparator.stdout, "abc.txt => ASCII text, with no line terminators\n")
        XCTAssertEqual(filePrint0.stdout, "abc.txt\0: ASCII text, with no line terminators\0\n")
        XCTAssertEqual(fileFilesFrom.stdout, "abc.txt: ASCII text, with no line terminators\nempty: empty\n")
        XCTAssertEqual(fileStdin.stdout, "-: ASCII text\n")
        XCTAssertEqual(fileProbeLimit.stdout, "ascii-nl.txt: ASCII text, with no line terminators\n")
        XCTAssertEqual(fileBadExclude.stderr, "file: invalid exclude type \u{2018}bogus\u{2019}\n")
        XCTAssertEqual(fileBadExclude.exitCode, 1)
        XCTAssertEqual(fileUnsupportedCompile.stderr, "file: -C is not supported in the MSP virtual classifier\n")
        XCTAssertEqual(fileUnsupportedCompile.exitCode, 1)
        XCTAssertEqual(statFormat.stdout, "abc.txt 3 regular file\n")
        XCTAssertEqual(statPrintf.stdout, "abc.txt\n")
        XCTAssertEqual(statIdentity.stdout, "65534:nobody:65534:nogroup\n")
        XCTAssertEqual(statVirtualMetadata.stdout, "?:0:0:/:0:0:-:-1\n")
        XCTAssertEqual(statVersion.stdout, "stat (GNU coreutils) 9.1\n")
        XCTAssertTrue(statHelp.stdout.hasPrefix("Usage: stat [OPTION]... FILE...\n"))
        XCTAssertEqual(statFileSystem.stdout, "ext2/ext3\n")
        XCTAssertTrue(statTerse.stdout.hasPrefix("abc.txt 3 "))
        XCTAssertEqual(statTerse.stderr, "")
        XCTAssertEqual(statTerse.exitCode, 0)
        XCTAssertEqual(statDefault.exitCode, 0)
        XCTAssertTrue(statDefault.stdout.contains("  File: abc.txt\n"))
        XCTAssertTrue(statDefault.stdout.contains("  Size: 3        \tBlocks: 1          IO Block: 4096   regular file\n"))
        XCTAssertTrue(statDefault.stdout.contains("Access: (0640/-rw-r-----)  Uid: (65534/  nobody)   Gid: (65534/ nogroup)\n"))
        XCTAssertTrue(statDefault.stdout.contains("Modify: 1970-01-01 00:00:00.000000000 +0000\n"))
        XCTAssertTrue(statDefault.stdout.contains(" Birth: -\n"))
        XCTAssertFalse(statDefault.stdout.contains("/Volumes/"))
        XCTAssertEqual(statMissing.stdout, "")
        XCTAssertEqual(statMissing.stderr, "stat: cannot statx 'missing': No such file or directory\n")
        XCTAssertEqual(statMissing.exitCode, 1)
    }

    func testFileUsesBoundedRangeProbeInsteadOfFullRead() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/large.txt": Data(repeating: UInt8(ascii: "a"), count: 100_000)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let result = await runCommand("file", ["large.txt"], workspace: workspace)

        XCTAssertEqual(result.stdout, "large.txt: ASCII text, with no line terminators\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 1)
    }

    func testOdReadBytesAndSkipUseBoundedRangeRead() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/bytes.bin": Data("0123456789".utf8)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let result = await runCommand("od", ["-An", "-tx1", "-j", "2", "-N", "3", "bytes.bin"], workspace: workspace)

        XCTAssertEqual(result.stdout, " 32 33 34\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 1)
    }

    func testChecksumCommandsUseRangeReadsForFileOperands() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/abc.txt": Data("abc".utf8)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let cksum = await runCommand("cksum", ["abc.txt"], workspace: workspace)
        let md5 = await runCommand("md5sum", ["abc.txt"], workspace: workspace)
        let sha256 = await runCommand("sha256sum", ["abc.txt"], workspace: workspace)

        XCTAssertEqual(cksum.stdout, "1219131554 3 abc.txt\n")
        XCTAssertEqual(md5.stdout, "900150983cd24fb0d6963f7d28e17f72  abc.txt\n")
        XCTAssertEqual(sha256.stdout, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt\n")
        XCTAssertEqual(cksum.exitCode, 0)
        XCTAssertEqual(md5.exitCode, 0)
        XCTAssertEqual(sha256.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 3)
    }

    func testSumSupportsSysvDashOperandAndRangeReads() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/abc.txt": Data("abc".utf8)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let bsdMixedStdin = await runCommand(
            "sum",
            ["abc.txt", "-"],
            workspace: workspace,
            standardInput: Data("de".utf8)
        )
        let sysvLong = await runCommand("sum", ["--sysv", "abc.txt"], workspace: workspace)

        XCTAssertEqual(bsdMixedStdin.stdout, "16556     1 abc.txt\n00151     1 -\n")
        XCTAssertEqual(bsdMixedStdin.stderr, "")
        XCTAssertEqual(bsdMixedStdin.exitCode, 0)
        XCTAssertEqual(sysvLong.stdout, "294 1 abc.txt\n")
        XCTAssertEqual(sysvLong.stderr, "")
        XCTAssertEqual(sysvLong.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThanOrEqual(fileSystem.rangeReadCallCount, 2)
    }

    func testBase64UsesRangeReadsForFileOperands() async throws {
        let fileSystem = RangeOnlyComparisonFileSystem(files: [
            "/hello.txt": Data("hello".utf8),
            "/hello.b64": Data("aGVsbG8=".utf8)
        ])
        let workspace = WorkerDInjectedWorkspace(fileSystem: fileSystem)

        let encoded = await runCommand("base64", ["-w0", "hello.txt"], workspace: workspace)
        let decoded = await runCommand("base64", ["-d", "hello.b64"], workspace: workspace)

        XCTAssertEqual(encoded.stdout, "aGVsbG8=")
        XCTAssertEqual(encoded.stderr, "")
        XCTAssertEqual(encoded.exitCode, 0)
        XCTAssertEqual(decoded.stdoutData, Data("hello".utf8))
        XCTAssertEqual(decoded.stderr, "")
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.rangeReadCallCount, 2)
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

private struct WorkerDWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data], metadata: [String: WorkerDFileMetadata] = [:]) {
        self.fileSystem = WorkerDWorkspaceFileSystem(files: files, metadata: metadata)
    }
}

private struct WorkerDInjectedWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem
}

private struct WorkerDFileMetadata: Sendable {
    var modificationDate: Date?
    var permissions: UInt16?

    init(modificationDate: Date? = nil, permissions: UInt16? = nil) {
        self.modificationDate = modificationDate
        self.permissions = permissions
    }
}

private struct WorkerDWorkspaceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    var metadata: [String: WorkerDFileMetadata]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            let metadata = metadata[virtualPath]
            return MSPFileInfo(
                virtualPath: virtualPath,
                type: .regularFile,
                size: Int64(data.count),
                modificationDate: metadata?.modificationDate,
                permissions: metadata?.permissions
            )
        }
        if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
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
            if virtualPath == "/" || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
                throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
            }
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

private final class RangeOnlyComparisonFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private let files: [String: Data]
    private(set) var readFileCallCount = 0
    private(set) var rangeReadCallCount = 0

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        readFileCallCount += 1
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "full-read-forbidden")
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        rangeReadCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
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

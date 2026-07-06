import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPWorkerFIdentityEncodingDigestTests: XCTestCase {
    func testIdentityCommandsUseVirtualLinuxProfile() async throws {
        let unameAll = try await MSPUnameCommand().run(
            invocation: MSPCommandInvocation(name: "uname", arguments: ["-a"]),
            context: MSPCommandContext()
        )
        let whoami = try await MSPWhoamiCommand().run(
            invocation: MSPCommandInvocation(name: "whoami"),
            context: MSPCommandContext(environment: ["USER": "custom"])
        )
        let idDefault = try await MSPIdCommand().run(
            invocation: MSPCommandInvocation(name: "id"),
            context: MSPCommandContext()
        )
        let hostnameShort = try await MSPHostnameCommand().run(
            invocation: MSPCommandInvocation(name: "hostname", arguments: ["-s"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(
            unameAll.stdout,
            "Linux happy-swan-1.localdomain 6.1.0-48-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.172-1 (2026-05-15) x86_64 GNU/Linux\n"
        )
        XCTAssertEqual(whoami.stdout, "nobody\n")
        XCTAssertEqual(idDefault.stdout, "uid=65534(nobody) gid=65534(nogroup) groups=65534(nogroup)\n")
        XCTAssertEqual(hostnameShort.stdout, "happy-swan-1\n")
    }

    func testIdentityCommandsExposeGNUHelpVersionAndVirtualLookupBoundaries() async throws {
        let groupsHelp = try await MSPGroupsCommand().run(
            invocation: MSPCommandInvocation(name: "groups", arguments: ["--help"]),
            context: MSPCommandContext()
        )
        let groupsVersion = try await MSPGroupsCommand().run(
            invocation: MSPCommandInvocation(name: "groups", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let numericGroups = try await MSPGroupsCommand().run(
            invocation: MSPCommandInvocation(name: "groups", arguments: ["0", "65534"]),
            context: MSPCommandContext()
        )
        let idVersion = try await MSPIdCommand().run(
            invocation: MSPCommandInvocation(name: "id", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let idNumericRoot = try await MSPIdCommand().run(
            invocation: MSPCommandInvocation(name: "id", arguments: ["-un", "0"]),
            context: MSPCommandContext()
        )
        let unameVersion = try await MSPUnameCommand().run(
            invocation: MSPCommandInvocation(name: "uname", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let whoamiVersion = try await MSPWhoamiCommand().run(
            invocation: MSPCommandInvocation(name: "whoami", arguments: ["--version"]),
            context: MSPCommandContext()
        )

        XCTAssertTrue(groupsHelp.stdout.hasPrefix("Usage: groups [OPTION]... [USERNAME]...\n"))
        XCTAssertEqual(groupsVersion.stdout, "groups (GNU coreutils) 9.1\n")
        XCTAssertEqual(numericGroups.stdout, "")
        XCTAssertEqual(
            numericGroups.stderr,
            "groups: \u{2018}0\u{2019}: no such user\ngroups: \u{2018}65534\u{2019}: no such user\n"
        )
        XCTAssertEqual(numericGroups.exitCode, 1)
        XCTAssertEqual(idVersion.stdout, "id (GNU coreutils) 9.1\n")
        XCTAssertEqual(idNumericRoot.stdout, "root\n")
        XCTAssertEqual(unameVersion.stdout, "uname (GNU coreutils) 9.1\n")
        XCTAssertEqual(whoamiVersion.stdout, "whoami (GNU coreutils) 9.1\n")
    }

    func testBase32AndBasencMatchCore100OracleBytes() async throws {
        let base32Encode = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32"),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let base32Decode = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-d"]),
            context: MSPCommandContext(standardInput: Data("NBSWY3DP".utf8))
        )
        let base32IgnoreGarbage = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-d", "-i"]),
            context: MSPCommandContext(standardInput: Data("NB SWY3DP!!".utf8))
        )
        let basencURL = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base64url"]),
            context: MSPCommandContext(standardInput: Data("hello?".utf8))
        )
        let basencBase16 = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base16"]),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let basencBase2 = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base2msbf"]),
            context: MSPCommandContext(standardInput: Data([0x80]))
        )
        let base32Version = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let basencVersion = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--version"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(base32Encode.stdout, "NBSWY3DP\n")
        XCTAssertEqual(base32Decode.stdoutData, Data("hello".utf8))
        XCTAssertEqual(base32IgnoreGarbage.stdoutData, Data("hello".utf8))
        XCTAssertEqual(basencURL.stdout, "aGVsbG8_\n")
        XCTAssertEqual(basencBase16.stdout, "68656C6C6F\n")
        XCTAssertEqual(basencBase2.stdout, "10000000\n")
        XCTAssertEqual(base32Version.stdout, "base32 (GNU coreutils) 9.1\n")
        XCTAssertEqual(basencVersion.stdout, "basenc (GNU coreutils) 9.1\n")
    }

    func testBase32AndBasencFileOperandsUseChunkedRangeReads() async throws {
        let data = Data((0..<(32 * 1024 + 7)).map { UInt8($0 % 251) })
        let expectedBase32 = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-w0"]),
            context: MSPCommandContext(standardInput: data)
        )
        let encodeFileSystem = WorkerFEncodingWorkspaceFileSystem(files: [
            "/large.bin": data
        ])
        let encode = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-w0", "large.bin"]),
            context: MSPCommandContext(workspace: WorkerFEncodingWorkspace(fileSystem: encodeFileSystem))
        )
        let decodeFileSystem = WorkerFEncodingWorkspaceFileSystem(files: [
            "/large.b32": Data(expectedBase32.stdout.utf8)
        ])
        let decode = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-d", "large.b32"]),
            context: MSPCommandContext(workspace: WorkerFEncodingWorkspace(fileSystem: decodeFileSystem))
        )

        XCTAssertEqual(encode.stdout, expectedBase32.stdout)
        XCTAssertEqual(decode.stdoutData, data)
        XCTAssertEqual(encodeFileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(encodeFileSystem.rangeReadCallCount, 1)
        XCTAssertEqual(decodeFileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(decodeFileSystem.rangeReadCallCount, 1)
    }

    func testBase32DiagnosticsHelpAndWrappingStayGNUShaped() async throws {
        let invalidDecode = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-d"]),
            context: MSPCommandContext(standardInput: Data("????".utf8))
        )
        let wrapped = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["-w4"]),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let invalidWrap = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["--wrap=nope"]),
            context: MSPCommandContext()
        )
        let extraOperand = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["a", "b"]),
            context: MSPCommandContext()
        )
        let help = try await MSPBase32Command().run(
            invocation: MSPCommandInvocation(name: "base32", arguments: ["--help"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(invalidDecode.stdout, "")
        XCTAssertEqual(invalidDecode.stderr, "base32: invalid input\n")
        XCTAssertEqual(invalidDecode.exitCode, 1)
        XCTAssertEqual(wrapped.stdout, "NBSW\nY3DP\n")
        XCTAssertEqual(invalidWrap.stderr, "base32: invalid wrap size: \u{2018}nope\u{2019}\n")
        XCTAssertEqual(invalidWrap.exitCode, 1)
        XCTAssertEqual(extraOperand.stderr, "base32: extra operand \u{2018}b\u{2019}\nTry 'base32 --help' for more information.\n")
        XCTAssertEqual(extraOperand.exitCode, 1)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: base32 [OPTION]... [FILE]\n"))
    }

    func testBasencSelectorMatrixDecodeAndMissingSelectorDiagnostics() async throws {
        let base32Hex = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base32hex"]),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let base32HexDecode = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base32hex", "-d"]),
            context: MSPCommandContext(standardInput: Data("D1IMOR3F".utf8))
        )
        let base2LSBF = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base2lsbf"]),
            context: MSPCommandContext(standardInput: Data([0x80]))
        )
        let base2LSBFDecode = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base2lsbf", "-d"]),
            context: MSPCommandContext(standardInput: Data("00000001".utf8))
        )
        let base64URLDecode = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc", arguments: ["--base64url", "-d"]),
            context: MSPCommandContext(standardInput: Data("aGVsbG8_".utf8))
        )
        let missingSelector = try await MSPBasencCommand().run(
            invocation: MSPCommandInvocation(name: "basenc"),
            context: MSPCommandContext()
        )

        XCTAssertEqual(base32Hex.stdout, "D1IMOR3F\n")
        XCTAssertEqual(base32HexDecode.stdoutData, Data("hello".utf8))
        XCTAssertEqual(base2LSBF.stdout, "00000001\n")
        XCTAssertEqual(base2LSBFDecode.stdoutData, Data([0x80]))
        XCTAssertEqual(base64URLDecode.stdoutData, Data("hello?".utf8))
        XCTAssertEqual(missingSelector.stderr, "basenc: missing encoding type\nTry 'basenc --help' for more information.\n")
        XCTAssertEqual(missingSelector.exitCode, 1)
    }

    func testSha512sumAndB2sumMatchCore100OracleBytes() async throws {
        let workspace = WorkerFEncodingWorkspace(files: [
            "/in.txt": Data("hello".utf8)
        ])
        let sha512 = try await MSPDigestCommand(name: "sha512sum", algorithm: .sha512).run(
            invocation: MSPCommandInvocation(name: "sha512sum"),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let b2 = try await MSPB2SumCommand().run(
            invocation: MSPCommandInvocation(name: "b2sum"),
            context: MSPCommandContext(standardInput: Data("hello".utf8))
        )
        let b2Length = try await MSPB2SumCommand().run(
            invocation: MSPCommandInvocation(name: "b2sum", arguments: ["-l", "256", "in.txt"]),
            context: MSPCommandContext(workspace: workspace)
        )
        let sha512Help = try await MSPDigestCommand(name: "sha512sum", algorithm: .sha512).run(
            invocation: MSPCommandInvocation(name: "sha512sum", arguments: ["--help"]),
            context: MSPCommandContext()
        )
        let sha512Version = try await MSPDigestCommand(name: "sha512sum", algorithm: .sha512).run(
            invocation: MSPCommandInvocation(name: "sha512sum", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let b2Help = try await MSPB2SumCommand().run(
            invocation: MSPCommandInvocation(name: "b2sum", arguments: ["--help"]),
            context: MSPCommandContext()
        )
        let b2Version = try await MSPB2SumCommand().run(
            invocation: MSPCommandInvocation(name: "b2sum", arguments: ["--version"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(
            sha512.stdout,
            "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043  -\n"
        )
        XCTAssertEqual(
            b2.stdout,
            "e4cfa39a3d37be31c59609e807970799caa68a19bfaa15135f165085e01d41a65ba1e1b146aeb6bd0092b49eac214c103ccfa3a365954bbbe52f74a2b3620c94  -\n"
        )
        XCTAssertEqual(
            b2Length.stdout,
            "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf  in.txt\n"
        )
        XCTAssertTrue(sha512Help.stdout.hasPrefix("Usage: sha512sum [OPTION]... [FILE]...\n"))
        XCTAssertEqual(sha512Version.stdout, "sha512sum (GNU coreutils) 9.1\n")
        XCTAssertTrue(b2Help.stdout.hasPrefix("Usage: b2sum [OPTION]... [FILE]...\n"))
        XCTAssertEqual(b2Version.stdout, "b2sum (GNU coreutils) 9.1\n")
    }

    func testDigestSharedGNUCheckAndTaggedOutputOptions() async throws {
        let workspace = WorkerFEncodingWorkspace(files: [
            "/abc.txt": Data("abc".utf8),
            "/ok.md5": Data("900150983cd24fb0d6963f7d28e17f72  abc.txt\n".utf8),
            "/bad.md5": Data("00000000000000000000000000000000  abc.txt\n".utf8),
            "/mixed.md5": Data("bad line\n900150983cd24fb0d6963f7d28e17f72  abc.txt\n".utf8),
            "/missing.md5": Data("900150983cd24fb0d6963f7d28e17f72  missing.txt\n".utf8),
            "/tagged.md5": Data("MD5 (abc.txt) = 900150983cd24fb0d6963f7d28e17f72\n".utf8)
        ])

        let tagged = try await md5sum(["--tag", "abc.txt"], workspace: workspace)
        let zero = try await md5sum(["--zero", "abc.txt"], workspace: workspace)
        let taggedZero = try await md5sum(["--tag", "--zero", "abc.txt"], workspace: workspace)
        let quietOK = try await md5sum(["-c", "--quiet", "ok.md5"], workspace: workspace)
        let badQuiet = try await md5sum(["-c", "--quiet", "bad.md5"], workspace: workspace)
        let warn = try await md5sum(["-c", "--warn", "mixed.md5"], workspace: workspace)
        let strict = try await md5sum(["-c", "--strict", "mixed.md5"], workspace: workspace)
        let ignoreMissing = try await md5sum(["-c", "--ignore-missing", "missing.md5"], workspace: workspace)
        let statusBad = try await md5sum(["-c", "--status", "bad.md5"], workspace: workspace)
        let taggedCheck = try await md5sum(["-c", "tagged.md5"], workspace: workspace)
        let md5Help = try await md5sum(["--help"], workspace: workspace)
        let md5Version = try await md5sum(["--version"], workspace: workspace)
        let sha1Version = try await MSPDigestCommand(name: "sha1sum", algorithm: .sha1).run(
            invocation: MSPCommandInvocation(name: "sha1sum", arguments: ["--version"]),
            context: MSPCommandContext()
        )
        let sha256Version = try await MSPDigestCommand(name: "sha256sum", algorithm: .sha256).run(
            invocation: MSPCommandInvocation(name: "sha256sum", arguments: ["--version"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(tagged.stdout, "MD5 (abc.txt) = 900150983cd24fb0d6963f7d28e17f72\n")
        XCTAssertEqual(zero.stdoutData, Data("900150983cd24fb0d6963f7d28e17f72  abc.txt".utf8) + Data([0]))
        XCTAssertEqual(taggedZero.stdoutData, Data("MD5 (abc.txt) = 900150983cd24fb0d6963f7d28e17f72".utf8) + Data([0]))
        XCTAssertEqual(quietOK.stdout, "")
        XCTAssertEqual(quietOK.stderr, "")
        XCTAssertEqual(quietOK.exitCode, 0)
        XCTAssertEqual(badQuiet.stdout, "abc.txt: FAILED\n")
        XCTAssertEqual(badQuiet.stderr, "md5sum: WARNING: 1 computed checksum did NOT match\n")
        XCTAssertEqual(badQuiet.exitCode, 1)
        XCTAssertEqual(warn.stdout, "abc.txt: OK\n")
        XCTAssertEqual(
            warn.stderr,
            "md5sum: mixed.md5: 1: improperly formatted MD5 checksum line\n"
                + "md5sum: WARNING: 1 line is improperly formatted\n"
        )
        XCTAssertEqual(warn.exitCode, 0)
        XCTAssertEqual(strict.stdout, "abc.txt: OK\n")
        XCTAssertEqual(strict.stderr, "md5sum: WARNING: 1 line is improperly formatted\n")
        XCTAssertEqual(strict.exitCode, 1)
        XCTAssertEqual(ignoreMissing.stdout, "")
        XCTAssertEqual(ignoreMissing.stderr, "md5sum: missing.md5: no file was verified\n")
        XCTAssertEqual(ignoreMissing.exitCode, 1)
        XCTAssertEqual(statusBad.stdout, "")
        XCTAssertEqual(statusBad.stderr, "")
        XCTAssertEqual(statusBad.exitCode, 1)
        XCTAssertEqual(taggedCheck.stdout, "abc.txt: OK\n")
        XCTAssertEqual(taggedCheck.stderr, "")
        XCTAssertEqual(taggedCheck.exitCode, 0)
        XCTAssertTrue(md5Help.stdout.hasPrefix("Usage: md5sum [OPTION]... [FILE]...\n"))
        XCTAssertEqual(md5Version.stdout, "md5sum (GNU coreutils) 9.1\n")
        XCTAssertEqual(sha1Version.stdout, "sha1sum (GNU coreutils) 9.1\n")
        XCTAssertEqual(sha256Version.stdout, "sha256sum (GNU coreutils) 9.1\n")
    }

    func testCksumModernDigestFrontendMatchesGNUOracleSamples() async throws {
        let workspace = WorkerFEncodingWorkspace(files: [
            "/abc.txt": Data("abc".utf8),
            "/md5.cks": Data("900150983cd24fb0d6963f7d28e17f72  abc.txt\n".utf8),
            "/md5tag.cks": Data("MD5 (abc.txt) = 900150983cd24fb0d6963f7d28e17f72\n".utf8),
            "/badmd5.cks": Data("00000000000000000000000000000000  abc.txt\n".utf8),
            "/mixedmd5.cks": Data("900150983cd24fb0d6963f7d28e17f72  abc.txt\nnot a checksum line\n".utf8),
            "/crc.cks": Data("1219131554 3 abc.txt\n".utf8)
        ])

        let crc = try await cksum(["abc.txt"], workspace: workspace)
        let crcZero = try await cksum(["--zero", "abc.txt"], workspace: workspace)
        let bsd = try await cksum(["--algorithm=bsd", "abc.txt"], workspace: workspace)
        let sysv = try await cksum(["--algorithm=sysv", "abc.txt"], workspace: workspace)
        let md5Tagged = try await cksum(["--algorithm=md5", "abc.txt"], workspace: workspace)
        let md5Untagged = try await cksum(["--algorithm=md5", "--untagged", "abc.txt"], workspace: workspace)
        let sha224 = try await cksum(["--algorithm=sha224", "abc.txt"], workspace: workspace)
        let sha384 = try await cksum(["--algorithm=sha384", "abc.txt"], workspace: workspace)
        let sm3 = try await cksum(["--algorithm=sm3", "abc.txt"], workspace: workspace)
        let blake256 = try await cksum(["--algorithm=blake2b", "--length=256", "abc.txt"], workspace: workspace)
        let checkOK = try await cksum(["--algorithm=md5", "-c", "md5.cks"], workspace: workspace)
        let checkTaggedOK = try await cksum(["--algorithm=md5", "-c", "md5tag.cks"], workspace: workspace)
        let checkBad = try await cksum(["--algorithm=md5", "-c", "badmd5.cks"], workspace: workspace)
        let checkStatusBad = try await cksum(["--algorithm=md5", "-c", "--status", "badmd5.cks"], workspace: workspace)
        let checkWarn = try await cksum(["--algorithm=md5", "-c", "--warn", "mixedmd5.cks"], workspace: workspace)
        let checkStrict = try await cksum(["--algorithm=md5", "-c", "--strict", "mixedmd5.cks"], workspace: workspace)
        let checkDefaultCRC = try await cksum(["-c", "crc.cks"], workspace: workspace)
        let checkExplicitCRC = try await cksum(["--algorithm=crc", "-c", "crc.cks"], workspace: workspace)
        let zeroCheck = try await cksum(["--algorithm=md5", "--zero", "-c", "md5.cks"], workspace: workspace)
        let lengthWithoutBlake = try await cksum(["--length=256", "abc.txt"], workspace: workspace)
        let cksumHelp = try await cksum(["--help"], workspace: workspace)
        let cksumVersion = try await cksum(["--version"], workspace: workspace)

        XCTAssertEqual(crc.stdout, "1219131554 3 abc.txt\n")
        XCTAssertEqual(crcZero.stdoutData, Data("1219131554 3 abc.txt".utf8) + Data([0]))
        XCTAssertEqual(bsd.stdout, "16556     1 abc.txt\n")
        XCTAssertEqual(sysv.stdout, "294 1 abc.txt\n")
        XCTAssertEqual(md5Tagged.stdout, "MD5 (abc.txt) = 900150983cd24fb0d6963f7d28e17f72\n")
        XCTAssertEqual(md5Untagged.stdout, "900150983cd24fb0d6963f7d28e17f72  abc.txt\n")
        XCTAssertEqual(sha224.stdout, "SHA224 (abc.txt) = 23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7\n")
        XCTAssertEqual(sha384.stdout, "SHA384 (abc.txt) = cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7\n")
        XCTAssertEqual(sm3.stdout, "SM3 (abc.txt) = 66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0\n")
        XCTAssertEqual(blake256.stdout, "BLAKE2b-256 (abc.txt) = bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319\n")
        XCTAssertEqual(checkOK.stdout, "abc.txt: OK\n")
        XCTAssertEqual(checkTaggedOK.stdout, "abc.txt: OK\n")
        XCTAssertEqual(checkBad.stdout, "abc.txt: FAILED\n")
        XCTAssertEqual(checkBad.stderr, "cksum: WARNING: 1 computed checksum did NOT match\n")
        XCTAssertEqual(checkBad.exitCode, 1)
        XCTAssertEqual(checkStatusBad.stdout, "")
        XCTAssertEqual(checkStatusBad.stderr, "")
        XCTAssertEqual(checkStatusBad.exitCode, 1)
        XCTAssertEqual(checkWarn.stdout, "abc.txt: OK\n")
        XCTAssertEqual(
            checkWarn.stderr,
            "cksum: mixedmd5.cks: 2: improperly formatted MD5 checksum line\n"
                + "cksum: WARNING: 1 line is improperly formatted\n"
        )
        XCTAssertEqual(checkWarn.exitCode, 0)
        XCTAssertEqual(checkStrict.stdout, "abc.txt: OK\n")
        XCTAssertEqual(checkStrict.stderr, "cksum: WARNING: 1 line is improperly formatted\n")
        XCTAssertEqual(checkStrict.exitCode, 1)
        XCTAssertEqual(checkDefaultCRC.stdout, "")
        XCTAssertEqual(checkDefaultCRC.stderr, "cksum: crc.cks: no properly formatted checksum lines found\n")
        XCTAssertEqual(checkDefaultCRC.exitCode, 1)
        XCTAssertEqual(checkExplicitCRC.stderr, "cksum: --check is not supported with --algorithm={bsd,sysv,crc}\n")
        XCTAssertEqual(checkExplicitCRC.exitCode, 1)
        XCTAssertEqual(
            zeroCheck.stderr,
            "cksum: the --zero option is not supported when verifying checksums\n"
                + "Try 'cksum --help' for more information.\n"
        )
        XCTAssertEqual(zeroCheck.exitCode, 1)
        XCTAssertEqual(lengthWithoutBlake.stderr, "cksum: --length is only supported with --algorithm=blake2b\n")
        XCTAssertEqual(lengthWithoutBlake.exitCode, 1)
        XCTAssertTrue(cksumHelp.stdout.hasPrefix("Usage: cksum [OPTION]... [FILE]...\n"))
        XCTAssertEqual(cksumVersion.stdout, "cksum (GNU coreutils) 9.1\n")
    }

    private func md5sum(
        _ arguments: [String],
        workspace: WorkerFEncodingWorkspace
    ) async throws -> MSPCommandResult {
        try await MSPDigestCommand(name: "md5sum", algorithm: .md5).run(
            invocation: MSPCommandInvocation(name: "md5sum", arguments: arguments),
            context: MSPCommandContext(workspace: workspace)
        )
    }

    private func cksum(
        _ arguments: [String],
        workspace: WorkerFEncodingWorkspace
    ) async throws -> MSPCommandResult {
        do {
            return try await MSPCksumCommand().run(
                invocation: MSPCommandInvocation(name: "cksum", arguments: arguments),
                context: MSPCommandContext(workspace: workspace)
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        }
    }
}

private struct WorkerFEncodingWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = WorkerFEncodingWorkspaceFileSystem(files: files)
    }

    init(fileSystem: WorkerFEncodingWorkspaceFileSystem) {
        self.fileSystem = fileSystem
    }
}

private final class WorkerFEncodingWorkspaceFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    private(set) var readFileCallCount = 0
    private(set) var rangeReadCallCount = 0

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory) else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
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
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        return try files.keys.sorted().map { path in
            let name = String(path.dropFirst())
            return MSPDirectoryEntry(name: name, info: try stat(path, from: "/"))
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        readFileCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
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

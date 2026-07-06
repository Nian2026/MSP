import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

extension MSPTextLanguageCommandOracleTests {
    func testGrepSedAndAwkMatchLinuxOracleCases() async throws {
        let workspace = TextLanguageOracleWorkspace(files: [
            "/grep-a.txt": Data("alpha\nbeta\nAlpha\n".utf8),
            "/grep-b.txt": Data("beta\nalpha\n".utf8),
            "/sed.txt": Data("one\ntwo\nthree\n".utf8),
            "/awk.csv": Data("a,2\nb,3\n".utf8)
        ])

        await assertCommand("grep", ["-in", "alpha"], stdin: "Alpha\nbeta\nalpha\n", stdout: "1:Alpha\n3:alpha\n")
        await assertCommand(
            "grep",
            ["-Hn", "alpha", "/grep-a.txt", "/grep-b.txt"],
            workspace: workspace,
            stdout: "/grep-a.txt:1:alpha\n/grep-b.txt:2:alpha\n"
        )
        await assertCommand("grep", ["[", "/grep-a.txt"], workspace: workspace, stderr: "grep: Invalid regular expression\n", exitCode: 2)
        await assertCommand(
            "grep",
            ["beta", "missing"],
            workspace: workspace,
            stderr: "grep: missing: No such file or directory\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["-s", "beta", "missing"],
            workspace: workspace,
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["-P", "beta"],
            stdin: "beta\n",
            stdout: "beta\n"
        )
        await assertCommand("grep", ["-G", "a+"], stdin: "a+\naaa\n", stdout: "a+\n")
        await assertCommand("grep", ["-E", "a+"], stdin: "a+\naaa\n", stdout: "a+\naaa\n")
        await assertCommand("grep", ["-F", "-E", "a+"], stdin: "a+\naaa\n", stderr: "grep: conflicting matchers specified\n", exitCode: 2)
        await assertCommand("grep", ["-E", "-F", "a+"], stdin: "a+\naaa\n", stderr: "grep: conflicting matchers specified\n", exitCode: 2)
        await assertCommand("grep", ["--fixed-regexp", "a.b"], stdin: "a.b\naxb\n", stdout: "a.b\n")

        await assertCommand("sed", ["s/a/A/"], stdin: "a\nb\n", stdout: "A\nb\n")
        await assertCommand("sed", ["s#[/]#X#"], stdin: "/\n#\n", stdout: "X\n#\n")
        await assertCommand("sed", ["-n", "/two/p", "/sed.txt"], workspace: workspace, stdout: "two\n")
        let sedHelp = await runCommand("sed", ["--help"], workspace: workspace, standardInput: Data())
        XCTAssertTrue(sedHelp.stdout.hasPrefix("Usage: sed"), "unexpected sed help: \(sedHelp.stdout)")
        XCTAssertEqual(sedHelp.stderr, "")
        XCTAssertEqual(sedHelp.exitCode, 0)
        await assertCommand(
            "sed",
            ["s/[//"],
            stdin: "abc\n",
            stderr: "sed: -e expression #1, char 5: unterminated `s' command\n",
            exitCode: 1
        )
        await assertCommand(
            "sed",
            ["p", "/missing.txt"],
            workspace: workspace,
            stderr: "sed: can't read /missing.txt: No such file or directory\n",
            exitCode: 2
        )

        await assertCommand("awk", ["{sum += $2} END {print sum}"], stdin: "a 2\nb 3\n", stdout: "5\n")
        await assertCommand("awk", ["-F,", "{print $2 \":\" NR}", "/awk.csv"], workspace: workspace, stdout: "2:1\n3:2\n")
        await assertCommand("awk", ["!seen[$0]++"], stdin: "a\nb\na\nc\nb\n", stdout: "a\nb\nc\n")
        await assertCommand("awk", ["NF"], stdin: "\nalpha\n   \nbeta gamma\n", stdout: "alpha\nbeta gamma\n")
        await assertCommand("awk", ["NR % 2 == 0"], stdin: "one\ntwo\nthree\nfour\n", stdout: "two\nfour\n")
        await assertCommand("awk", ["$1 == \"keep\""], stdin: "keep 1\ndrop 2\nkeep 3\n", stdout: "keep 1\nkeep 3\n")
        await assertCommand("awk", ["{seen[$1]++} seen[$1] == 1"], stdin: "a 1\na 2\nb 3\n", stdout: "a 1\nb 3\n")
        await assertCommand("awk", ["/game|steam/"], stdin: "game ui\nphoto\nsteam sale\n", stdout: "game ui\nsteam sale\n")
        await assertCommand("awk", ["$1 == \"keep\" {print $2}"], stdin: "keep 1\ndrop 2\nkeep 3\n", stdout: "1\n3\n")
        await assertCommand("awk", ["BEGIN {print \"start\"} NF"], stdin: "\nalpha\n", stdout: "start\nalpha\n")
        await assertCommand("awk", ["NF; NR % 2 == 0"], stdin: "\none\ntwo\n", stdout: "one\none\ntwo\n")
        await assertCommand("awk", ["NF; {print $1}"], stdin: "\na x\nb y\n", stdout: "\na x\na\nb y\nb\n")
        let awkHelp = await runCommand("awk", ["-W", "help"], workspace: workspace, standardInput: Data())
        XCTAssertTrue(awkHelp.stdout.hasPrefix("Usage: awk"), "unexpected awk help: \(awkHelp.stdout)")
        XCTAssertEqual(awkHelp.stderr, "")
        XCTAssertEqual(awkHelp.exitCode, 0)
        let awkUsage = await runCommand("awk", ["-Wusage"], workspace: workspace, standardInput: Data())
        XCTAssertTrue(awkUsage.stdout.hasPrefix("Usage: awk"), "unexpected awk usage: \(awkUsage.stdout)")
        XCTAssertEqual(awkUsage.stderr, "")
        XCTAssertEqual(awkUsage.exitCode, 0)
        await assertCommand(
            "awk",
            ["{print}", "missing.txt"],
            workspace: workspace,
            stderr: "awk: cannot open missing.txt (No such file or directory)\n",
            exitCode: 2
        )
        await assertCommand("awk", ["--bad"], stderr: "awk: not an option: --bad\n", exitCode: 2)
    }

    func testAwkFileOperandsUseSequentialReaderInStreamingMode() async throws {
        let inputText = (1...1_200)
            .map { "line-\($0)" }
            .joined(separator: "\n") + "\n"
        let workspace = TextLanguageOracleWorkspace(files: [
            "/large.txt": Data(inputText.utf8)
        ])
        let output = MSPCommandOutputBuffer()

        let result = try await MSPAwkCommand().runStreaming(
            invocation: MSPCommandInvocation(
                name: "awk",
                arguments: ["NR == 640 || NR == 1115", "/large.txt"]
            ),
            context: MSPCommandContext(
                workspace: workspace,
                standardOutputStream: output
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, "line-640\nline-1115\n")
        XCTAssertEqual(workspace.oracleFileSystem.sequentialOpenCount, 1)
        XCTAssertEqual(workspace.oracleFileSystem.readFileCallCount, 0)
    }

    func testSedProgramExecutionMatrixCoversComplexRunnerOwners() async throws {
        await assertCommand(
            "sed",
            ["-n", "2,3{s/o/O/;p}"],
            stdin: "one\ntwo\nthree\nfour\n",
            stdout: "twO\nthree\n"
        )
        await assertCommand(
            "sed",
            [":done;s/foo/bar/;t done;s/baz/qux/"],
            stdin: "foo\nbaz\n",
            stdout: "bar\nqux\n"
        )
        await assertCommand(
            "sed",
            ["1h;2G"],
            stdin: "alpha\nbeta\n",
            stdout: "alpha\nbeta\nalpha\n"
        )
        await assertCommand(
            "sed",
            ["2i before;2a after;3c CHANGED"],
            stdin: "one\ntwo\nthree\n",
            stdout: "one\nbefore\ntwo\nafter\nCHANGED\n"
        )
        await assertCommand(
            "sed",
            ["2d;3q"],
            stdin: "one\ntwo\nthree\nfour\n",
            stdout: "one\nthree\n"
        )
        await assertCommand(
            "sed",
            ["-n", "l"],
            stdin: "tab\tend",
            stdout: "tab\\tend$\n"
        )
        await assertCommand(
            "sed",
            ["-n", "$p"],
            stdin: "tail",
            stdout: "tail"
        )
        await assertCommand(
            "sed",
            ["-n", "1~2p"],
            stdin: "one\ntwo\nthree\nfour\n",
            stdout: "one\nthree\n"
        )
        await assertCommand(
            "sed",
            ["-E", "s/([a-z]+)-([0-9]+)/\\2:&:\\1/"],
            stdin: "abc-12\n",
            stdout: "12:abc-12:abc\n"
        )
        await assertCommand(
            "sed",
            ["-n", "s/a/A/2p"],
            stdin: "a a a\n",
            stdout: "a A a\n"
        )
    }

    func testAwkActionlessPatternProgramsMatchExternalAwkOracleByteForByte() async throws {
        guard let oracleAwk = Self.externalAwkPath() else {
            throw XCTSkip("No external awk oracle is available")
        }
        let cases: [AwkOracleCase] = [
            AwkOracleCase(
                program: "!seen[$0]++",
                stdin: "a\nb\na\nc\nb\n"
            ),
            AwkOracleCase(
                program: "! seen[$0]++",
                stdin: "a\nb\na\nc\nb\n"
            ),
            AwkOracleCase(
                program: "! /skip/",
                stdin: "keep\nskip\nalso keep\n"
            ),
            AwkOracleCase(
                program: "NF",
                stdin: "\nalpha\n   \nbeta gamma\n"
            ),
            AwkOracleCase(
                program: "NR % 2 == 0",
                stdin: "one\ntwo\nthree\nfour\n"
            ),
            AwkOracleCase(
                program: "$1 == \"keep\"",
                stdin: "keep 1\ndrop 2\nkeep 3\n"
            ),
            AwkOracleCase(
                program: "$0 ~ /game|steam/",
                stdin: "game ui\nphoto\nsteam sale\n"
            ),
            AwkOracleCase(
                program: "/game|steam/",
                stdin: "game ui\nphoto\nsteam sale\n"
            ),
            AwkOracleCase(
                program: "$1 == \"keep\" {print $2}",
                stdin: "keep 1\ndrop 2\nkeep 3\n"
            ),
            AwkOracleCase(
                program: "BEGIN {print \"start\"} NF",
                stdin: "\nalpha\n"
            ),
            AwkOracleCase(
                program: "NF; NR % 2 == 0",
                stdin: "\none\ntwo\n"
            ),
            AwkOracleCase(
                program: "NF\n$1 == \"keep\"",
                stdin: "\nkeep 1\ndrop 2\n"
            ),
            AwkOracleCase(
                program: "NF; {print $1}",
                stdin: "\na x\nb y\n"
            ),
            AwkOracleCase(
                program: "{seen[$1]++} seen[$1] == 1",
                stdin: "a 1\na 2\nb 3\n"
            ),
            AwkOracleCase(
                program: "!seen[$0]++",
                stdin: "游戏\n订单\n游戏\nsteam\n订单\n"
            ),
            AwkOracleCase(
                program: "!seen[$0]++",
                stdin: (0..<1000)
                    .map { "line-\($0 % 137)" }
                    .joined(separator: "\n") + "\n"
            )
        ]

        for testCase in cases {
            let expected = try Self.runExternalAwk(
                path: oracleAwk,
                program: testCase.program,
                stdin: testCase.stdin
            )
            let actual = await runCommand(
                "awk",
                [testCase.program],
                standardInput: Data(testCase.stdin.utf8)
            )

            XCTAssertEqual(
                Data(actual.stdout.utf8),
                expected.stdout,
                "stdout byte mismatch for awk program: \(testCase.program)"
            )
            XCTAssertEqual(
                Data(actual.stderr.utf8),
                expected.stderr,
                "stderr byte mismatch for awk program: \(testCase.program)"
            )
            XCTAssertEqual(
                actual.exitCode,
                expected.exitCode,
                "exit code mismatch for awk program: \(testCase.program)"
            )
        }
    }
}

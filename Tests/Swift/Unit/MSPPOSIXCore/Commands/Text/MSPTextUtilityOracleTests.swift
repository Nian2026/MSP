import Foundation
import XCTest

extension MSPTextLanguageCommandOracleTests {
    func testXargsYesPrintfEchoAndSeqMatchLinuxOracleCases() async throws {
        await assertCommand("xargs", [], stdin: "a b\n", stdout: "a b\n")
        await assertCommand("xargs", ["-I{}", "printf", "[%s]\\n", "{}"], stdin: "one\ntwo\n", stdout: "[one]\n[two]\n")
        await assertCommand(
            "xargs",
            ["echo"],
            stdin: "'\n",
            stderr: "xargs: unmatched single quote; by default quotes are special to xargs unless you use the -0 option\n",
            exitCode: 1
        )

        let yesDefault = await runCommand("yes", [], standardInput: Data())
        XCTAssertTrue(yesDefault.stdout.hasPrefix("y\ny\n"))
        XCTAssertEqual(yesDefault.stderr, "")
        XCTAssertEqual(yesDefault.exitCode, 0)
        let yesWords = await runCommand("yes", ["MSP", "v1"], standardInput: Data())
        XCTAssertTrue(yesWords.stdout.hasPrefix("MSP v1\nMSP v1\nMSP v1\n"))
        XCTAssertEqual(yesWords.stderr, "")
        XCTAssertEqual(yesWords.exitCode, 0)
        await assertCommand("yes", ["--help"], stdout: """
        Usage: yes [STRING]...
          or:  yes OPTION
        Repeatedly output a line with all specified STRING(s), or 'y'.

              --help        display this help and exit
              --version     output version information and exit

        GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
        Report any translation bugs to <https://translationproject.org/team/>
        Full documentation <https://www.gnu.org/software/coreutils/yes>
        or available locally via: info '(coreutils) yes invocation'

        """)
        await assertCommand("yes", ["--version"], stdout: """
        yes (GNU coreutils) 9.1
        Copyright (C) 2022 Free Software Foundation, Inc.
        License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        Written by David MacKenzie.

        """)

        await assertCommand("printf", ["%s=%02d\n", "a", "3", "b", "7"], stdout: "a=03\nb=07\n")
        await assertCommand("printf", ["%bX\n", "a\\n\\czz"], stdout: "a\n")
        await assertCommand("printf", ["%d\n", "12x"], stdout: "12\n", stderr: "printf: \u{2018}12x\u{2019}: value not completely converted\n", exitCode: 1)

        await assertCommand("echo", ["hello", "world"], stdout: "hello world\n")
        await assertCommand("echo", ["-n", "hello"], stdout: "hello")
        await assertCommand("echo", ["-e", "a\\nb"], stdout: "a\nb\n")

        await assertCommand("seq", ["3"], stdout: "1\n2\n3\n")
        await assertCommand("seq", ["-s,", "2", "2", "6"], stdout: "2,4,6\n")
        await assertCommand(
            "seq",
            ["1", "0", "2"],
            stderr: "seq: invalid Zero increment value: \u{2018}0\u{2019}\nTry 'seq --help' for more information.\n",
            exitCode: 1
        )
    }
}

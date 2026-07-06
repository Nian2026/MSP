import Foundation

extension MSPTextLanguageCommandOracleTests {
    func testCutJoinAndNlMatchLinuxOracleCases() async throws {
        let workspace = TextLanguageOracleWorkspace(files: [
            "/cut.txt": Data("wxyz\n".utf8),
            "/join-left.txt": Data("1 apple\n2 banana\n".utf8),
            "/join-right.txt": Data("1 red\n2 yellow\n".utf8),
            "/nl.txt": Data("a\n\nb\n".utf8)
        ])

        await assertCommand("cut", ["-d:", "-f2"], stdin: "a:b:c\n", stdout: "b\n")
        await assertCommand("cut", ["-n", "-b", "2-3"], stdin: "abcd\n", stdout: "bc\n")
        await assertCommand(
            "cut",
            ["-d", "", "-f2"],
            stdin: "a\0b\0c\n",
            stdout: "b\n"
        )
        await assertCommand(
            "cut",
            ["-d", ":", "--output-delimiter=", "-f1,3"],
            stdin: "a:b:c\n",
            stdout: "a\0c\n"
        )
        await assertCommand("cut", ["-c2-4", "/cut.txt"], workspace: workspace, stdout: "xyz\n")
        await assertCommand(
            "cut",
            ["-d", "::", "-f1", "/cut.txt"],
            workspace: workspace,
            stderr: "cut: the delimiter must be a single character\nTry 'cut --help' for more information.\n",
            exitCode: 1
        )

        await assertCommand("join", ["/join-left.txt", "/join-right.txt"], workspace: workspace, stdout: "1 apple red\n2 banana yellow\n")
        await assertCommand(
            "join",
            ["-", "/join-right.txt"],
            workspace: workspace,
            stdin: "1 one\n2 two\n",
            stdout: "1 one red\n2 two yellow\n"
        )
        await assertCommand(
            "join",
            ["-1", "0", "/join-left.txt", "/join-right.txt"],
            workspace: workspace,
            stderr: "join: invalid field number: \u{2018}0\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            "join",
            ["/join-left.txt", "missing"],
            workspace: workspace,
            stderr: "join: missing: No such file or directory\n",
            exitCode: 1
        )

        await assertCommand("nl", [], stdin: "a\n\nb\n", stdout: "     1\ta\n       \n     2\tb\n")
        await assertCommand("nl", ["-ba", "-nrz", "-w3", "-s:", "/nl.txt"], workspace: workspace, stdout: "001:a\n002:\n003:b\n")
        await assertCommand(
            "nl",
            ["-w", "0", "/nl.txt"],
            workspace: workspace,
            stderr: "nl: invalid line number field width: \u{2018}0\u{2019}: Numerical result out of range\n",
            exitCode: 1
        )
    }
}

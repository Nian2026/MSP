import Foundation

extension MSPTextLanguageCommandOracleTests {
    func testGrepSupportsAdditionalGNUOptionAliases() async throws {
        await assertCommand("grep", ["--help"], stdoutPrefix: "Usage: grep [OPTION]... PATTERNS [FILE]...\n")
        await assertCommand("grep", ["-V"], stdout: "grep (GNU grep) 3.8\n")
        await assertCommand("grep", ["-G", "a.a"], stdin: "axa\nbbb\n", stdout: "axa\n")
        await assertCommand("grep", ["-y", "alpha"], stdin: "Alpha\nbeta\n", stdout: "Alpha\n")
        await assertCommand("grep", ["-i", "--no-ignore-case", "alpha"], stdin: "Alpha\nalpha\n", stdout: "alpha\n")
        await assertCommand("grep", ["--label=stdin.txt", "-H", "beta"], stdin: "beta\n", stdout: "stdin.txt:beta\n")
        await assertCommand("grep", ["--line-buffered", "beta"], stdin: "alpha\nbeta\n", stdout: "beta\n")
    }

    func testGrepContextBinaryDirectoryAndPrecedenceOptions() async throws {
        let workspace = TextLanguageOracleWorkspace(files: [
            "/context.txt": Data("zero\none\ntwo\nthree\nfour\nfive\nsix\n".utf8),
            "/match.txt": Data("hit\nmiss\n".utf8),
            "/nomatch.txt": Data("miss\n".utf8),
            "/bin.dat": Data([0x61, 0x00, 0x62, 0x0A]),
            "/dir/file.txt": Data("hit\n".utf8),
            "/tree/keep.txt": Data("hit\n".utf8),
            "/tree/skip.log": Data("hit\n".utf8),
            "/tree/nested/keep.swift": Data("hit\n".utf8),
            "/tree/vendor/keep.txt": Data("hit\n".utf8),
            "/empty-patterns.txt": Data(),
            "/exclude-patterns.txt": Data("*.log\n".utf8)
        ])

        await assertCommand(
            "grep",
            ["-n", "-1", "three", "/context.txt"],
            workspace: workspace,
            stdout: "3-two\n4:three\n5-four\n"
        )
        await assertCommand(
            "grep",
            ["-E", "-A1", "-B1", "--group-separator=***", "one|five", "/context.txt"],
            workspace: workspace,
            stdout: "zero\none\ntwo\n" + "***\n" + "four\nfive\nsix\n"
        )
        await assertCommand(
            "grep",
            ["-E", "-C1", "--no-group-separator", "one|five", "/context.txt"],
            workspace: workspace,
            stdout: "zero\none\ntwo\nfour\nfive\nsix\n"
        )
        await assertCommand(
            "grep",
            ["-n", "-A0", "-C1", "three", "/context.txt"],
            workspace: workspace,
            stdout: "3-two\n4:three\n"
        )
        await assertCommand(
            "grep",
            ["--directories=skip", "hit", "/dir"],
            workspace: workspace,
            exitCode: 1
        )
        await assertCommand(
            "grep",
            ["--directories=read", "hit", "/dir"],
            workspace: workspace,
            stderr: "grep: /dir: Is a directory\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["--binary-files=without-match", "a", "/bin.dat"],
            workspace: workspace,
            exitCode: 1
        )
        await assertCommand(
            "grep",
            ["--binary-files=text", "a", "/bin.dat"],
            workspace: workspace,
            stdout: "a\u{0}b\n"
        )
        await assertCommand(
            "grep",
            ["--binary-files=binary", "a", "/bin.dat"],
            workspace: workspace,
            stderr: "grep: /bin.dat: binary file matches\n"
        )
        await assertCommand(
            "grep",
            ["-z", "b"],
            stdin: "a\0b\0",
            stdout: "b\0"
        )
        await assertCommand(
            "grep",
            ["-lZ", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "/match.txt\0"
        )
        await assertCommand(
            "grep",
            ["-nT", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "1:\thit\n"
        )
        await assertCommand(
            "grep",
            ["-u", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "hit\n",
            stderr: "grep: warning: --unix-byte-offsets (-u) is obsolete\n"
        )
        await assertCommand(
            "grep",
            ["--color", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "hit\n"
        )
        await assertCommand(
            "grep",
            ["--colour=never", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "hit\n"
        )
        await assertCommand(
            "grep",
            ["--color=always", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "\u{1B}[01;31m\u{1B}[Khit\u{1B}[m\u{1B}[K\n"
        )
        await assertCommand(
            "grep",
            ["--color=always", "-nH", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "\u{1B}[35m\u{1B}[K/match.txt\u{1B}[m\u{1B}[K\u{1B}[36m\u{1B}[K:\u{1B}[m\u{1B}[K\u{1B}[32m\u{1B}[K1\u{1B}[m\u{1B}[K\u{1B}[36m\u{1B}[K:\u{1B}[m\u{1B}[K\u{1B}[01;31m\u{1B}[Khit\u{1B}[m\u{1B}[K\n"
        )
        await assertCommand(
            "grep",
            ["--color=bad", "hit", "/match.txt"],
            workspace: workspace,
            stderr: "grep: invalid color option \u{2018}bad\u{2019}\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["-I", "a", "/bin.dat"],
            workspace: workspace,
            exitCode: 1
        )
        await assertCommand(
            "grep",
            ["-c", "-l", "hit", "/match.txt"],
            workspace: workspace,
            stdout: "/match.txt\n"
        )
        await assertCommand(
            "grep",
            ["-c", "-L", "hit", "/nomatch.txt"],
            workspace: workspace,
            stdout: "/nomatch.txt\n"
        )
        await assertCommand(
            "grep",
            ["-q", "-c", "hit", "/match.txt"],
            workspace: workspace
        )
        await assertCommand(
            "grep",
            ["--binary-files=nope", "a", "/bin.dat"],
            workspace: workspace,
            stderr: "grep: unknown binary-files type\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["--directories=nope", "hit", "/dir"],
            workspace: workspace,
            stderr: "grep: unknown directories method\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["-r", "--include=*.txt", "hit", "/tree"],
            workspace: workspace,
            stdout: "/tree/keep.txt:hit\n/tree/vendor/keep.txt:hit\n"
        )
        await assertCommand(
            "grep",
            ["-r", "--exclude=*.log", "--exclude-dir=vendor", "hit", "/tree"],
            workspace: workspace,
            stdout: "/tree/keep.txt:hit\n/tree/nested/keep.swift:hit\n"
        )
        await assertCommand(
            "grep",
            ["-r", "--exclude-from=/exclude-patterns.txt", "hit", "/tree"],
            workspace: workspace,
            stdout: "/tree/keep.txt:hit\n/tree/nested/keep.swift:hit\n/tree/vendor/keep.txt:hit\n"
        )
        await assertCommand(
            "grep",
            ["--dereference-recursive", "--exclude=*.log", "hit", "/tree"],
            workspace: workspace,
            stdout: "/tree/keep.txt:hit\n/tree/nested/keep.swift:hit\n/tree/vendor/keep.txt:hit\n"
        )
        await assertCommand(
            "grep",
            ["--exclude-from=/missing-patterns.txt", "hit", "/tree"],
            workspace: workspace,
            stderr: "grep: /missing-patterns.txt: No such file or directory\n",
            exitCode: 2
        )
        await assertCommand(
            "grep",
            ["-f", "/empty-patterns.txt", "/match.txt"],
            workspace: workspace,
            exitCode: 1
        )
        await assertCommand(
            "grep",
            ["-L", "-f", "/empty-patterns.txt", "/match.txt"],
            workspace: workspace,
            stdout: "/match.txt\n"
        )
    }
}

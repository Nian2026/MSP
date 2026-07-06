import Foundation
import XCTest
import ModelShellProxy

final class ModelShellProxyFilesystemParityTests: XCTestCase {
    func testLsDotfileVisibilityMatchesGNUCoreutils() async throws {
        let result = try await runInWorkspace("""
        mkdir d
        touch .hidden visible
        ls
        printf -- '--\\n'
        ls -a
        printf -- '--\\n'
        ls -A
        printf -- '--\\n'
        ls -d .
        """)

        XCTAssertEqual(
            result.stdout,
            """
            d
            visible
            --
            .
            ..
            .hidden
            d
            visible
            --
            .hidden
            d
            visible
            --
            .

            """
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testLsRecursiveHeadersUseCallerVisiblePaths() async throws {
        let result = try await runInWorkspace("mkdir -p tree/sub; touch tree/f; ls -R tree")

        XCTAssertEqual(
            result.stdout,
            """
            tree:
            f
            sub

            tree/sub:

            """
        )
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testFilesystemCommandErrorEdgesMatchGNUCoreutils() async throws {
        try await assertRun(
            "mkdir d; mkdir d",
            stderr: "mkdir: cannot create directory ‘d’: File exists\n",
            exitCode: 1
        )
        try await assertRun(
            "touch f; mkdir -p f",
            stderr: "mkdir: cannot create directory ‘f’: File exists\n",
            exitCode: 1
        )
        try await assertRun(
            "rm",
            stderr: "rm: missing operand\nTry 'rm --help' for more information.\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; cp d e",
            stderr: "cp: -r not specified; omitting directory 'd'\n",
            exitCode: 1
        )
        try await assertRun(
            "printf x > a; printf y > b; cp a b missing",
            stderr: "cp: target 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; printf x > f; cp -r d f",
            stderr: "cp: cannot overwrite non-directory 'f' with directory 'd'\n",
            exitCode: 1
        )
        try await assertRun(
            "printf x > a; printf y > b; mv a b missing",
            stderr: "mv: target 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; printf x > f; mv d f",
            stderr: "mv: cannot overwrite non-directory 'f' with directory 'd'\n",
            exitCode: 1
        )
        try await assertRun(
            "touch",
            stderr: "touch: missing file operand\nTry 'touch --help' for more information.\n",
            exitCode: 1
        )
        try await assertRun(
            "touch -c missing; test -e missing",
            exitCode: 1
        )
    }

    func testLinkModeTemporaryDuAndFindEdgesMatchGNUCoreutils() async throws {
        try await assertRun(
            "ln missing link",
            stderr: "ln: failed to access 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; ln d hard",
            stderr: "ln: d: hard link not allowed for directory\n",
            exitCode: 1
        )
        try await assertRun(
            "ln -s target link; ln -s target link",
            stderr: "ln: failed to create symbolic link 'link': File exists\n",
            exitCode: 1
        )
        try await assertRun(
            "ln -s missing link; ln -sf target link; readlink link",
            stdout: "target\n",
            exitCode: 0
        )
        try await assertRun(
            "chmod bad missing",
            stderr: "chmod: invalid mode: \u{2018}bad\u{2019}\nTry 'chmod --help' for more information.\n",
            exitCode: 1
        )
        try await assertRun(
            "mktemp plain",
            stderr: "mktemp: too few X's in template \u{2018}plain\u{2019}\n",
            exitCode: 1
        )
        try await assertRun(
            "mktemp a.XXXXXX b.XXXXXX",
            stderr: "mktemp: too many templates\nTry 'mktemp --help' for more information.\n",
            exitCode: 1
        )

        let relativeTemp = try await runInWorkspace("mktemp case.XXXXXX; ls")
        XCTAssertTrue(relativeTemp.stdout.range(
            of: #"^case\.[A-Za-z0-9]{6}\ncase\.[A-Za-z0-9]{6}\n$"#,
            options: .regularExpression
        ) != nil, relativeTemp.stdout)
        XCTAssertEqual(relativeTemp.stderr, "")
        XCTAssertEqual(relativeTemp.exitCode, 0)

        try await assertRun(
            "du missing",
            stderr: "du: cannot access 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; : > f; printf abc > g; du d; du f; du g",
            stdout: "4\td\n0\tf\n4\tg\n",
            exitCode: 0
        )
        try await assertRun(
            "du -d nope .",
            stderr: "du: invalid maximum depth \u{2018}nope\u{2019}\nTry 'du --help' for more information.\n",
            exitCode: 1
        )
        try await assertRun(
            "find missing",
            stderr: "find: \u{2018}missing\u{2019}: No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "find . \\( \\)",
            stderr: "find: invalid expression; empty parentheses are not allowed.\n",
            exitCode: 1
        )
        try await assertRun(
            "find . -maxdepth nope",
            stderr: "find: Expected a positive decimal integer argument to -maxdepth, but got \u{2018}nope\u{2019}\n",
            exitCode: 1
        )
        try await assertRun(
            "find . -type z",
            stderr: "find: Unknown argument to -type: z\n",
            exitCode: 1
        )
        try await assertRun(
            "find . -exec echo {}",
            stderr: "find: missing argument to `-exec'\n",
            exitCode: 1
        )
    }

    func testVPSOracleFilesystemCommandCoverageMatchesGNUCoreutils() async throws {
        try await assertRun(
            "mkdir d; touch a; ls",
            stdout: "a\nd\n",
            exitCode: 0
        )
        try await assertRun(
            "ls missing",
            stderr: "ls: cannot access 'missing': No such file or directory\n",
            exitCode: 2
        )
        try await assertRun(
            """
            mkdir -p d/sub
            touch d/file .hidden
            ls -a
            printf -- '--\\n'
            ls -R d
            """,
            stdout:
            """
            .
            ..
            .hidden
            d
            --
            d:
            file
            sub

            d/sub:

            """,
            exitCode: 0
        )
        try await assertRun(
            "printf x > a; cp a b; cat b; printf '\\n'; ls",
            stdout: "x\na\nb\n",
            exitCode: 0
        )
        try await assertRun(
            "printf x > a; cp a a",
            stderr: "cp: 'a' and 'a' are the same file\n",
            exitCode: 1
        )
        try await assertRun(
            "printf x > a; mv a a",
            stderr: "mv: 'a' and 'a' are the same file\n",
            exitCode: 1
        )
        try await assertRun(
            "touch a; rm a; ls",
            exitCode: 0
        )
        try await assertRun(
            "rm missing",
            stderr: "rm: cannot remove 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; rm d",
            stderr: "rm: cannot remove 'd': Is a directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mkdir d; ls",
            stdout: "d\n",
            exitCode: 0
        )
        try await assertRun(
            "mkdir missing/child",
            stderr: "mkdir: cannot create directory ‘missing/child’: No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "touch a; ls",
            stdout: "a\n",
            exitCode: 0
        )
        try await assertRun(
            "touch missing/a",
            stderr: "touch: cannot touch 'missing/a': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "printf x > a; ln a b; cat b; printf '\\n'; ls",
            stdout: "x\na\nb\n",
            exitCode: 0
        )
        try await assertRun(
            "printf x > a; printf y > b; mkdir d; ln a b d; ls d; cat d/a; cat d/b",
            stdout: "a\nb\nxy",
            exitCode: 0
        )
        try await assertRun(
            "touch a; chmod 600 a; stat -c %a a",
            stdout: "600\n",
            exitCode: 0
        )
        try await assertRun(
            "touch a b; chmod 600 missing a b; stat -c '%n %a' a b",
            stdout: "a 600\nb 600\n",
            stderr: "chmod: cannot access 'missing': No such file or directory\n",
            exitCode: 0
        )
        try await assertRun(
            "mkdir d; printf abc > d/f; du d",
            stdout: "8\td\n",
            exitCode: 0
        )
        try await assertRun(
            "mkdir d; printf abc > d/f; du -b -c d/f",
            stdout: "3\td/f\n3\ttotal\n",
            exitCode: 0
        )
        try await assertRun(
            "mkdir -p d/sub; touch d/a d/sub/b; find d -name a",
            stdout: "d/a\n",
            exitCode: 0
        )
        try await assertRun(
            "touch victim; find . -name victim -exec rm {} \\;; test -e victim",
            exitCode: 1
        )
    }

    func testVPSOracleMktempCreatesRelativeFilesAndDirectories() async throws {
        let fileResult = try await runInWorkspace("mktemp case.XXXXXX; ls")
        XCTAssertTrue(fileResult.stdout.range(
            of: #"^case\.[A-Za-z0-9]{6}\ncase\.[A-Za-z0-9]{6}\n$"#,
            options: .regularExpression
        ) != nil, fileResult.stdout)
        XCTAssertEqual(fileResult.stderr, "")
        XCTAssertEqual(fileResult.exitCode, 0)

        let directoryResult = try await runInWorkspace("mktemp -d dir.XXXXXX; ls -d dir.*")
        XCTAssertTrue(directoryResult.stdout.range(
            of: #"^dir\.[A-Za-z0-9]{6}\ndir\.[A-Za-z0-9]{6}\n$"#,
            options: .regularExpression
        ) != nil, directoryResult.stdout)
        XCTAssertEqual(directoryResult.stderr, "")
        XCTAssertEqual(directoryResult.exitCode, 0)
    }

    func testVPSOracleMissingSourceDiagnosticsForCopyAndMove() async throws {
        try await assertRun(
            "cp missing b",
            stderr: "cp: cannot stat 'missing': No such file or directory\n",
            exitCode: 1
        )
        try await assertRun(
            "mv missing b",
            stderr: "mv: cannot stat 'missing': No such file or directory\n",
            exitCode: 1
        )
    }

    private func assertRun(
        _ command: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await runInWorkspace(command)
        XCTAssertEqual(result.stdout, stdout, file: file, line: line)
        XCTAssertEqual(result.stderr, stderr, file: file, line: line)
        XCTAssertEqual(result.exitCode, exitCode, file: file, line: line)
    }

    private func runInWorkspace(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
        let result = await shell.run(command)
        XCTAssertFalse(result.stdout.contains(rootURL.path))
        XCTAssertFalse(result.stderr.contains(rootURL.path))
        return (result.stdout, result.stderr, result.exitCode)
    }

    private func makeTemporaryURL(_ name: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelShellProxyFilesystemParityTests")
            .appendingPathComponent(name)
    }

    private func removeTemporaryURL(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

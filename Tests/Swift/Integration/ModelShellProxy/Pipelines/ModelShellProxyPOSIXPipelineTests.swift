import Foundation
import XCTest
import MSPAgentBridge
import MSPApple
import ModelShellProxy

final class ModelShellProxyPOSIXPipelineTests: ModelShellProxyIntegrationTestCase {
    func testTextFilterPipelineSortUniqAndNumericSort() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("printf 'b\\na\\nb\\nc\\na\\nb\\n' | sort | uniq -c | sort -nr")

        XCTAssertEqual(result.stdout, "      3 b\n      2 a\n      1 c\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPipelineCommandExecutionRespectsVirtualPATH() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let hidden = await shell.run("PATH=/nope yes hidden | head -n 1; printf 'status=%s/%s:%s\\n' \"${PIPESTATUS[0]}\" \"${PIPESTATUS[1]}\" \"$?\"")
        let visible = await shell.run("PATH=/bin yes visible | head -n 1")
        let explicit = await shell.run("PATH=/nope /usr/bin/yes explicit | /usr/bin/head -n 1")

        XCTAssertEqual(hidden.stdout, "status=127/0:0\n")
        XCTAssertEqual(hidden.stderr, "yes: command not found\n")
        XCTAssertEqual(hidden.exitCode, 0)
        XCTAssertEqual(visible.stdout, "visible\n")
        XCTAssertEqual(visible.stderr, "")
        XCTAssertEqual(visible.exitCode, 0)
        XCTAssertEqual(explicit.stdout, "explicit\n")
        XCTAssertEqual(explicit.stderr, "")
        XCTAssertEqual(explicit.exitCode, 0)
    }

    func testBcEvaluatesIntegerArithmeticFromPipelinesAndFiles() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "10/3\n2*(4+5)\n7>3\n".write(
            to: rootURL.appendingPathComponent("math.bc"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let pipeline = await shell.run("printf '1+2*3\\n(10-4)/3\\n1&&0\\n' | bc")
        let file = await shell.run("bc -l math.bc")
        let divideByZero = await shell.run("printf '1/0\\n' | bc")

        XCTAssertEqual(pipeline.stdout, "7\n2\n0\n")
        XCTAssertEqual(pipeline.stderr, "")
        XCTAssertEqual(pipeline.exitCode, 0)
        XCTAssertEqual(file.stdout, "3\n18\n1\n")
        XCTAssertEqual(file.stderr, "")
        XCTAssertEqual(file.exitCode, 0)
        XCTAssertEqual(divideByZero.stdout, "")
        XCTAssertEqual(divideByZero.stderr, "arithmetic expansion: division by zero\n")
        XCTAssertEqual(divideByZero.exitCode, 2)
        XCTAssertFalse(file.stdout.contains(rootURL.path))
        XCTAssertFalse(divideByZero.stderr.contains(rootURL.path))
    }

    func testAwkRunsProgramsFromPipelinesFilesAndWorkspaceScripts() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha,1\nbeta,2\ngamma,3\n".write(
            to: rootURL.appendingPathComponent("docs/data.csv"),
            atomically: true,
            encoding: .utf8
        )
        try "$2 >= limit { print $1 }\n".write(
            to: rootURL.appendingPathComponent("filter.awk"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let pipeline = await shell.run("printf 'a b\\nc d\\n' | awk '{ print $2 }'")
        let csv = await shell.run("awk -F, '{ print $1 \":\" $2 }' docs/data.csv")
        let begin = await shell.run("awk 'BEGIN { print \"ready\" }'")
        let script = await shell.run("awk -F, -v limit=2 -f filter.awk docs/data.csv")
        let redirected = await shell.run("awk -F, '{ print $2 > \"docs/numbers.txt\" }' docs/data.csv; cat docs/numbers.txt")
        let commandGetline = await shell.run("awk 'BEGIN { \"cat docs/data.csv\" | getline x; print x }'")

        XCTAssertEqual(pipeline.stdout, "b\nd\n")
        XCTAssertEqual(pipeline.stderr, "")
        XCTAssertEqual(pipeline.exitCode, 0)
        XCTAssertEqual(csv.stdout, "alpha:1\nbeta:2\ngamma:3\n")
        XCTAssertEqual(csv.stderr, "")
        XCTAssertEqual(csv.exitCode, 0)
        XCTAssertEqual(begin.stdout, "ready\n")
        XCTAssertEqual(begin.stderr, "")
        XCTAssertEqual(begin.exitCode, 0)
        XCTAssertEqual(script.stdout, "beta\ngamma\n")
        XCTAssertEqual(script.stderr, "")
        XCTAssertEqual(script.exitCode, 0)
        XCTAssertEqual(redirected.stdout, "1\n2\n3\n")
        XCTAssertEqual(redirected.stderr, "")
        XCTAssertEqual(redirected.exitCode, 0)
        XCTAssertEqual(commandGetline.stdout, "alpha,1\n")
        XCTAssertEqual(commandGetline.stderr, "")
        XCTAssertEqual(commandGetline.exitCode, 0)
        XCTAssertFalse(csv.stdout.contains(rootURL.path))
        XCTAssertFalse(script.stderr.contains(rootURL.path))
        XCTAssertFalse(redirected.stdout.contains(rootURL.path))
        XCTAssertFalse(commandGetline.stdout.contains(rootURL.path))
    }

    func testPOSIXCoreFindPipeWcUsesStreamingDirectoryEnumeration() async throws {
        let fileSystem = PipelineStreamingOnlyFileSystem(fileCount: 12)
        let workspace = PipelineStreamingOnlyWorkspace(fileSystem: fileSystem)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)

        let result = await shell.run("find / -type f 2>/dev/null | wc -l")

        XCTAssertEqual(result.stdout, "12\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
    }

    func testStreamingPipelineLetsHeadCloseFindThroughSed() async throws {
        let fileSystem = PipelineStreamingOnlyFileSystem(fileCount: 5_000)
        let workspace = PipelineStreamingOnlyWorkspace(fileSystem: fileSystem)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)

        let result = await shell.run("find / -type f 2>/dev/null | sed 's#^#/#' | head -50")

        XCTAssertEqual(result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 50)
        XCTAssertTrue(result.stdout.hasPrefix("//file-000.txt\n"))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertLessThan(fileSystem.enumeratedEntryCount, 5_000)
    }

    func testPipelineEarlyStopPropagatesForSedQuitGrepMaxCountAndAwkExit() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let sedQuit = await shell.run("seq 1 1000000 | sed -n '348,500p;501q' | wc -l")
        let grepMaxCount = await shell.run("seq 1 1000000 | grep -m 3 '^[0-9]'")
        let awkExit = await shell.run("seq 1 1000000 | awk 'NR > 5 { exit } { print }'")

        XCTAssertEqual(sedQuit.stdout, "153\n")
        XCTAssertEqual(sedQuit.stderr, "")
        XCTAssertEqual(sedQuit.exitCode, 0)
        XCTAssertEqual(grepMaxCount.stdout, "1\n2\n3\n")
        XCTAssertEqual(grepMaxCount.stderr, "")
        XCTAssertEqual(grepMaxCount.exitCode, 0)
        XCTAssertEqual(awkExit.stdout, "1\n2\n3\n4\n5\n")
        XCTAssertEqual(awkExit.stderr, "")
        XCTAssertEqual(awkExit.exitCode, 0)
    }

    func testStreamingPipelineLetsHeadCloseFindThroughXargs() async throws {
        let fileSystem = PipelineStreamingOnlyFileSystem(fileCount: 80_000)
        let workspace = PipelineStreamingOnlyWorkspace(fileSystem: fileSystem)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)

        let result = await shell.run("find / -type f -print0 | xargs -0 -n 1000 echo | head -5")
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines.first?.hasPrefix("/file-000.txt /file-001.txt /file-002.txt") == true)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertLessThan(fileSystem.enumeratedEntryCount, 80_000)
    }

    func testStreamingLsUnsortedCanBeStoppedByHead() async throws {
        let fileSystem = PipelineStreamingOnlyFileSystem(fileCount: 5_000)
        let workspace = PipelineStreamingOnlyWorkspace(fileSystem: fileSystem)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)

        let shortOption = await shell.run("ls -U / | head -3")
        let longOption = await shell.run("ls --sort=none / | head -3")

        XCTAssertEqual(shortOption.stdout, "file-000.txt\nfile-001.txt\nfile-002.txt\n")
        XCTAssertEqual(shortOption.stderr, "")
        XCTAssertEqual(shortOption.exitCode, 0)
        XCTAssertEqual(longOption.stdout, "file-000.txt\nfile-001.txt\nfile-002.txt\n")
        XCTAssertEqual(longOption.stderr, "")
        XCTAssertEqual(longOption.exitCode, 0)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertLessThan(fileSystem.enumeratedEntryCount, 10_000)
    }

    func testStreamingRecursiveLsUnsortedCanBeStoppedByHead() async throws {
        let fileSystem = PipelineStreamingOnlyFileSystem(fileCount: 5_000)
        let workspace = PipelineStreamingOnlyWorkspace(fileSystem: fileSystem)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
            .enable(.posixCore)

        let result = await shell.run("ls -R -U / | head -3")

        XCTAssertEqual(result.stdout, "/:\nfile-000.txt\nfile-001.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertLessThan(fileSystem.enumeratedEntryCount, 5_000)
    }

    func testDataAndTextLinuxCommandsRunThroughPipelinesAndWorkspaceFS() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try "a\nb\nc\n".write(
            to: rootURL.appendingPathComponent("left.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "b\nc\nd\n".write(
            to: rootURL.appendingPathComponent("right.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 apple\n2 banana\n".write(
            to: rootURL.appendingPathComponent("names.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 red\n2 yellow\n".write(
            to: rootURL.appendingPathComponent("colors.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let encoded = await shell.run("printf hello | base64 -w0")
        let decodedUpper = await shell.run("printf aGVsbG8= | base64 -d | tr a-z A-Z")
        let comparison = await shell.run("comm -12 left.txt right.txt | paste -d , -s")
        let checksum = await shell.run("printf abc | cksum")
        let hex = await shell.run("printf 'ABC\\n' | xxd -p")
        let grep = await shell.run("grep -n c right.txt")
        let joined = await shell.run("join names.txt colors.txt")
        let formatted = await shell.run("printf '1024\\n' | numfmt --to=iec")
        let dump = await shell.run("printf AB | od -An -tx1")
        let binaryDecoded = await shell.run("printf '/w==' | base64 -d")
        let binaryPipeline = await shell.run("printf '/w==' | base64 -d | od -An -tx1")
        let binaryRedirection = await shell.run("printf '/w==' | base64 -d > byte.bin; od -An -tx1 byte.bin")

        XCTAssertEqual(encoded.stdout, "aGVsbG8=")
        XCTAssertEqual(decodedUpper.stdout, "HELLO")
        XCTAssertEqual(comparison.stdout, "b,c\n")
        XCTAssertEqual(checksum.stdout, "1219131554 3\n")
        XCTAssertEqual(hex.stdout, "4142430a\n")
        XCTAssertEqual(grep.stdout, "2:c\n")
        XCTAssertEqual(joined.stdout, "1 apple red\n2 banana yellow\n")
        XCTAssertEqual(formatted.stdout, "1.0K\n")
        XCTAssertEqual(dump.stdout, " 41 42\n")
        XCTAssertEqual(binaryDecoded.stdoutData, Data([0xff]))
        XCTAssertEqual(binaryPipeline.stdout, " ff\n")
        XCTAssertEqual(binaryRedirection.stdout, " ff\n")
        XCTAssertFalse(comparison.stdout.contains(rootURL.path))
        XCTAssertFalse(checksum.stdout.contains(rootURL.path))
        XCTAssertFalse(grep.stdout.contains(rootURL.path))
    }
}

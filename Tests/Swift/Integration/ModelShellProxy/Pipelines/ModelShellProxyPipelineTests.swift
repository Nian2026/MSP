import Foundation
import XCTest
import MSPAgentBridge
import MSPApple
import ModelShellProxy

final class ModelShellProxyPipelineTests: ModelShellProxyIntegrationTestCase {
    func testPipelineFeedsStdoutIntoNextCommandStdin() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let byteCount = await shell.run("printf 'abc' | wc -c")
        let lineCount = await shell.run("printf 'alpha\\nbeta\\n' | head -n 1 | wc -c")

        XCTAssertEqual(byteCount.stdout, "3\n")
        XCTAssertEqual(byteCount.stderr, "")
        XCTAssertEqual(byteCount.exitCode, 0)
        XCTAssertEqual(lineCount.stdout, "6\n")
        XCTAssertEqual(lineCount.stderr, "")
        XCTAssertEqual(lineCount.exitCode, 0)
    }

    func testBufferedPipelinePreservesClosedStandardInputForFirstFallbackStage() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("exec <&-; f() { cat; }; f | cat")
        let statuses = await shell.run(#"printf '%s\n' "${PIPESTATUS[*]}""#)

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(statuses.stdout, "1 0\n")
        XCTAssertEqual(statuses.stderr, "")
        XCTAssertEqual(statuses.exitCode, 0)
    }

    func testStreamingPipelinePreservesClosedStandardInputForFirstStage() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("cat <&- | wc -c")
        let statuses = await shell.run(#"printf '%s\n' "${PIPESTATUS[*]}""#)

        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.stderr, "cat: stdin: Bad file descriptor\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(statuses.stdout, "1 0\n")
        XCTAssertEqual(statuses.stderr, "")
        XCTAssertEqual(statuses.exitCode, 0)
    }

    func testStreamingPipelineStdinRedirectionOverridesInheritedInputStream() async throws {
        let shell = try ModelShellProxy(configuration: MSPConfiguration(
            standardInputStream: MSPDataInputStream(Data("outer-stream".utf8))
        ))
        .enable(.posixCore)

        let result = await shell.run("cat <<< inner | wc -c")

        XCTAssertEqual(result.stdout, "6\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPipelineFinalizesOutputProcessSubstitution() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("yes routed | head -n 1 > >(cat > out.txt); cat out.txt")

        XCTAssertEqual(result.stdout, "routed\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("out.txt"), encoding: .utf8),
            "routed\n"
        )
        XCTAssertFalse(result.stdout.contains(rootURL.path))
    }

    func testStreamingPipelineExpansionMutationsStayIsolatedFromParentShell() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run(#"""
        declare -a arr
        declare -A map
        seq 1 ${x:=3} | wc -l
        seq 1 ${arr[1]:=4} | wc -l
        seq 1 ${map[k]:=2} | wc -l
        printf 'x=<%s> arr1=<%s> mapk=<%s>\n' "$x" "${arr[1]}" "${map[k]}"
        """#)

        XCTAssertEqual(result.stdout, "3\n4\n2\nx=<> arr1=<> mapk=<>\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPipelineKeepsIntermediateStderrUnlessPipeAndStderrIsRequested() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        try shell.register("both") { _, _ in
            .failure(exitCode: 7, stdout: "out", stderr: "err")
        }

        let normalPipe = await shell.run("both | wc -c")
        let stderrPipe = await shell.run("both |& wc -c")

        XCTAssertEqual(normalPipe.stdout, "3\n")
        XCTAssertEqual(normalPipe.stderr, "err")
        XCTAssertEqual(normalPipe.exitCode, 0)
        XCTAssertEqual(stderrPipe.stdout, "6\n")
        XCTAssertEqual(stderrPipe.stderr, "")
        XCTAssertEqual(stderrPipe.exitCode, 0)
    }

    func testStreamingPipelinePipeAndStderrRoutesStreamingStageStderrIntoPipe() async throws {
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(registry: registry)
            .enable(.posixCore)

        let normalPipe = await shell.run("stream-both | wc -c")
        let stderrPipe = await shell.run("stream-both |& wc -c")

        XCTAssertEqual(normalPipe.stdout, "3\n")
        XCTAssertEqual(normalPipe.stderr, "err")
        XCTAssertEqual(normalPipe.exitCode, 0)
        XCTAssertEqual(stderrPipe.stdout, "6\n")
        XCTAssertEqual(stderrPipe.stderr, "")
        XCTAssertEqual(stderrPipe.exitCode, 0)
    }

    func testStreamingPipelineAggregatesModelContentItemsFromStreamingStages() async throws {
        let registry = try MSPCommandRegistry(commands: [
            StreamingModelContentCommand()
        ])
        let shell = try ModelShellProxy(registry: registry)
            .enable(.posixCore)

        let result = await shell.run("stream-model-content | wc -c")

        XCTAssertEqual(result.stdout, "3\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [.inputText("sidecar")])
    }

    func testStreamingPreparationPolicyFailureRecordsAudit() async throws {
        let audit = PipelineAuditCapture()
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                policyEngine: DenyCommandPolicyEngine(commandName: "stream-both", reason: "blocked"),
                auditSink: audit
            ),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run("stream-both | wc -c")
        let records = await audit.records()

        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.stderr, "stream-both: blocked\n")
        XCTAssertEqual(result.exitCode, 0)
        let failedStreamingRecord = records.first { $0.commandName == "stream-both" }
        XCTAssertEqual(failedStreamingRecord?.arguments, [])
        XCTAssertEqual(failedStreamingRecord?.exitCode, 126)
    }

    func testStreamingPreparationPolicyFailurePreservesCommandSubstitutionStderr() async throws {
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                policyEngine: DenyCommandPolicyEngine(commandName: "stream-both", reason: "blocked")
            ),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run(#"stream-both $(printf 'prep-err\n' >&2; printf arg) | wc -c"#)

        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.stderr, "prep-err\nstream-both: blocked\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPreparationPolicyFailureForwardsVisibleStderr() async throws {
        let errorOutput = StreamingOutputCapture()
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                policyEngine: DenyCommandPolicyEngine(commandName: "stream-both", reason: "blocked")
            ),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run(
            #"stream-both $(printf 'prep-visible\n' >&2; printf arg) | wc -c"#,
            errorStream: errorOutput
        )

        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.stderr, "prep-visible\nstream-both: blocked\n")
        XCTAssertEqual(result.exitCode, 0)
        let visibleStderr = await errorOutput.text()
        XCTAssertEqual(visibleStderr, "prep-visible\nstream-both: blocked\n")
    }

    func testStreamingPreparationPolicyFailureParticipatesInPipeAndStatuses() async throws {
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                policyEngine: DenyCommandPolicyEngine(commandName: "stream-both", reason: "blocked")
            ),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run(#"stream-both $(printf 'prep\n' >&2; printf arg) |& wc -c"#)
        let statuses = await shell.run(#"printf '%s\n' "${PIPESTATUS[*]}""#)

        XCTAssertEqual(result.stdout, "26\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(statuses.stdout, "126 0\n")
        XCTAssertEqual(statuses.stderr, "")
        XCTAssertEqual(statuses.exitCode, 0)
    }

    func testLaterStreamingPreparationPolicyFailureKeepsPipelineStatuses() async throws {
        let registry = try MSPCommandRegistry(commands: [
            StreamingNoopCommand(),
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(
                policyEngine: DenyCommandPolicyEngine(commandName: "stream-both", reason: "blocked")
            ),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run("stream-noop | stream-both")
        let statuses = await shell.run(#"printf '%s\n' "${PIPESTATUS[*]}""#)

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "stream-both: blocked\n")
        XCTAssertEqual(result.exitCode, 126)
        XCTAssertEqual(statuses.stdout, "0 126\n")
        XCTAssertEqual(statuses.stderr, "")
        XCTAssertEqual(statuses.exitCode, 0)
    }

    func testStreamingPreparationRedirectionFailureRecordsAuditAndPreservesCommandSubstitutionStderr() async throws {
        let audit = PipelineAuditCapture()
        let registry = try MSPCommandRegistry(commands: [
            StreamingBothCommand()
        ])
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(auditSink: audit),
            registry: registry
        )
        .enable(.posixCore)

        let result = await shell.run(#"stream-both $(printf 'prep-redir\n' >&2; printf arg) > out.txt | wc -c"#)
        let records = await audit.records()

        XCTAssertEqual(result.stdout, "0\n")
        XCTAssertEqual(result.stderr, "prep-redir\nshell: workspace is required for redirection\n")
        XCTAssertEqual(result.exitCode, 0)
        let failedStreamingRecord = records.first { $0.commandName == "stream-both" }
        XCTAssertEqual(failedStreamingRecord?.arguments, ["arg"])
        XCTAssertEqual(failedStreamingRecord?.exitCode, 1)
    }

    func testStreamingPipelineFallsBackWhenShellFunctionShadowsStreamingCommand() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("head() { echo fn; }; printf ok | head")

        XCTAssertEqual(result.stdout, "fn\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPreparationCleansEarlierProcessSubstitutionWhenLaterStageFallsBack() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("cat <(printf stage0) | { cat; }")

        XCTAssertEqual(result.stdout, "stage0")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let tmpURL = rootURL.appendingPathComponent("tmp")
        let leakedPaths = (try? FileManager.default.contentsOfDirectory(atPath: tmpURL.path)) ?? []
        XCTAssertFalse(
            leakedPaths.contains { $0.hasPrefix("msp-process-substitution.") },
            "process substitution temp paths should be cleaned after streaming preparation fallback"
        )
    }

    func testStreamingPipelinePreflightAvoidsDoubleProcessSubstitutionWhenLaterStageFallsBack() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run(#"cat <(printf hit >> marker.txt; printf stage0) | { cat; }; printf ':'; cat marker.txt"#)

        XCTAssertEqual(result.stdout, "stage0:hit")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let marker = try String(
            contentsOf: rootURL.appendingPathComponent("marker.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(marker, "hit")
    }

}

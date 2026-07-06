import Foundation
import MSPAgentBridge
import MSPCore
import XCTest

final class MSPExecCommandBridgeTests: XCTestCase {
    func testExecCommandSchemaIncludesCodexSessionArguments() throws {
        XCTAssertEqual(MSPExecCommandToolSchema.name, "exec_command")

        let data = Data(MSPExecCommandToolSchema.parametersJSON.utf8)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        XCTAssertEqual(object["required"] as? [String], ["cmd"])

        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), [
            "cmd",
            "workdir",
            "shell",
            "tty",
            "yield_time_ms",
            "max_output_tokens"
        ])

        let cmd = try XCTUnwrap(properties["cmd"] as? [String: Any])
        XCTAssertEqual(Set(cmd.keys), ["type"])
        XCTAssertEqual(cmd["type"] as? String, "string")

        let workdir = try XCTUnwrap(properties["workdir"] as? [String: Any])
        XCTAssertEqual(workdir["type"] as? String, "string")

        let shell = try XCTUnwrap(properties["shell"] as? [String: Any])
        XCTAssertEqual(shell["type"] as? String, "string")

        let tty = try XCTUnwrap(properties["tty"] as? [String: Any])
        XCTAssertEqual(tty["type"] as? String, "boolean")

        let yieldTime = try XCTUnwrap(properties["yield_time_ms"] as? [String: Any])
        XCTAssertEqual(yieldTime["type"] as? String, "number")
        XCTAssertTrue((yieldTime["description"] as? String)?.contains("effective range is 250-30000 ms") == true)

        let maxOutputTokens = try XCTUnwrap(properties["max_output_tokens"] as? [String: Any])
        XCTAssertEqual(maxOutputTokens["type"] as? String, "number")
        XCTAssertTrue((maxOutputTokens["description"] as? String)?.contains("Defaults to 10000 tokens") == true)

        let forbidden = Set(["stdout", "stderr", "exit_code", "tool_name", "ok"])
        XCTAssertTrue(forbidden.isDisjoint(with: Set(properties.keys)))
    }

    func testExecCommandToolDefinitionIsNotStrictBecauseOutputBudgetIsOptional() {
        let tool = MSPAgentRequestBuilder.execCommandToolDefinition

        XCTAssertEqual(tool.name, "exec_command")
        XCTAssertFalse(tool.strict)
        XCTAssertEqual(
            tool.parameters.objectValue?["required"],
            .array([.string("cmd")])
        )
    }

    func testWriteStdinToolDefinitionIsAvailableForSessionPolls() throws {
        XCTAssertEqual(MSPWriteStdinToolSchema.name, "write_stdin")

        let tool = MSPAgentRequestBuilder.writeStdinToolDefinition
        XCTAssertEqual(tool.name, "write_stdin")
        XCTAssertFalse(tool.strict)
        XCTAssertEqual(
            tool.parameters.objectValue?["required"],
            .array([.string("session_id")])
        )

        let data = Data(MSPWriteStdinToolSchema.parametersJSON.utf8)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), [
            "session_id",
            "chars",
            "yield_time_ms",
            "max_output_tokens"
        ])
        let yieldTime = try XCTUnwrap(properties["yield_time_ms"] as? [String: Any])
        XCTAssertTrue((yieldTime["description"] as? String)?.contains("empty polls wait 5000-300000 ms") == true)
    }

    func testPackageManifestsIncludeExecCommandSourcesUnderToolsOwner() throws {
        let root = Self.repositoryRoot()
        let rootManifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let implementationManifest = try String(
            contentsOf: root.appendingPathComponent("Implementations/Swift/Package.swift")
        )
        let execCommandOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/Tools/MSP/exec_command")
        let writeStdinOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/Tools/MSP/write_stdin")
        let misplacedCapabilityOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPAgentBridge/Capabilities/ExecCommand")
        let legacyDirectExecCommandOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPAgentBridge/ExecCommand")
        let legacyDirectToolSchemaOwner = root
            .appendingPathComponent("Implementations/Swift/Sources/MSPAgentBridge/ToolSchema")

        XCTAssertTrue(rootManifest.contains(#"path: "Implementations/Swift/Sources""#))
        XCTAssertTrue(implementationManifest.contains(#"path: "Sources""#))
        for manifest in [rootManifest, implementationManifest] {
            XCTAssertTrue(manifest.contains(#""MSPAgentBridge/Capabilities""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/exec_command/Contract""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/exec_command/Runtime""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/write_stdin/Contract""#))
            XCTAssertTrue(manifest.contains(#""Tools/MSP/write_stdin/Runtime""#))
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: execCommandOwner.appendingPathComponent("Contract/MSPExecCommandToolSchema.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writeStdinOwner.appendingPathComponent("Contract/MSPWriteStdinToolSchema.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: execCommandOwner.appendingPathComponent("Runtime/MSPExecCommandBridge.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: writeStdinOwner.appendingPathComponent("Runtime/MSPWriteStdinCall.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Schema/MSPExecCommandToolSchema.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Schema/MSPWriteStdinToolSchema.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Runtime/MSPExecCommandBridge.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: misplacedCapabilityOwner.appendingPathComponent("Runtime/MSPWriteStdinCall.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDirectExecCommandOwner.appendingPathComponent("MSPExecCommandBridge.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDirectExecCommandOwner.appendingPathComponent("MSPExecCommandCall.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDirectExecCommandOwner.appendingPathComponent("MSPExecCommandSessionCoordinator.swift").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDirectToolSchemaOwner.appendingPathComponent("MSPExecCommandToolSchema.swift").path
        ))
    }

    func testYieldPolicyMatchesCodexUnifiedExecBounds() {
        XCTAssertEqual(MSPExecCommandYieldPolicy.execMilliseconds(nil), 10_000)
        XCTAssertEqual(MSPExecCommandYieldPolicy.execMilliseconds(1), 250)
        XCTAssertEqual(MSPExecCommandYieldPolicy.execMilliseconds(1_000), 1_000)
        XCTAssertEqual(MSPExecCommandYieldPolicy.execMilliseconds(30_001), 30_000)

        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(nil, chars: "x"),
            250
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(1, chars: "x"),
            250
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(40_000, chars: "x"),
            30_000
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(nil, chars: ""),
            5_000
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(1_000, chars: ""),
            5_000
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.writeStdinMilliseconds(400_000, chars: ""),
            300_000
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.readExecMilliseconds(nil),
            0
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.readExecMilliseconds(-1),
            0
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.readExecMilliseconds(500),
            500
        )
        XCTAssertEqual(
            MSPExecCommandYieldPolicy.readExecMilliseconds(400_000),
            300_000
        )
    }

    func testExecCommandCallAcceptsCodexSessionArgumentsAndRejectsOtherKeys() throws {
        XCTAssertEqual(
            try MSPExecCommandCall(arguments: ["cmd": "ls"]).cmd,
            "ls"
        )
        let call = try MSPExecCommandCall(arguments: [
            "cmd": "ls",
            "workdir": "/workspace",
            "shell": "/bin/bash",
            "tty": "true",
            "yield_time_ms": "250",
            "max_output_tokens": "5"
        ])
        XCTAssertEqual(call.cmd, "ls")
        XCTAssertEqual(call.workdir, "/workspace")
        XCTAssertEqual(call.shell, "/bin/bash")
        XCTAssertTrue(call.tty)
        XCTAssertEqual(call.yieldTimeMilliseconds, 250)
        XCTAssertEqual(call.maxOutputTokens, 5)

        XCTAssertThrowsError(
            try MSPExecCommandCall(arguments: ["cmd": "ls", "cwd": "/"])
        ) { error in
            XCTAssertEqual(
                error as? MSPExecCommandCallError,
                .invalidArgumentKeys(["cmd", "cwd"])
            )
        }
        XCTAssertThrowsError(
            try MSPExecCommandCall(arguments: ["cmd": "ls", "max_output_tokens": "-1"])
        ) { error in
            XCTAssertEqual(
                error as? MSPExecCommandCallError,
                .invalidMaxOutputTokens("-1")
            )
        }
    }

    func testExecCommandCallParsesModelJSONArgumentsWithSameKeyValidation() throws {
        let call = try MSPExecCommandCall(arguments: [
            "cmd": .string("python3 -i"),
            "workdir": .string("/workspace"),
            "shell": .string("/bin/zsh"),
            "tty": .bool(true),
            "yield_time_ms": .number(250),
            "max_output_tokens": .number(5)
        ])

        XCTAssertEqual(call.cmd, "python3 -i")
        XCTAssertEqual(call.workdir, "/workspace")
        XCTAssertEqual(call.shell, "/bin/zsh")
        XCTAssertTrue(call.tty)
        XCTAssertEqual(call.yieldTimeMilliseconds, 250)
        XCTAssertEqual(call.maxOutputTokens, 5)

        XCTAssertThrowsError(
            try MSPExecCommandCall(arguments: [
                "cmd": .string("pwd"),
                "cwd": .string("/")
            ])
        ) { error in
            XCTAssertEqual(
                error as? MSPExecCommandCallError,
                .invalidArgumentKeys(["cmd", "cwd"])
            )
        }
        XCTAssertThrowsError(
            try MSPExecCommandCall(arguments: [
                "cmd": .string("ls"),
                "max_output_tokens": .number(1.5)
            ])
        ) { error in
            XCTAssertEqual(
                error as? MSPExecCommandCallError,
                .invalidMaxOutputTokens("1.5")
            )
        }
    }

    func testWriteStdinCallDefaultsEmptyCharsToPoll() throws {
        let call = try MSPWriteStdinCall(arguments: [
            "session_id": "92492",
            "yield_time_ms": "1000",
            "max_output_tokens": "50"
        ])

        XCTAssertEqual(call.sessionID, 92492)
        XCTAssertEqual(call.chars, "")
        XCTAssertEqual(call.yieldTimeMilliseconds, 1000)
        XCTAssertEqual(call.maxOutputTokens, 50)
    }

    func testWriteStdinCallParsesModelJSONArgumentsWithSameKeyValidation() throws {
        let call = try MSPWriteStdinCall(arguments: [
            "session_id": .number(92492),
            "chars": .string("hello\n"),
            "yield_time_ms": .number(1000),
            "max_output_tokens": .number(50)
        ])

        XCTAssertEqual(call.sessionID, 92492)
        XCTAssertEqual(call.chars, "hello\n")
        XCTAssertEqual(call.yieldTimeMilliseconds, 1000)
        XCTAssertEqual(call.maxOutputTokens, 50)

        XCTAssertThrowsError(
            try MSPWriteStdinCall(arguments: [
                "session_id": .number(92492),
                "stdin": .string("hello\n")
            ])
        ) { error in
            XCTAssertEqual(
                error as? MSPWriteStdinCallError,
                .invalidArgumentKeys(["session_id", "stdin"])
            )
        }
    }

    func testBridgeReturnsFormattedExecOutputWithoutJSONEnvelope() async throws {
        let bridge = MSPExecCommandBridge { cmd in
            XCTAssertEqual(cmd, "ls")
            return .success(stdout: "notes.txt\nreport.pdf\n")
        }

        let text = try await bridge.call(arguments: ["cmd": "ls"])

        XCTAssertEqual(
            text,
            "Wall time: 0.0000 seconds\n" +
            "Process exited with code 0\n" +
            "Output:\n" +
            "notes.txt\n" +
            "report.pdf\n"
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        XCTAssertFalse(text.contains(#""stdout""#))
        XCTAssertFalse(text.contains(#""exit_code""#))
    }

    func testBridgeRendersShellErrorEnvelopeWithoutJSONEnvelope() async throws {
        let bridge = MSPExecCommandBridge { _ in
            .failure(exitCode: 127, stderr: "missing: command not found\n")
        }

        let text = try await bridge.call(arguments: ["cmd": "missing"])

        XCTAssertEqual(
            text,
            "Wall time: 0.0000 seconds\n" +
            "Process exited with code 127\n" +
            "Output:\n" +
            "missing: command not found\n"
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        XCTAssertFalse(text.contains(#""stderr""#))
        XCTAssertFalse(text.contains(#""exit_code""#))
    }

    func testFormattedTruncationKeepsHeadAndTailWithTokenMarker() {
        XCTAssertEqual(
            MSPExecCommandOutputTruncation.formattedTruncateText(
                "example output",
                maxOutputTokens: 1
            ),
            "Total output lines: 1\n\nex…3 tokens truncated…ut"
        )
    }

    func testFormattedTruncationReturnsOriginalUnderLimit() {
        XCTAssertEqual(
            MSPExecCommandOutputTruncation.formattedTruncateText(
                "example output",
                maxOutputTokens: 10
            ),
            "example output"
        )
    }

    func testRendererFormatsTruncatedExecOutputEnvelope() {
        let text = MSPExecCommandRenderer.renderAgentText(
            from: .success(stdout: "this is an example of a long output that should be truncated"),
            options: MSPExecCommandRenderOptions(
                chunkID: "abc123",
                wallTimeSeconds: 1.25,
                maxOutputTokens: 5
            )
        )

        XCTAssertEqual(
            text,
            "Chunk ID: abc123\n" +
            "Wall time: 1.2500 seconds\n" +
            "Process exited with code 0\n" +
            "Output:\n" +
            "Total output lines: 1\n\n" +
            "this is an…10 tokens truncated… truncated"
        )
    }

    func testRendererFormatsEmptyExecOutputEnvelope() {
        let text = MSPExecCommandRenderer.renderAgentText(
            from: .success(),
            options: MSPExecCommandRenderOptions(
                chunkID: "0c2c3d",
                wallTimeSeconds: 0.5023,
                runningSessionID: 92492
            )
        )

        XCTAssertEqual(
            text,
            "Chunk ID: 0c2c3d\n" +
            "Wall time: 0.5023 seconds\n" +
            "Process running with session ID 92492\n" +
            "Output:\n"
        )
    }

    func testRendererAppliesTerminalBackspaceBeforeReturningAgentText() {
        let text = MSPExecCommandRenderer.renderAgentText(
            from: .success(stdout: ">>> subprocess.check_output(['printenv \u{8}'], text=True)\r\n"),
            options: MSPExecCommandRenderOptions(wallTimeSeconds: 0.25)
        )

        XCTAssertFalse(text.contains("\u{8}"))
        XCTAssertTrue(text.contains("subprocess.check_output(['printenv'], text=True)"))
    }

    func testRendererAppliesCarriageReturnLineOverwriteBeforeReturningAgentText() {
        let text = MSPExecCommandRenderer.renderAgentText(
            from: .success(stdout: "progress 10%\rprogress 20%\nabcdef\rxy\n"),
            options: MSPExecCommandRenderOptions(wallTimeSeconds: 0.25)
        )

        XCTAssertFalse(text.contains("progress 10%"))
        XCTAssertTrue(text.contains("progress 20%\n"))
        XCTAssertTrue(text.contains("xycdef\n"))
    }

    func testSessionCoordinatorYieldsRunningSessionAndPollsToCompletion() async throws {
        let transport = ScriptedExecSessionTransport(firstWriteCompletes: true)
        let coordinator = MSPExecCommandSessionCoordinator(
            transport: transport,
            firstSessionID: 92492
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: coordinator)

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -i",
            tty: true,
            yieldTimeMilliseconds: 30
        ))

        XCTAssertEqual(start.runningSessionID, 92492)
        XCTAssertEqual(start.result.stdout, "READY\n")
        let liveAfterStart = await coordinator.listSessionIDs()
        XCTAssertEqual(liveAfterStart, [92492])

        let startText = MSPExecCommandRenderer.renderAgentText(from: start)
        XCTAssertTrue(startText.contains("Process running with session ID 92492"))
        XCTAssertFalse(startText.contains("Original token count:"))

        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: 92492,
            chars: "",
            yieldTimeMilliseconds: 100
        ))

        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertEqual(poll.result.stdout, "READ\n")
        let liveAfterPoll = await coordinator.listSessionIDs()
        let writesAfterPoll = await transport.writes()
        let readWaitsAfterPoll = await transport.readWaits()
        XCTAssertEqual(liveAfterPoll, [])
        XCTAssertEqual(writesAfterPoll, [])
        XCTAssertEqual(readWaitsAfterPoll, [5_000])
    }

    func testSessionCoordinatorReadPollDoesNotWriteStdin() async throws {
        let transport = ScriptedExecSessionTransport(firstWriteCompletes: true)
        let coordinator = MSPExecCommandSessionCoordinator(
            transport: transport,
            firstSessionID: 41
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: coordinator)

        _ = await bridge.runSession(MSPExecCommandCall(
            cmd: "sleep 1",
            tty: true,
            yieldTimeMilliseconds: 30
        ))
        let read = await bridge.readSession(
            sessionID: 41,
            waitMilliseconds: 25
        )

        XCTAssertNil(read.runningSessionID)
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertEqual(read.result.stdout, "READ\n")
        let writes = await transport.writes()
        XCTAssertEqual(writes, [])
    }

    func testSessionCoordinatorKeepsSessionLiveAfterNonEmptyStdinWrite() async throws {
        let transport = ScriptedExecSessionTransport(firstWriteCompletes: false)
        let coordinator = MSPExecCommandSessionCoordinator(
            transport: transport,
            firstSessionID: 7
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: coordinator)

        _ = await bridge.runSession(MSPExecCommandCall(cmd: "cat", tty: true))
        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: 7,
            chars: "alpha\n",
            yieldTimeMilliseconds: 10
        ))

        XCTAssertEqual(write.runningSessionID, 7)
        XCTAssertEqual(write.result.stdout, "echo:alpha\n\n")
        let liveAfterWrite = await coordinator.listSessionIDs()
        let writesAfterWrite = await transport.writes()
        XCTAssertEqual(liveAfterWrite, [7])
        XCTAssertEqual(writesAfterWrite, ["alpha\n"])
    }

    func testSessionCoordinatorTerminateClosesLiveSession() async throws {
        let transport = ScriptedExecSessionTransport(firstWriteCompletes: false)
        let coordinator = MSPExecCommandSessionCoordinator(
            transport: transport,
            firstSessionID: 12
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: coordinator)

        _ = await bridge.runSession(MSPExecCommandCall(cmd: "sleep 300", yieldTimeMilliseconds: 1))
        let liveBeforeTerminate = await coordinator.listSessionIDs()
        XCTAssertEqual(liveBeforeTerminate, [12])

        let terminated = await bridge.terminateSession(12)

        XCTAssertNil(terminated.runningSessionID)
        XCTAssertEqual(terminated.exitCode, 143)
        XCTAssertEqual(terminated.result.stderr, "terminated\n")
        let liveAfterTerminate = await coordinator.listSessionIDs()
        let terminatedIDs = await transport.terminatedSessionIDs()
        XCTAssertEqual(liveAfterTerminate, [])
        XCTAssertEqual(terminatedIDs, [12])
    }

    func testSessionCoordinatorPrunesLeastRecentlyUsedSessionAtLiveCap() async throws {
        let transport = ScriptedExecSessionTransport(firstWriteCompletes: false)
        let coordinator = MSPExecCommandSessionCoordinator(
            transport: transport,
            firstSessionID: 100,
            maximumLiveSessionCount: 2,
            protectedRecentSessionCount: 1
        )
        let bridge = MSPExecCommandBridge(sessionCoordinator: coordinator)

        _ = await bridge.runSession(MSPExecCommandCall(cmd: "sleep 100", yieldTimeMilliseconds: 1))
        _ = await bridge.runSession(MSPExecCommandCall(cmd: "sleep 101", yieldTimeMilliseconds: 1))
        _ = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: 100,
            chars: "keepalive\n",
            yieldTimeMilliseconds: 1
        ))
        _ = await bridge.runSession(MSPExecCommandCall(cmd: "sleep 102", yieldTimeMilliseconds: 1))

        let liveAfterPrune = await coordinator.listSessionIDs()
        let terminatedIDs = await transport.terminatedSessionIDs()
        XCTAssertEqual(liveAfterPrune, [100, 102])
        XCTAssertEqual(terminatedIDs, [101])

        let prunedRead = await bridge.readSession(sessionID: 101)
        XCTAssertEqual(prunedRead.exitCode, 1)
        XCTAssertEqual(prunedRead.result.stderr, "read failed: inactive session 101\n")
    }
    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private actor ScriptedExecSessionTransport: MSPExecCommandSessionTransport {
    private let firstWriteCompletes: Bool
    private var recordedStarts: [MSPExecCommandCall] = []
    private var recordedWrites: [String] = []
    private var recordedReadWaits: [Int?] = []
    private var recordedTerminates: [Int] = []

    init(firstWriteCompletes: Bool) {
        self.firstWriteCompletes = firstWriteCompletes
    }

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedStarts.append(call)
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "READY\n"))
        return MSPExecCommandSessionRead(
            result: .success(stdout: "READY\n"),
            wallTimeSeconds: Double(call.yieldTimeMilliseconds ?? 0) / 1000,
            runningSessionID: sessionID
        )
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedWrites.append(call.chars)
        if firstWriteCompletes {
            await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "DONE\n"))
            return MSPExecCommandSessionRead(
                result: .success(stdout: "DONE\n"),
                wallTimeSeconds: Double(call.yieldTimeMilliseconds ?? 0) / 1000,
                exitCode: 0
            )
        }
        let output = "echo:\(call.chars)\n"
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: output))
        return MSPExecCommandSessionRead(
            result: .success(stdout: output),
            wallTimeSeconds: Double(call.yieldTimeMilliseconds ?? 0) / 1000,
            runningSessionID: call.sessionID
        )
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedReadWaits.append(waitMilliseconds)
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "READ\n"))
        return MSPExecCommandSessionRead(
            result: .success(stdout: "READ\n"),
            wallTimeSeconds: Double(waitMilliseconds ?? 0) / 1000,
            exitCode: 0
        )
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        recordedTerminates.append(sessionID)
        return MSPExecCommandSessionRead(
            result: .failure(exitCode: 143, stderr: "terminated\n"),
            exitCode: 143
        )
    }

    func starts() -> [MSPExecCommandCall] {
        recordedStarts
    }

    func writes() -> [String] {
        recordedWrites
    }

    func readWaits() -> [Int?] {
        recordedReadWaits
    }

    func terminatedSessionIDs() -> [Int] {
        recordedTerminates
    }
}

import Foundation
import MSPAgentBridge
import ModelShellProxy

struct GatedStreamingCommand: MSPStreamingCommand {
    let gate: GatedStreamingCommandGate

    var name: String { "gated-stream" }
    var summary: String? { "Test-only command that emits one chunk before it is allowed to finish." }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        await gate.waitForRelease()
        return .success(stdout: "first\nsecond\n")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard let standardOutput = context.standardOutputStream else {
            return .success(stdout: "first\nsecond\n")
        }
        try await standardOutput.write(Data("first\n".utf8))
        await gate.markFirstOutput()
        await gate.waitForRelease()
        try await standardOutput.write(Data("second\n".utf8))
        return .success()
    }
}

struct StreamingBothCommand: MSPStreamingCommand {
    var name: String { "stream-both" }
    var summary: String? { "Test-only streaming command that emits both stdout and stderr." }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        MSPCommandResult(stdout: "out", stderr: "err", exitCode: 7)
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let stdout = context.standardOutputStream {
            try await stdout.write(Data("out".utf8))
        }
        if let stderr = context.standardErrorStream {
            try await stderr.write(Data("err".utf8))
        }
        return MSPCommandResult(exitCode: 7)
    }
}

struct StreamingNoopCommand: MSPStreamingCommand {
    var name: String { "stream-noop" }
    var summary: String? { "Test-only streaming command that exits successfully without output." }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success()
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success()
    }
}

struct StreamingModelContentCommand: MSPStreamingCommand {
    var name: String { "stream-model-content" }
    var summary: String? { "Test-only streaming command that returns model content." }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "abc", modelContentItems: [.inputText("sidecar")])
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let stdout = context.standardOutputStream {
            try await stdout.write(Data("abc".utf8))
        }
        return .success(modelContentItems: [.inputText("sidecar")])
    }
}

struct DenyCommandPolicyEngine: MSPPolicyEngine {
    let commandName: String
    let reason: String

    func evaluate(_ request: MSPPolicyRequest) async -> MSPPolicyDecision {
        request.commandName == commandName ? .deny(reason: reason) : .allow
    }
}

actor PipelineAuditCapture: MSPAuditSink {
    private var capturedRecords: [MSPCommandRunRecord] = []

    func record(_ run: MSPCommandRunRecord) async {
        capturedRecords.append(run)
    }

    func records() -> [MSPCommandRunRecord] {
        capturedRecords
    }
}

actor GatedStreamingCommandGate {
    private var didWriteFirstOutput = false
    private var released = false
    private var firstOutputWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markFirstOutput() {
        didWriteFirstOutput = true
        let waiters = firstOutputWaiters
        firstOutputWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForFirstOutput() async {
        guard !didWriteFirstOutput else {
            return
        }
        await withCheckedContinuation { continuation in
            firstOutputWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForRelease() async {
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func isReleased() -> Bool {
        released
    }
}

actor StreamingOutputCapture: MSPCommandOutputStream {
    private var buffer = Data()

    func write(_ data: Data) async throws {
        buffer.append(data)
    }

    func closeWrite() async {}

    func text() -> String {
        String(decoding: buffer, as: UTF8.self)
    }
}

actor ExecCommandOutputEventCapture {
    private var events: [MSPExecCommandOutputEvent] = []

    func append(_ event: MSPExecCommandOutputEvent) {
        events.append(event)
    }

    func stdoutText() -> String {
        events
            .filter { $0.stream == .stdout }
            .map(\.text)
            .joined()
    }
}

enum AsyncTestTimeoutError: Error {
    case timedOut
}

func waitForAsyncEvent(
    timeoutNanoseconds: UInt64,
    operation: @escaping @Sendable () async -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw AsyncTestTimeoutError.timedOut
        }
        try await group.next()
        group.cancelAll()
    }
}

func waitUntil(
    timeoutNanoseconds: UInt64,
    operation: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await operation() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await operation()
}

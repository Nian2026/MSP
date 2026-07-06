import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


actor PollingSessionTransport: MSPExecCommandSessionTransport {
    private var recordedStarts: [MSPExecCommandCall] = []
    private var recordedWrites: [MSPWriteStdinCall] = []
    private var recordedReadWaits: [Int?] = []

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedStarts.append(call)
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "first\n"))
        return MSPExecCommandSessionRead(
            result: .success(stdout: "first\n"),
            wallTimeSeconds: 0.1,
            runningSessionID: sessionID
        )
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedWrites.append(call)
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "second\n"))
        return MSPExecCommandSessionRead(
            result: .success(stdout: "second\n"),
            wallTimeSeconds: 1.0,
            exitCode: 0
        )
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        recordedReadWaits.append(waitMilliseconds)
        await onOutput?(MSPExecCommandOutputEvent(stream: .stdout, text: "second\n"))
        return MSPExecCommandSessionRead(
            result: .success(stdout: "second\n"),
            wallTimeSeconds: Double(waitMilliseconds ?? 0) / 1000,
            exitCode: 0
        )
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(exitCode: 143, stderr: "terminated\n"),
            exitCode: 143
        )
    }

    func startedCommands() -> [String] {
        recordedStarts.map(\.cmd)
    }

    func writes() -> [String] {
        recordedWrites.map(\.chars)
    }

    func readWaits() -> [Int?] {
        recordedReadWaits
    }
}

actor SignalFailureSessionTransport: MSPExecCommandSessionTransport {
    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: MSPCommandResult(
                stdoutData: Data(),
                stderrData: Data("killed by signal\n".utf8),
                exitCode: 137
            ),
            wallTimeSeconds: 0.2,
            exitCode: 137,
            signal: 9
        )
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(exitCode: 1, stderr: "inactive\n"),
            exitCode: 1
        )
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(exitCode: 1, stderr: "inactive\n"),
            exitCode: 1
        )
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(exitCode: 143, stderr: "terminated\n"),
            exitCode: 143,
            signal: 15
        )
    }
}

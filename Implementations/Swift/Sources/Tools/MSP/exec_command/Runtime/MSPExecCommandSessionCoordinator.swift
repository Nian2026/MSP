import Foundation
import MSPCore

public struct MSPExecCommandSessionRead: Sendable, Equatable {
    public var result: MSPCommandResult
    public var wallTimeSeconds: Double
    public var runningSessionID: Int?
    public var exitCode: Int32?
    public var signal: Int32?

    public var isRunning: Bool {
        runningSessionID != nil
    }

    public init(
        result: MSPCommandResult,
        wallTimeSeconds: Double = 0,
        runningSessionID: Int? = nil,
        exitCode: Int32? = nil,
        signal: Int32? = nil
    ) {
        self.result = result
        self.wallTimeSeconds = max(0, wallTimeSeconds)
        self.runningSessionID = runningSessionID
        self.exitCode = exitCode
        self.signal = signal
    }
}

public protocol MSPExecCommandSessionTransport: Sendable {
    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead
}

public actor MSPExecCommandSessionCoordinator {
    public static let defaultMaximumLiveSessionCount = 64
    public static let defaultProtectedRecentSessionCount = 8

    private let transport: any MSPExecCommandSessionTransport
    private let maximumLiveSessionCount: Int
    private let protectedRecentSessionCount: Int
    private var nextSessionID: Int
    private var liveSessionIDs: Set<Int> = []
    private var lastUsedBySessionID: [Int: UInt64] = [:]
    private var lastUsedClock: UInt64 = 0

    public init(
        transport: any MSPExecCommandSessionTransport,
        firstSessionID: Int = 1,
        maximumLiveSessionCount: Int = 64,
        protectedRecentSessionCount: Int = 8
    ) {
        self.transport = transport
        self.maximumLiveSessionCount = max(1, maximumLiveSessionCount)
        self.protectedRecentSessionCount = max(0, protectedRecentSessionCount)
        self.nextSessionID = max(0, firstSessionID)
    }

    public func exec(
        _ call: MSPExecCommandCall,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        let sessionID = allocateSessionID()
        let read = await transport.start(
            call: call,
            sessionID: sessionID,
            onOutput: onOutput
        )
        return await register(read, preferredSessionID: sessionID)
    }

    public func writeStdin(
        _ call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        guard liveSessionIDs.contains(call.sessionID) else {
            return Self.inactiveSessionRead(
                sessionID: call.sessionID,
                operation: "write_stdin"
            )
        }
        if call.stdinBytes.isEmpty {
            let waitMilliseconds = MSPExecCommandYieldPolicy.writeStdinMilliseconds(
                call.yieldTimeMilliseconds,
                isEmpty: true
            )
            let read = await transport.read(
                sessionID: call.sessionID,
                waitMilliseconds: waitMilliseconds,
                onOutput: onOutput
            )
            return await register(read, preferredSessionID: call.sessionID)
        }
        let read = await transport.write(call: call, onOutput: onOutput)
        return await register(read, preferredSessionID: call.sessionID)
    }

    public func read(
        sessionID: Int,
        waitMilliseconds: Int? = nil,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        guard liveSessionIDs.contains(sessionID) else {
            return Self.inactiveSessionRead(sessionID: sessionID, operation: "read")
        }
        let read = await transport.read(
            sessionID: sessionID,
            waitMilliseconds: waitMilliseconds,
            onOutput: onOutput
        )
        return await register(read, preferredSessionID: sessionID)
    }

    public func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        guard liveSessionIDs.contains(sessionID) else {
            return Self.inactiveSessionRead(sessionID: sessionID, operation: "terminate")
        }
        let read = await transport.terminate(sessionID: sessionID)
        removeLiveSession(sessionID)
        return MSPExecCommandSessionRead(
            result: read.result,
            wallTimeSeconds: read.wallTimeSeconds,
            runningSessionID: nil,
            exitCode: completedExitCode(from: read),
            signal: read.signal
        )
    }

    public func listSessionIDs() -> [Int] {
        liveSessionIDs.sorted()
    }

    private func allocateSessionID() -> Int {
        let sessionID = nextSessionID
        nextSessionID += 1
        return sessionID
    }

    private func register(
        _ read: MSPExecCommandSessionRead,
        preferredSessionID: Int
    ) async -> MSPExecCommandSessionRead {
        if read.isRunning {
            await pruneSessionsIfNeeded(beforeInserting: preferredSessionID)
            liveSessionIDs.insert(preferredSessionID)
            markUsed(preferredSessionID)
            return MSPExecCommandSessionRead(
                result: read.result,
                wallTimeSeconds: read.wallTimeSeconds,
                runningSessionID: read.runningSessionID ?? preferredSessionID,
                exitCode: nil,
                signal: read.signal
            )
        }
        removeLiveSession(preferredSessionID)
        return MSPExecCommandSessionRead(
            result: read.result,
            wallTimeSeconds: read.wallTimeSeconds,
            runningSessionID: nil,
            exitCode: completedExitCode(from: read),
            signal: read.signal
        )
    }

    private func completedExitCode(from read: MSPExecCommandSessionRead) -> Int32? {
        if read.signal != nil {
            return read.exitCode
        }
        return read.exitCode ?? read.result.exitCode
    }

    private func markUsed(_ sessionID: Int) {
        lastUsedClock += 1
        lastUsedBySessionID[sessionID] = lastUsedClock
    }

    private func removeLiveSession(_ sessionID: Int) {
        liveSessionIDs.remove(sessionID)
        lastUsedBySessionID.removeValue(forKey: sessionID)
    }

    private func pruneSessionsIfNeeded(beforeInserting sessionID: Int) async {
        guard !liveSessionIDs.contains(sessionID) else {
            return
        }
        while liveSessionIDs.count >= maximumLiveSessionCount,
              let prunedSessionID = sessionIDToPrune() {
            removeLiveSession(prunedSessionID)
            _ = await transport.terminate(sessionID: prunedSessionID)
        }
    }

    private func sessionIDToPrune() -> Int? {
        guard !liveSessionIDs.isEmpty else {
            return nil
        }
        let entries = liveSessionIDs.map { sessionID in
            (sessionID: sessionID, lastUsed: lastUsedBySessionID[sessionID] ?? 0)
        }
        let protectedCount = min(
            protectedRecentSessionCount,
            max(0, entries.count - 1)
        )
        let protected = Set(
            entries
                .sorted { lhs, rhs in
                    if lhs.lastUsed == rhs.lastUsed {
                        return lhs.sessionID > rhs.sessionID
                    }
                    return lhs.lastUsed > rhs.lastUsed
                }
                .prefix(protectedCount)
                .map(\.sessionID)
        )
        return entries
            .filter { !protected.contains($0.sessionID) }
            .sorted { lhs, rhs in
                if lhs.lastUsed == rhs.lastUsed {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.lastUsed < rhs.lastUsed
            }
            .first?
            .sessionID
    }

    private static func inactiveSessionRead(
        sessionID: Int,
        operation: String
    ) -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "\(operation) failed: inactive session \(sessionID)\n"
            ),
            exitCode: 1
        )
    }
}

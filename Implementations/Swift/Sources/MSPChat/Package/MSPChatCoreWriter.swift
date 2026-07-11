import Foundation

private final class MSPChatPackageWriteLockRegistry: @unchecked Sendable {
    static let shared = MSPChatPackageWriteLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    private init() {}

    func withLock<T>(at packageURL: URL, _ body: () throws -> T) rethrows -> T {
        let packageLock = lock(for: packageURL)
        packageLock.lock()
        defer {
            packageLock.unlock()
        }
        return try body()
    }

    private func lock(for packageURL: URL) -> NSRecursiveLock {
        let key = packageURL.standardizedFileURL.path
        registryLock.lock()
        defer {
            registryLock.unlock()
        }
        if let lock = locks[key] {
            return lock
        }
        let lock = NSRecursiveLock()
        locks[key] = lock
        return lock
    }
}

public struct MSPChatCoreWriter {
    public init() {}

    public enum FlushPolicy: Sendable {
        case synchronize
        case deferToSystem
    }

    public enum AppendStateValidationPolicy: Sendable {
        case validateTimeline
        case trustManifestNextSeq
        case trustProvidedState
    }

    public static func withPackageWriteLock<T>(
        at packageURL: URL,
        _ body: () throws -> T
    ) rethrows -> T {
        try MSPChatPackageWriteLockRegistry.shared.withLock(at: packageURL, body)
    }

    public func createMinimalPackage(
        at packageURL: URL,
        packageID: String,
        createdAt: String,
        initialEvents: [MSPChatTimelineEvent],
        profiles: [String] = ["core-timeline"],
        capabilities: [String] = ["read_core", "write_core"]
    ) throws {
        let packageURL = packageURL.standardizedFileURL
        try Self.withPackageWriteLock(at: packageURL) {
            if FileManager.default.fileExists(atPath: packageURL.path) {
                throw MSPChatError.packageAlreadyExists(packageURL.path)
            }

            let manifest = try MSPChatManifest(
                packageID: packageID,
                createdAt: createdAt,
                profiles: profiles,
                capabilities: capabilities,
                timelineNextSeq: 1
            )

            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try MSPChatJSON.writeObject(manifest.rawJSON, to: packageURL.appendingPathComponent("manifest.json"))

            let timelineURL = packageURL.appendingPathComponent(manifest.timelinePath)
            try Data().write(to: timelineURL, options: .atomic)
            var appendState = MSPChatAppendState(
                packageURL: packageURL,
                manifest: manifest,
                nextSeq: 1
            )
            try appendEvents(
                initialEvents,
                to: packageURL,
                state: &appendState,
                updatedAt: createdAt
            )
        }
    }

    /// Reads and conditionally replaces `manifest.json` while holding the
    /// process-local package write lock. Returning `nil` leaves the manifest
    /// untouched. A host that has multiple writer processes must provide an
    /// outer cross-process lock.
    @discardableResult
    public func updateManifest(
        at packageURL: URL,
        _ update: (MSPChatManifest) throws -> MSPChatManifest?
    ) throws -> MSPChatManifest {
        let packageURL = packageURL.standardizedFileURL
        return try Self.withPackageWriteLock(at: packageURL) {
            let currentManifest = try MSPChatCoreReader().readManifest(at: packageURL)
            guard let updatedManifest = try update(currentManifest) else {
                return currentManifest
            }

            let timelineURL = packageURL.appendingPathComponent(updatedManifest.timelinePath)
            guard FileManager.default.fileExists(atPath: timelineURL.path) else {
                throw MSPChatError.missingTimeline(timelineURL.path)
            }
            try MSPChatJSON.writeObject(
                updatedManifest.rawJSON,
                to: packageURL.appendingPathComponent("manifest.json")
            )
            return updatedManifest
        }
    }

    public func appendMessage(
        to packageURL: URL,
        id: String,
        role: String,
        content: String,
        phase: String? = nil,
        createdAt: String,
        turnID: String? = nil
    ) throws -> MSPChatTimelineEvent {
        let packageURL = packageURL.standardizedFileURL
        return try Self.withPackageWriteLock(at: packageURL) {
            let state = try appendState(at: packageURL)
            let event = MSPChatTimelineEvent.message(
                id: id,
                seq: state.nextSeq,
                createdAt: createdAt,
                role: role,
                content: content,
                phase: phase,
                turnID: turnID
            )
            try appendEvents([event], to: packageURL, updatedAt: createdAt)
            return event
        }
    }

    public func appendEvents(
        _ events: [MSPChatTimelineEvent],
        to packageURL: URL,
        updatedAt: String,
        flushPolicy: FlushPolicy = .synchronize
    ) throws {
        guard !events.isEmpty else {
            return
        }

        let packageURL = packageURL.standardizedFileURL
        try Self.withPackageWriteLock(at: packageURL) {
            var state = try appendState(at: packageURL)
            try appendEvents(
                events,
                to: packageURL,
                state: &state,
                updatedAt: updatedAt,
                flushPolicy: flushPolicy
            )
        }
    }

    public func appendEvents(
        _ events: [MSPChatTimelineEvent],
        to packageURL: URL,
        state: inout MSPChatAppendState,
        updatedAt: String,
        flushPolicy: FlushPolicy = .synchronize,
        validationPolicy: AppendStateValidationPolicy = .validateTimeline
    ) throws {
        guard !events.isEmpty else {
            return
        }

        let packageURL = packageURL.standardizedFileURL
        try Self.withPackageWriteLock(at: packageURL) {
            guard state.packageURL.standardizedFileURL.path == packageURL.path else {
                throw MSPChatError.invalidAppendState("append state package \(state.packageURL.path) does not match target package \(packageURL.path).")
            }

            let currentState: MSPChatAppendState
            switch validationPolicy {
            case .validateTimeline:
                currentState = try appendState(at: packageURL, validationPolicy: .validateTimeline)
            case .trustManifestNextSeq:
                currentState = try appendState(at: packageURL, validationPolicy: .trustManifestNextSeq)
            case .trustProvidedState:
                currentState = state
            }
            guard currentState.nextSeq == state.nextSeq else {
                throw MSPChatError.invalidAppendState("append state next seq \(state.nextSeq) is stale; current package next seq is \(currentState.nextSeq).")
            }

            var expectedSeq = currentState.nextSeq
            for event in events {
                guard event.seq == expectedSeq else {
                    throw MSPChatError.invalidTimelineEvent("event \(event.id) has seq \(event.seq), expected \(expectedSeq).")
                }
                expectedSeq += 1
            }

            let timelineURL = packageURL.appendingPathComponent(currentState.manifest.timelinePath)
            try appendLines(
                events.map { try $0.jsonLineData() },
                to: timelineURL,
                flushPolicy: flushPolicy
            )

            let updatedManifestJSON = currentState.manifest.rawJSONWithUpdatedAt(
                updatedAt,
                timelineNextSeq: expectedSeq
            )
            try MSPChatJSON.writeObject(
                updatedManifestJSON,
                to: packageURL.appendingPathComponent("manifest.json")
            )
            state.manifest = try MSPChatManifest(rawJSON: updatedManifestJSON)
            state.nextSeq = expectedSeq
        }
    }

    public func appendState(
        at packageURL: URL,
        validationPolicy: AppendStateValidationPolicy = .validateTimeline
    ) throws -> MSPChatAppendState {
        let packageURL = packageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MSPChatError.packageNotDirectory(packageURL.path)
        }

        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw MSPChatError.missingManifest(manifestURL.path)
        }

        let manifestObject = try MSPChatJSON.readObject(from: manifestURL)
        let manifest = try MSPChatManifest(rawJSON: manifestObject)
        let timelineURL = packageURL.appendingPathComponent(manifest.timelinePath)
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            throw MSPChatError.missingTimeline(timelineURL.path)
        }

        if validationPolicy == .trustManifestNextSeq,
           let manifestNextSeq = manifest.timelineNextSeq,
           manifestNextSeq > 0 {
            return MSPChatAppendState(
                packageURL: packageURL,
                manifest: manifest,
                nextSeq: manifestNextSeq
            )
        }

        let validatedNextSeq = try MSPChatTimelineRecords.validatedNextSeq(from: timelineURL)
        let nextSeq: Int
        if let manifestNextSeq = manifest.timelineNextSeq,
           manifestNextSeq > 0 {
            nextSeq = max(manifestNextSeq, validatedNextSeq)
        } else {
            nextSeq = validatedNextSeq
        }
        return MSPChatAppendState(
            packageURL: packageURL,
            manifest: manifest,
            nextSeq: nextSeq
        )
    }

    private func appendLines(_ lines: [Data], to url: URL, flushPolicy: FlushPolicy) throws {
        let handle = try FileHandle(forUpdating: url)
        defer {
            try? handle.close()
        }

        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
        }
        let lastByte = endOffset > 0 ? try handle.read(upToCount: 1)?.first : nil
        try handle.seekToEnd()
        if endOffset > 0, lastByte != 0x0A {
            try handle.write(contentsOf: Data([0x0A]))
        }
        for line in lines {
            try handle.write(contentsOf: line)
        }
        if flushPolicy == .synchronize {
            try handle.synchronize()
        }
    }
}

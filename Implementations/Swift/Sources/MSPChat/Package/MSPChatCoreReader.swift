import Foundation

public struct MSPChatTimelineReadResult: Equatable, Sendable {
    public var manifest: MSPChatManifest
    public var nextSeq: Int

    public init(manifest: MSPChatManifest, nextSeq: Int) {
        self.manifest = manifest
        self.nextSeq = nextSeq
    }
}

public struct MSPChatCoreReader {
    public init() {}

    public func readManifest(at packageURL: URL) throws -> MSPChatManifest {
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

        return manifest
    }

    public func readPackage(at packageURL: URL) throws -> MSPChatPackage {
        let packageURL = packageURL.standardizedFileURL
        let manifest = try readManifest(at: packageURL)
        let timelineURL = packageURL.appendingPathComponent(manifest.timelinePath)
        let events = try MSPChatTimelineRecords.readEvents(from: timelineURL)

        return MSPChatPackage(packageURL: packageURL, manifest: manifest, timelineEvents: events)
    }

    public func forEachTimelineEvent(
        at packageURL: URL,
        _ body: (MSPChatTimelineEvent) throws -> Void
    ) throws -> MSPChatTimelineReadResult {
        let packageURL = packageURL.standardizedFileURL
        let manifest = try readManifest(at: packageURL)
        return try forEachTimelineEvent(at: packageURL, manifest: manifest, body)
    }

    public func forEachTimelineEvent(
        at packageURL: URL,
        manifest: MSPChatManifest,
        _ body: (MSPChatTimelineEvent) throws -> Void
    ) throws -> MSPChatTimelineReadResult {
        let packageURL = packageURL.standardizedFileURL
        let timelineURL = packageURL.appendingPathComponent(manifest.timelinePath)
        guard FileManager.default.fileExists(atPath: timelineURL.path) else {
            throw MSPChatError.missingTimeline(timelineURL.path)
        }
        let nextSeq = try MSPChatTimelineRecords.forEachEvent(from: timelineURL, body)
        return MSPChatTimelineReadResult(manifest: manifest, nextSeq: nextSeq)
    }
}

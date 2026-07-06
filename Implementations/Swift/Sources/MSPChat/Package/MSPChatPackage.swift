import Foundation

public struct MSPChatPackage: Equatable, Sendable {
    public var packageURL: URL
    public var manifest: MSPChatManifest
    public var timelineEvents: [MSPChatTimelineEvent]

    public var nextSeq: Int {
        (timelineEvents.map(\.seq).max() ?? 0) + 1
    }
}

public struct MSPChatAppendState: Equatable, Sendable {
    public var packageURL: URL
    public var manifest: MSPChatManifest
    public var nextSeq: Int

    public init(packageURL: URL, manifest: MSPChatManifest, nextSeq: Int) {
        self.packageURL = packageURL.standardizedFileURL
        self.manifest = manifest
        self.nextSeq = nextSeq
    }

    public init(package: MSPChatPackage) {
        self.init(
            packageURL: package.packageURL,
            manifest: package.manifest,
            nextSeq: package.nextSeq
        )
    }
}

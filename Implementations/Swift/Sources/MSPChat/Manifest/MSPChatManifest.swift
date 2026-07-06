public struct MSPChatManifest: Equatable, Sendable {
    public var format: String
    public var version: Int
    public var packageID: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var profiles: [String]
    public var capabilities: [String]
    public var timelinePath: String
    public var timelineNextSeq: Int?
    public var rawJSON: [String: MSPChatJSONValue]

    public init(rawJSON: [String: MSPChatJSONValue]) throws {
        guard let format = rawJSON["format"]?.stringValue else {
            throw MSPChatError.invalidManifest("manifest.format is required.")
        }
        guard format == MSPChat.formatIdentifier else {
            throw MSPChatError.invalidManifest("manifest.format must be \(MSPChat.formatIdentifier).")
        }
        guard let version = rawJSON["version"]?.intValue else {
            throw MSPChatError.invalidManifest("manifest.version must be an integer.")
        }
        let profiles = rawJSON["profiles"]?.stringArrayValue ?? []
        guard profiles.contains("core-timeline") else {
            throw MSPChatError.invalidManifest("manifest.profiles must include core-timeline.")
        }
        let timelineObject = rawJSON["timeline"]?.objectValue
        let timelinePath = timelineObject?["path"]?.stringValue ?? MSPChat.defaultTimelinePath
        try MSPChatManifest.validateTimelinePath(timelinePath)

        self.format = format
        self.version = version
        self.packageID = rawJSON["package_id"]?.stringValue
        self.createdAt = rawJSON["created_at"]?.stringValue
        self.updatedAt = rawJSON["updated_at"]?.stringValue
        self.profiles = profiles
        self.capabilities = rawJSON["capabilities"]?.stringArrayValue ?? []
        self.timelinePath = timelinePath
        self.timelineNextSeq = timelineObject?["next_seq"]?.intValue
        self.rawJSON = rawJSON
    }

    public init(
        packageID: String,
        createdAt: String,
        updatedAt: String? = nil,
        profiles: [String] = ["core-timeline"],
        capabilities: [String] = ["read_core", "write_core"],
        timelinePath: String = MSPChat.defaultTimelinePath,
        timelineNextSeq: Int = 1
    ) throws {
        try MSPChatManifest.validateTimelinePath(timelinePath)
        let raw: [String: MSPChatJSONValue] = [
            "format": .string(MSPChat.formatIdentifier),
            "version": .int(MSPChat.schemaVersion),
            "package_id": .string(packageID),
            "created_at": .string(createdAt),
            "updated_at": .string(updatedAt ?? createdAt),
            "profiles": .array(profiles.map { .string($0) }),
            "capabilities": .array(capabilities.map { .string($0) }),
            "timeline": .object([
                "path": .string(timelinePath),
                "encoding": .string("utf-8"),
                "record_format": .string("ndjson"),
                "next_seq": .int(timelineNextSeq)
            ])
        ]
        try self.init(rawJSON: raw)
    }

    public func rawJSONWithUpdatedAt(_ updatedAt: String, timelineNextSeq: Int? = nil) -> [String: MSPChatJSONValue] {
        var raw = rawJSON
        raw["updated_at"] = .string(updatedAt)
        if let timelineNextSeq {
            var timelineObject = raw["timeline"]?.objectValue ?? [:]
            timelineObject["next_seq"] = .int(timelineNextSeq)
            raw["timeline"] = .object(timelineObject)
        }
        return raw
    }

    private static func validateTimelinePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else {
            throw MSPChatError.unsafeTimelinePath(path)
        }
    }
}

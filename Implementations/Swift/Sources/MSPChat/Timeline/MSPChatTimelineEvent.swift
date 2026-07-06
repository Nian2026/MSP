import Foundation

public struct MSPChatTimelineEvent: Equatable, Sendable {
    public var id: String
    public var type: String
    public var seq: Int
    public var createdAt: String
    public var durability: String
    public var turnID: String?
    public var actor: String?
    public var parentID: String?
    public var correlationID: String?
    public var callID: String?
    public var payload: [String: MSPChatJSONValue]
    public var rawJSON: [String: MSPChatJSONValue]
    public var sourceLine: Int?

    public init(rawJSON: [String: MSPChatJSONValue], sourceLine: Int? = nil) throws {
        guard let id = rawJSON["id"]?.stringValue, !id.isEmpty else {
            throw MSPChatError.invalidTimelineEvent("event id is required.")
        }
        guard let type = rawJSON["type"]?.stringValue, !type.isEmpty else {
            throw MSPChatError.invalidTimelineEvent("event type is required for \(id).")
        }
        guard let seq = rawJSON["seq"]?.intValue else {
            throw MSPChatError.invalidTimelineEvent("event seq must be an integer for \(id).")
        }
        guard let createdAt = rawJSON["created_at"]?.stringValue, !createdAt.isEmpty else {
            throw MSPChatError.invalidTimelineEvent("event created_at is required for \(id).")
        }
        guard let durability = rawJSON["durability"]?.stringValue, !durability.isEmpty else {
            throw MSPChatError.invalidTimelineEvent("event durability is required for \(id).")
        }
        guard let payload = rawJSON["payload"]?.objectValue else {
            throw MSPChatError.invalidTimelineEvent("event payload object is required for \(id).")
        }

        self.id = id
        self.type = type
        self.seq = seq
        self.createdAt = createdAt
        self.durability = durability
        self.turnID = rawJSON["turn_id"]?.stringValue
        self.actor = rawJSON["actor"]?.stringValue
        self.parentID = rawJSON["parent_id"]?.stringValue
        self.correlationID = rawJSON["correlation_id"]?.stringValue
        self.callID = rawJSON["call_id"]?.stringValue
        self.payload = payload
        self.rawJSON = rawJSON
        self.sourceLine = sourceLine
    }

    public init(
        id: String,
        type: String,
        seq: Int,
        createdAt: String,
        durability: String = "durable_replay",
        turnID: String? = nil,
        actor: String? = nil,
        parentID: String? = nil,
        correlationID: String? = nil,
        callID: String? = nil,
        payload: [String: MSPChatJSONValue]
    ) {
        var raw: [String: MSPChatJSONValue] = [
            "id": .string(id),
            "type": .string(type),
            "seq": .int(seq),
            "created_at": .string(createdAt),
            "durability": .string(durability),
            "payload": .object(payload)
        ]
        raw["turn_id"] = turnID.map { .string($0) }
        raw["actor"] = actor.map { .string($0) }
        raw["parent_id"] = parentID.map { .string($0) }
        raw["correlation_id"] = correlationID.map { .string($0) }
        raw["call_id"] = callID.map { .string($0) }

        self.id = id
        self.type = type
        self.seq = seq
        self.createdAt = createdAt
        self.durability = durability
        self.turnID = turnID
        self.actor = actor
        self.parentID = parentID
        self.correlationID = correlationID
        self.callID = callID
        self.payload = payload
        self.rawJSON = raw
        self.sourceLine = nil
    }

    public static func message(
        id: String,
        seq: Int,
        createdAt: String,
        role: String,
        content: String,
        phase: String? = nil,
        turnID: String? = nil,
        durability: String = "durable_replay"
    ) -> MSPChatTimelineEvent {
        var payload: [String: MSPChatJSONValue] = [
            "role": .string(role),
            "content": .string(content)
        ]
        if let phase {
            payload["phase"] = .string(phase)
        }
        return MSPChatTimelineEvent(
            id: id,
            type: "message",
            seq: seq,
            createdAt: createdAt,
            durability: durability,
            turnID: turnID,
            payload: payload
        )
    }

    public func jsonLineData() throws -> Data {
        var data = try MSPChatJSON.writeJSONObject(rawJSON, prettyPrinted: false)
        data.append(0x0A)
        return data
    }
}

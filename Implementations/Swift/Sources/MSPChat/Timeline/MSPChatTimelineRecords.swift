import Foundation

enum MSPChatTimelineRecords {
    static func readEvents(from url: URL) throws -> [MSPChatTimelineEvent] {
        var events: [MSPChatTimelineEvent] = []
        _ = try forEachEvent(from: url) { event in
            events.append(event)
        }
        return events
    }

    static func validatedNextSeq(from url: URL) throws -> Int {
        try forEachEvent(from: url) { _ in }
    }

    static func forEachEvent(
        from url: URL,
        _ body: (MSPChatTimelineEvent) throws -> Void
    ) throws -> Int {
        var seen = Set<String>()
        var previousSeq: Int?
        var maxSeq = 0
        try MSPChatJSON.forEachNDJSONObject(from: url) { line, object in
            let event = try MSPChatTimelineEvent(rawJSON: object, sourceLine: line)
            if seen.contains(event.id) {
                throw MSPChatError.invalidTimelineEvent("duplicate event id \(event.id).")
            }
            seen.insert(event.id)
            if let previousSeq, event.seq <= previousSeq {
                throw MSPChatError.invalidTimelineEvent("timeline seq must be strictly increasing at \(event.id).")
            }
            previousSeq = event.seq
            maxSeq = max(maxSeq, event.seq)
            try body(event)
        }
        return maxSeq + 1
    }
}

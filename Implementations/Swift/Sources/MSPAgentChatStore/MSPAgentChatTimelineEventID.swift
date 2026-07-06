import Foundation

enum MSPAgentChatTimelineEventID {
    static func make(prefix: String, seq: Int) -> String {
        "evt_\(prefix)_\(seq)_\(UUID().uuidString.lowercased())"
    }
}

import Foundation

struct MSPContextCompactionItem: Codable, Hashable, Sendable {
    var id: String

    init(id: String = UUID().uuidString) {
        self.id = id
    }
}

enum MSPCompactionLifecycleEvent: Hashable, Sendable {
    case started(MSPContextCompactionItem, operation: MSPCompactionOperation)
    case completed(MSPContextCompactionItem, operation: MSPCompactionOperation)
    case failed(MSPContextCompactionItem?, operation: MSPCompactionOperation, message: String)
    case interrupted(operation: MSPCompactionOperation)
    case warning(String)
}

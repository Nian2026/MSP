import Foundation

enum MSPCompactionHookOutcome: Hashable, Sendable {
    case `continue`
    case stop(reason: String?)

    var shouldStop: Bool {
        if case .stop = self {
            return true
        }
        return false
    }
}

protocol MSPCompactionLifecycleHookRuntime: Sendable {
    func preCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome
    func postCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome
}

struct MSPNoopCompactionLifecycleHookRuntime: MSPCompactionLifecycleHookRuntime {
    func preCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        .continue
    }

    func postCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        .continue
    }
}

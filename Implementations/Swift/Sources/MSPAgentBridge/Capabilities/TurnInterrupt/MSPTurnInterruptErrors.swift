import Foundation

public enum MSPTurnInterruptError: Error, Equatable, LocalizedError, Sendable {
    case capabilityDisabled
    case threadMismatch(expected: String, actual: String)
    case startupInterruptUnsupported
    case noActiveTurn(turnID: String)
    case activeTurnMismatch(requested: String, active: String)
    case terminalTurn(turnID: String, status: MSPTurnInterruptTurnStatus)

    public var errorDescription: String? {
        switch self {
        case .capabilityDisabled:
            return "Turn interrupt capability is disabled."
        case let .threadMismatch(expected, actual):
            return "expected thread id `\(expected)` but found `\(actual)`"
        case .startupInterruptUnsupported:
            return "startup interrupt is not supported by this capability."
        case .noActiveTurn:
            return "no active turn to interrupt"
        case let .activeTurnMismatch(requested, active):
            return "expected active turn id \(requested) but found \(active)"
        case let .terminalTurn(turnID, status):
            return "turn \(turnID) is already terminal with status \(status.rawValue)"
        }
    }
}

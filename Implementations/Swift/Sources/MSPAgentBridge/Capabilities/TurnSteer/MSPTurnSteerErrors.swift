import Foundation

public enum MSPTurnSteerRejectionReason: String, Hashable, Sendable {
    case capabilityDisabled = "capability_disabled"
    case threadMismatch = "thread_mismatch"
    case emptyExpectedTurnID = "empty_expected_turn_id"
    case emptyInput = "empty_input"
    case noActiveTurn = "no_active_turn"
    case expectedTurnMismatch = "expected_turn_mismatch"
    case activeTurnNotSteerable = "active_turn_not_steerable"
    case terminalTurn = "terminal_turn"
    case interruptedTurn = "interrupted_turn"
}

public enum MSPTurnSteerError: Error, Equatable, LocalizedError, Sendable {
    case capabilityDisabled
    case threadMismatch(expected: String, actual: String)
    case emptyExpectedTurnID
    case emptyInput
    case noActiveTurn(turnID: String)
    case expectedTurnMismatch(expected: String, actual: String)
    case activeTurnNotSteerable(turnID: String, kind: MSPTurnSteerTurnKind)
    case terminalTurn(turnID: String, status: MSPTurnSteerTurnStatus)
    case interruptedTurn(turnID: String, status: MSPTurnSteerTurnStatus)

    public var reason: MSPTurnSteerRejectionReason {
        switch self {
        case .capabilityDisabled:
            return .capabilityDisabled
        case .threadMismatch:
            return .threadMismatch
        case .emptyExpectedTurnID:
            return .emptyExpectedTurnID
        case .emptyInput:
            return .emptyInput
        case .noActiveTurn:
            return .noActiveTurn
        case .expectedTurnMismatch:
            return .expectedTurnMismatch
        case .activeTurnNotSteerable:
            return .activeTurnNotSteerable
        case .terminalTurn:
            return .terminalTurn
        case .interruptedTurn:
            return .interruptedTurn
        }
    }

    public var errorDescription: String? {
        switch self {
        case .capabilityDisabled:
            return "Turn steer capability is disabled."
        case let .threadMismatch(expected, actual):
            return "expected thread id `\(expected)` but found `\(actual)`"
        case .emptyExpectedTurnID:
            return "expectedTurnId must not be empty"
        case .emptyInput:
            return "input must not be empty"
        case .noActiveTurn:
            return "no active turn to steer"
        case let .expectedTurnMismatch(expected, actual):
            return "expected active turn id `\(expected)` but found `\(actual)`"
        case let .activeTurnNotSteerable(turnID, kind):
            return "cannot steer \(kind.rawValue) turn \(turnID)"
        case let .terminalTurn(turnID, status):
            return "turn \(turnID) is already terminal with status \(status.rawValue)"
        case let .interruptedTurn(turnID, status):
            return "turn \(turnID) cannot be steered while status is \(status.rawValue)"
        }
    }
}

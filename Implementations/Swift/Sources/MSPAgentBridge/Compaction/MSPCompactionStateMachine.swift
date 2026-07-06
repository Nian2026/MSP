import Foundation

enum MSPCompactionLogicalState: String, Codable, Hashable, Sendable {
    case idle
    case checkingPreTurn = "checking_pre_turn"
    case runningTurn = "running_turn"
    case samplingCompleted = "sampling_completed"
    case checkingMidTurn = "checking_mid_turn"
    case runningPreCompactHook = "running_pre_compact_hook"
    case emittingContextCompactionStart = "emitting_context_compaction_start"
    case runningCompaction = "running_compaction"
    case installingReplacement = "installing_replacement"
    case recomputingUsage = "recomputing_usage"
    case runningPostCompactHook = "running_post_compact_hook"
    case continueTurn = "continue_turn"
    case completed
    case failed
    case aborted
}

struct MSPCompactionOperation: Codable, Hashable, Sendable {
    var id: String
    var decision: MSPCompactionDecision
    var startedAt: Date

    init(
        id: String = UUID().uuidString,
        decision: MSPCompactionDecision,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.decision = decision
        self.startedAt = startedAt
    }
}

struct MSPCompactionTransition: Codable, Hashable, Sendable {
    var from: MSPCompactionLogicalState
    var to: MSPCompactionLogicalState
    var operationID: String?
    var status: MSPCompactionStatus?
}

struct MSPCompactionStateMachine: Codable, Hashable, Sendable {
    private(set) var state: MSPCompactionLogicalState
    private(set) var activeOperation: MSPCompactionOperation?
    private(set) var transitions: [MSPCompactionTransition]

    init(
        state: MSPCompactionLogicalState = .idle,
        activeOperation: MSPCompactionOperation? = nil,
        transitions: [MSPCompactionTransition] = []
    ) {
        self.state = state
        self.activeOperation = activeOperation
        self.transitions = transitions
    }

    mutating func begin(_ operation: MSPCompactionOperation) {
        activeOperation = operation
        move(to: .runningPreCompactHook)
    }

    mutating func markPreCompactHookCompleted() {
        move(to: .emittingContextCompactionStart)
    }

    mutating func markStartedItemEmitted() {
        move(to: .runningCompaction)
    }

    mutating func markReplacementInstalled() {
        move(to: .recomputingUsage)
    }

    mutating func markUsageRecomputed() {
        move(to: .runningPostCompactHook)
    }

    mutating func complete() {
        move(to: .completed, status: .completed)
        activeOperation = nil
    }

    mutating func fail() {
        move(to: .failed, status: .failed)
        activeOperation = nil
    }

    mutating func abort() {
        move(to: .aborted, status: .interrupted)
        activeOperation = nil
    }

    private mutating func move(
        to nextState: MSPCompactionLogicalState,
        status: MSPCompactionStatus? = nil
    ) {
        transitions.append(MSPCompactionTransition(
            from: state,
            to: nextState,
            operationID: activeOperation?.id,
            status: status
        ))
        state = nextState
    }
}

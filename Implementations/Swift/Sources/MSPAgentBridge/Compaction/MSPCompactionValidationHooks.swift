import Foundation

struct MSPCompactionValidationSnapshot: Hashable, Sendable {
    var operation: MSPCompactionOperation
    var requestMetadata: MSPAgentJSONValue?
    var replacementHistory: [MSPAgentJSONValue]
    var checkpoint: MSPCompactionCheckpoint?
}

protocol MSPCompactionValidationHook: Sendable {
    func capture(_ snapshot: MSPCompactionValidationSnapshot) async
}

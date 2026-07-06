import Foundation

public struct MSPApplyPatchCall: Hashable, Sendable {
    public var callID: String
    public var patch: String
    public var cwd: String?

    public init(
        callID: String,
        patch: String,
        cwd: String? = nil
    ) {
        self.callID = callID
        self.patch = patch
        self.cwd = cwd
    }
}

public struct MSPApplyPatchExecutionResult: Hashable, Sendable {
    public var ok: Bool
    public var output: String
    public var changedPaths: [String]
    public var exactDelta: Bool?
    public var internalContent: MSPAgentJSONValue?
    public var modelOutputContent: MSPAgentJSONValue?
    public var errorMessage: String?

    public init(
        ok: Bool,
        output: String,
        changedPaths: [String] = [],
        exactDelta: Bool? = nil,
        internalContent: MSPAgentJSONValue? = nil,
        modelOutputContent: MSPAgentJSONValue? = nil,
        errorMessage: String? = nil
    ) {
        self.ok = ok
        self.output = output
        self.changedPaths = changedPaths
        self.exactDelta = exactDelta
        self.internalContent = internalContent
        self.modelOutputContent = modelOutputContent
        self.errorMessage = errorMessage
    }
}

public protocol MSPApplyPatchExecuting: Sendable {
    func execute(_ call: MSPApplyPatchCall) async -> MSPApplyPatchExecutionResult
}

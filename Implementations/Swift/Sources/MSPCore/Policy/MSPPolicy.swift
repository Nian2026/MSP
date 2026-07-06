public struct MSPPolicyRequest: Sendable, Equatable {
    public var commandName: String
    public var arguments: [String]
    public var currentDirectory: String

    public init(commandName: String, arguments: [String], currentDirectory: String) {
        self.commandName = commandName
        self.arguments = arguments
        self.currentDirectory = currentDirectory
    }
}

public enum MSPPolicyDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case requiresConfirmation(prompt: String)
}

public protocol MSPPolicyEngine: Sendable {
    func evaluate(_ request: MSPPolicyRequest) async -> MSPPolicyDecision
}

public struct MSPAllowAllPolicyEngine: MSPPolicyEngine {
    public init() {}

    public func evaluate(_ request: MSPPolicyRequest) async -> MSPPolicyDecision {
        .allow
    }
}

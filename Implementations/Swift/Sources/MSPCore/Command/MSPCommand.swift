import Foundation

public protocol MSPCommand: Sendable {
    var name: String { get }
    var summary: String? { get }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult
}

public protocol MSPCommandLookupPathProviding: Sendable {
    var commandLookupPaths: [String] { get }
}

public struct MSPCommandInvocation: Sendable, Equatable {
    public var name: String
    public var arguments: [String]
    public var rawInput: String

    public init(name: String, arguments: [String] = [], rawInput: String = "") {
        self.name = name
        self.arguments = arguments
        self.rawInput = rawInput
    }
}

public typealias MSPSubcommandRunner = @Sendable (
    MSPCommandInvocation,
    MSPCommandContext
) async -> MSPCommandResult

public typealias MSPCommandLineRunner = @Sendable (
    String,
    MSPCommandContext
) async -> MSPCommandResult

public struct MSPCommandContext: Sendable {
    public var workspace: (any MSPWorkspace)?
    public var currentDirectory: String
    public var environment: [String: String]
    public var standardInput: Data
    public var standardInputClosed: Bool
    public var standardInputOverridesFileDescriptor: Bool
    public var standardInputStream: (any MSPCommandInputStream)?
    public var standardOutputStream: (any MSPCommandOutputStream)?
    public var standardErrorStream: (any MSPCommandOutputStream)?
    public var fileCreationMask: UInt16
    public var availableCommandNames: [String]
    public var commandLookupPaths: [String: [String]]
    public var subcommandRunner: MSPSubcommandRunner?
    public var commandLineRunner: MSPCommandLineRunner?
    public var policyEngine: any MSPPolicyEngine
    public var auditSink: any MSPAuditSink

    public init(
        workspace: (any MSPWorkspace)? = nil,
        currentDirectory: String = "/",
        environment: [String: String] = [:],
        standardInput: Data = Data(),
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        standardInputStream: (any MSPCommandInputStream)? = nil,
        standardOutputStream: (any MSPCommandOutputStream)? = nil,
        standardErrorStream: (any MSPCommandOutputStream)? = nil,
        fileCreationMask: UInt16 = 0o022,
        availableCommandNames: [String] = [],
        commandLookupPaths: [String: [String]] = [:],
        subcommandRunner: MSPSubcommandRunner? = nil,
        commandLineRunner: MSPCommandLineRunner? = nil,
        policyEngine: any MSPPolicyEngine = MSPAllowAllPolicyEngine(),
        auditSink: any MSPAuditSink = MSPNoopAuditSink()
    ) {
        self.workspace = workspace
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.standardInputClosed = standardInputClosed
        self.standardInputOverridesFileDescriptor = standardInputOverridesFileDescriptor
        self.standardInputStream = standardInputStream
        self.standardOutputStream = standardOutputStream
        self.standardErrorStream = standardErrorStream
        self.fileCreationMask = fileCreationMask & 0o777
        self.availableCommandNames = availableCommandNames
        self.commandLookupPaths = commandLookupPaths
        self.subcommandRunner = subcommandRunner
        self.commandLineRunner = commandLineRunner
        self.policyEngine = policyEngine
        self.auditSink = auditSink
    }

    public func maskedCreationMode(base: UInt16) -> UInt16 {
        (base & ~fileCreationMask) & 0o777
    }

    public var regularFileCreationMode: UInt16 {
        maskedCreationMode(base: 0o666)
    }

    public var directoryCreationMode: UInt16 {
        maskedCreationMode(base: 0o777)
    }

    public func runSubcommand(
        name: String,
        arguments: [String],
        rawInput: String? = nil,
        standardInput: Data = Data(),
        environment: [String: String]? = nil
    ) async -> MSPCommandResult {
        guard let subcommandRunner else {
            return .failure(exitCode: 125, stderr: "\(name): subcommand execution is not available\n")
        }
        var childContext = self
        childContext.standardInput = standardInput
        childContext.standardInputClosed = false
        if let environment {
            childContext.environment = environment
        }
        return await subcommandRunner(
            MSPCommandInvocation(
                name: name,
                arguments: arguments,
                rawInput: rawInput ?? ([name] + arguments).joined(separator: " ")
            ),
            childContext
        )
    }

    public func runCommandLine(
        _ commandLine: String,
        standardInput: Data = Data(),
        environment: [String: String]? = nil
    ) async -> MSPCommandResult {
        guard let commandLineRunner else {
            return .failure(exitCode: 125, stderr: "shell: command-line execution is not available\n")
        }
        var childContext = self
        childContext.standardInput = standardInput
        childContext.standardInputClosed = false
        if let environment {
            childContext.environment = environment
        }
        return await commandLineRunner(commandLine, childContext)
    }
}

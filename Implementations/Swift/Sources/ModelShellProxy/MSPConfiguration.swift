import Foundation
import MSPCore

public enum MSPShellDiagnosticProfile: Sendable, Equatable {
    case bash(scriptName: String)
    case dash(scriptName: String)
}

public struct MSPConfiguration {
    public var workspace: (any MSPWorkspace)?
    public var currentDirectory: String
    public var environment: [String: String]
    public var standardInput: Data
    public var standardInputClosed: Bool
    public var standardInputStream: (any MSPCommandInputStream)?
    public var standardOutputStream: (any MSPCommandOutputStream)?
    public var standardErrorStream: (any MSPCommandOutputStream)?
    public var fileCreationMask: UInt16
    public var shellDiagnosticProfile: MSPShellDiagnosticProfile?
    public var policyEngine: any MSPPolicyEngine
    public var auditSink: any MSPAuditSink

    public init(
        workspace: (any MSPWorkspace)? = nil,
        currentDirectory: String = "/",
        environment: [String: String] = [:],
        standardInput: Data = Data(),
        standardInputClosed: Bool = false,
        standardInputStream: (any MSPCommandInputStream)? = nil,
        standardOutputStream: (any MSPCommandOutputStream)? = nil,
        standardErrorStream: (any MSPCommandOutputStream)? = nil,
        fileCreationMask: UInt16 = 0o022,
        shellDiagnosticProfile: MSPShellDiagnosticProfile? = nil,
        policyEngine: any MSPPolicyEngine = MSPAllowAllPolicyEngine(),
        auditSink: any MSPAuditSink = MSPNoopAuditSink()
    ) {
        self.workspace = workspace
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.standardInputClosed = standardInputClosed
        self.standardInputStream = standardInputStream
        self.standardOutputStream = standardOutputStream
        self.standardErrorStream = standardErrorStream
        self.fileCreationMask = fileCreationMask & 0o777
        self.shellDiagnosticProfile = shellDiagnosticProfile
        self.policyEngine = policyEngine
        self.auditSink = auditSink
    }

    public func makeCommandContext(
        availableCommandNames: [String] = [],
        commandLookupPaths: [String: [String]] = [:],
        subcommandRunner: MSPSubcommandRunner? = nil,
        commandLineRunner: MSPCommandLineRunner? = nil
    ) -> MSPCommandContext {
        makeCommandContext(
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputStream: standardInputStream,
            standardOutputStream: standardOutputStream,
            standardErrorStream: standardErrorStream,
            availableCommandNames: availableCommandNames,
            commandLookupPaths: commandLookupPaths,
            subcommandRunner: subcommandRunner,
            commandLineRunner: commandLineRunner
        )
    }

    public func makeCommandContext(
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputStream: (any MSPCommandInputStream)? = nil,
        standardOutputStream: (any MSPCommandOutputStream)? = nil,
        standardErrorStream: (any MSPCommandOutputStream)? = nil,
        availableCommandNames: [String] = [],
        commandLookupPaths: [String: [String]] = [:],
        subcommandRunner: MSPSubcommandRunner? = nil,
        commandLineRunner: MSPCommandLineRunner? = nil
    ) -> MSPCommandContext {
        var commandEnvironment = environment
        commandEnvironment["PWD"] = currentDirectory
        if commandEnvironment["HOME"] == nil {
            commandEnvironment["HOME"] = "/"
        }
        return MSPCommandContext(
            workspace: workspace,
            currentDirectory: currentDirectory,
            environment: commandEnvironment,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputStream: standardInputStream,
            standardOutputStream: standardOutputStream,
            standardErrorStream: standardErrorStream,
            fileCreationMask: fileCreationMask,
            availableCommandNames: availableCommandNames,
            commandLookupPaths: commandLookupPaths,
            subcommandRunner: subcommandRunner,
            commandLineRunner: commandLineRunner,
            policyEngine: policyEngine,
            auditSink: auditSink
        )
    }
}

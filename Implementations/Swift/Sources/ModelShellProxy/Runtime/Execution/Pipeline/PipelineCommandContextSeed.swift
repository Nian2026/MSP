import Foundation
import MSPCore

struct ShellPipelineCommandContextSeed {
    var workspace: (any MSPWorkspace)?
    var currentDirectory: String
    var environment: [String: String]
    var standardInput: Data
    var standardInputClosed: Bool
    var standardInputStream: (any MSPCommandInputStream)?
    var fileCreationMask: UInt16
    var policyEngine: any MSPPolicyEngine
    var auditSink: any MSPAuditSink

    init(configuration: MSPConfiguration) {
        self.workspace = configuration.workspace
        self.currentDirectory = configuration.currentDirectory
        self.environment = configuration.environment
        self.standardInput = configuration.standardInput
        self.standardInputClosed = configuration.standardInputClosed
        self.standardInputStream = configuration.standardInputStream
        self.fileCreationMask = configuration.fileCreationMask
        self.policyEngine = configuration.policyEngine
        self.auditSink = configuration.auditSink
    }

    func makeCommandContext(
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
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
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
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

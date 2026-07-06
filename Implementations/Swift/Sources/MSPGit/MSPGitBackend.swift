import Foundation
import MSPCore

public struct MSPGitCommandRequest: Sendable, Equatable {
    public var modelArgv: [String]
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String
    public var standardInput: Data
    public var standardInputClosed: Bool
    public var workspaceMapping: MSPGitWorkspaceMapping?

    public init(
        modelArgv: [String],
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: String = "/",
        standardInput: Data = Data(),
        standardInputClosed: Bool = false,
        workspaceMapping: MSPGitWorkspaceMapping? = nil
    ) {
        self.modelArgv = modelArgv
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = MSPWorkspacePathResolver.normalize(currentDirectory)
        self.standardInput = standardInput
        self.standardInputClosed = standardInputClosed
        self.workspaceMapping = workspaceMapping
    }
}

public protocol MSPGitBackend: Sendable {
    func run(
        _ request: MSPGitCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult
}

public struct MSPGitUnavailableBackend: MSPGitBackend {
    public var reason: String

    public init(reason: String = "libgit2 backend is not configured") {
        self.reason = reason
    }

    public func run(
        _ request: MSPGitCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .failure(exitCode: 127, stderr: "git: \(reason)\n")
    }
}

public enum MSPGitCompatibilityProfile {
    public static let linuxOracleSeedSubcommands: Set<String> = [
        "add",
        "commit",
        "diff",
        "init",
        "log",
        "ls-files",
        "show",
        "status"
    ]

    public static func firstSubcommand(in arguments: [String]) -> String? {
        var skipsNextValue = false
        for argument in arguments {
            if skipsNextValue {
                skipsNextValue = false
                continue
            }
            if argument == "--" {
                return nil
            }
            if argument == "-C" || argument == "-c" {
                skipsNextValue = true
                continue
            }
            if argument.hasPrefix("--git-dir=") || argument.hasPrefix("--work-tree=") {
                continue
            }
            if argument == "--git-dir" || argument == "--work-tree" {
                skipsNextValue = true
                continue
            }
            if argument.hasPrefix("-") {
                continue
            }
            return argument
        }
        return nil
    }
}

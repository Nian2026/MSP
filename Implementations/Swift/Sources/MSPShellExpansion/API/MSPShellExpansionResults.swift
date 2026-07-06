import Foundation
import MSPShellLanguage

public enum MSPShellExpansionError: Error, Sendable, Equatable, CustomStringConvertible {
    case badSubstitution(String)
    case expansionFailed(String)
    case arithmetic(String)

    public var description: String {
        switch self {
        case .badSubstitution(let expression):
            return "bad substitution: \(expression)"
        case .expansionFailed(let message):
            return message
        case .arithmetic(let message):
            return "arithmetic expansion: \(message)"
        }
    }
}

public struct MSPShellCommandSubstitutionResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct MSPShellCommandSubstitutionExpansion: Sendable, Equatable {
    public var commandLine: MSPParsedCommandLine
    public var stderr: String
    public var state: MSPShellExpansionState

    public var environment: [String: String] {
        get { state.environment }
        set { state.environment = newValue }
    }

    public var arrays: [String: MSPShellIndexedArray] {
        get { state.arrays }
        set { state.arrays = newValue }
    }

    public var associativeArrays: [String: [String: String]] {
        get { state.associativeArrays }
        set { state.associativeArrays = newValue }
    }

    public init(
        commandLine: MSPParsedCommandLine,
        stderr: String = "",
        state: MSPShellExpansionState
    ) {
        self.commandLine = commandLine
        self.stderr = stderr
        self.state = state
    }

    public init(
        commandLine: MSPParsedCommandLine,
        stderr: String = "",
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:]
    ) {
        self.init(
            commandLine: commandLine,
            stderr: stderr,
            state: MSPShellExpansionState(
                environment: environment,
                arrays: arrays,
                associativeArrays: associativeArrays
            )
        )
    }
}

public struct MSPShellProcessSubstitutionRequest: Sendable, Equatable {
    public var mode: MSPShellProcessSubstitutionMode
    public var command: String

    public init(mode: MSPShellProcessSubstitutionMode, command: String) {
        self.mode = mode
        self.command = command
    }
}

public struct MSPShellProcessSubstitutionResult: Sendable, Equatable {
    public var path: String
    public var stderr: String

    public init(path: String, stderr: String = "") {
        self.path = path
        self.stderr = stderr
    }
}

public typealias MSPShellProcessSubstitutionResolver = @Sendable (
    MSPShellProcessSubstitutionRequest
) async throws -> MSPShellProcessSubstitutionResult

public struct MSPShellWordExpansionResult: Sendable, Equatable {
    public var values: [String]
    public var stderr: String
    public var state: MSPShellExpansionState

    public var environment: [String: String] {
        get { state.environment }
        set { state.environment = newValue }
    }

    public var arrays: [String: MSPShellIndexedArray] {
        get { state.arrays }
        set { state.arrays = newValue }
    }

    public var associativeArrays: [String: [String: String]] {
        get { state.associativeArrays }
        set { state.associativeArrays = newValue }
    }

    public init(
        values: [String],
        stderr: String = "",
        state: MSPShellExpansionState
    ) {
        self.values = values
        self.stderr = stderr
        self.state = state
    }

    public init(
        values: [String],
        stderr: String = "",
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:]
    ) {
        self.init(
            values: values,
            stderr: stderr,
            state: MSPShellExpansionState(
                environment: environment,
                arrays: arrays,
                associativeArrays: associativeArrays
            )
        )
    }
}

public struct MSPShellWordTextExpansionResult: Sendable, Equatable {
    public var value: String
    public var stderr: String
    public var state: MSPShellExpansionState

    public var environment: [String: String] {
        get { state.environment }
        set { state.environment = newValue }
    }

    public var arrays: [String: MSPShellIndexedArray] {
        get { state.arrays }
        set { state.arrays = newValue }
    }

    public var associativeArrays: [String: [String: String]] {
        get { state.associativeArrays }
        set { state.associativeArrays = newValue }
    }

    public init(
        value: String,
        stderr: String = "",
        state: MSPShellExpansionState
    ) {
        self.value = value
        self.stderr = stderr
        self.state = state
    }

    public init(
        value: String,
        stderr: String = "",
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:]
    ) {
        self.init(
            value: value,
            stderr: stderr,
            state: MSPShellExpansionState(
                environment: environment,
                arrays: arrays,
                associativeArrays: associativeArrays
            )
        )
    }
}

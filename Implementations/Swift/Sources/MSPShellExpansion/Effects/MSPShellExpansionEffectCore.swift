import Foundation
import MSPShellLanguage

struct MSPShellTextExpansionCore {
    var commandSubstitutions: MSPShellTextExpansionScanner.CommandSubstitutionRecognition

    func expandText(
        _ text: String,
        resolve: (MSPShellTextExpansionScanner.Step) throws -> String
    ) throws -> String {
        var result = ""
        let scanner = MSPShellTextExpansionScanner(
            text: text,
            commandSubstitutions: commandSubstitutions
        )
        for step in try scanner.steps() {
            result += try resolve(step)
        }
        return result
    }

    func expandText(
        _ text: String,
        resolveAsync: (MSPShellTextExpansionScanner.Step) async throws -> String
    ) async throws -> String {
        var result = ""
        let scanner = MSPShellTextExpansionScanner(
            text: text,
            commandSubstitutions: commandSubstitutions
        )
        for step in try scanner.steps() {
            result += try await resolveAsync(step)
        }
        return result
    }
}

struct MSPShellSyncExpansionEffectAdapter {
    func preservedCommandSubstitution(rawText: String) -> String {
        rawText
    }

    func processSubstitutionPath(
        mode: MSPShellProcessSubstitutionMode
    ) throws -> String {
        throw MSPShellExpansionError.expansionFailed(
            "\(mode.operatorText)(: process substitution requires shell runtime execution"
        )
    }
}

struct MSPShellAsyncExpansionEffectAdapter {
    var commandSubstitutionResolver: @Sendable (String) async throws -> MSPShellCommandSubstitutionResult
    var processSubstitutionResolver: MSPShellProcessSubstitutionResolver?
    private(set) var stderr = ""

    mutating func commandSubstitutionOutput(_ command: String) async throws -> String {
        let result = try await commandSubstitutionResolver(command)
        stderr += result.stderr
        return Self.strippingTrailingNewlines(result.stdout)
    }

    mutating func processSubstitutionPath(
        mode: MSPShellProcessSubstitutionMode,
        command: String
    ) async throws -> String {
        guard let processSubstitutionResolver else {
            throw MSPShellExpansionError.expansionFailed(
                "\(mode.operatorText)(: process substitution is not available"
            )
        }
        let result = try await processSubstitutionResolver(
            MSPShellProcessSubstitutionRequest(mode: mode, command: command)
        )
        stderr += result.stderr
        return result.path
    }

    private static func strippingTrailingNewlines(_ text: String) -> String {
        var output = text
        while output.hasSuffix("\n") {
            output.removeLast()
        }
        return output
    }
}

enum MSPShellExpansionMutation {
    case assignDefault(value: String, target: MSPShellParameterAssignmentTarget)
}

extension MSPShellExpansionContext {
    mutating func apply(_ mutation: MSPShellExpansionMutation) {
        switch mutation {
        case .assignDefault(let value, let target):
            assignDefaultValue(value, to: target)
        }
    }

    private mutating func assignDefaultValue(
        _ value: String,
        to target: MSPShellParameterAssignmentTarget
    ) {
        switch target {
        case .scalar(let name):
            environment[name] = value
        case .associativeArrayElement(let name, let key):
            associativeArrays[name]?[key] = value
        case .indexedArrayElement(let name, let index):
            var array = arrays[name] ?? MSPShellIndexedArray()
            array.assign(value, at: index)
            arrays[name] = array
            environment[name] = array.first ?? ""
        }
    }
}

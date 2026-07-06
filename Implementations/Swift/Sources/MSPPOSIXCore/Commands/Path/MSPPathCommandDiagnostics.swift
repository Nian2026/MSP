import Foundation
import MSPCore

enum MSPPathCommandDiagnostics {
    static func parse(
        _ spec: MSPPOSIXCommandSpec,
        arguments: [String],
        stopAtFirstOperand: Bool = false
    ) throws -> MSPPOSIXParsedArguments {
        do {
            return try spec.parse(arguments, stopAtFirstOperand: stopAtFirstOperand)
        } catch let failure as MSPCommandFailure {
            throw mapOptionFailure(failure, command: spec.name)
        }
    }

    static func missingOperand(_ command: String) -> MSPCommandFailure {
        MSPCommandFailure(
            result: .failure(
                exitCode: 1,
                stderr: "\(command): missing operand\n\(helpHint(command))"
            )
        )
    }

    static func extraOperand(_ command: String, _ operand: String) -> MSPCommandFailure {
        MSPCommandFailure(
            result: .failure(
                exitCode: 1,
                stderr: "\(command): extra operand \(MSPPOSIXCommandSupport.gnuQuote(operand))\n\(helpHint(command))"
            )
        )
    }

    private static func mapOptionFailure(
        _ failure: MSPCommandFailure,
        command: String
    ) -> MSPCommandFailure {
        let stderr = failure.result.stderr
        let unsupportedPrefix = "\(command): unsupported option -- "
        let requiresArgumentPrefix = "\(command): option requires an argument -- "

        if stderr.hasPrefix(unsupportedPrefix) {
            let option = stderr
                .dropFirst(unsupportedPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if option.count == 1 {
                message = "\(command): invalid option -- '\(option)'\n"
            } else {
                message = "\(command): unrecognized option '--\(option)'\n"
            }
            return MSPCommandFailure(
                result: .failure(exitCode: 1, stderr: message + helpHint(command))
            )
        }

        if stderr.hasPrefix(requiresArgumentPrefix) {
            let option = stderr
                .dropFirst(requiresArgumentPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "\(command): option requires an argument -- '\(option)'\n\(helpHint(command))"
                )
            )
        }

        return failure
    }

    private static func helpHint(_ command: String) -> String {
        "Try '\(command) --help' for more information.\n"
    }
}

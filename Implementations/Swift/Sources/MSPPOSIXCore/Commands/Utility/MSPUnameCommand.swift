import Foundation
import MSPCore

public struct MSPUnameCommand: MSPCommand {
    public let name = "uname"
    public let summary: String? = "Print virtual Linux system information."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = mspUnameParse(arguments: invocation.arguments)
        if let result = parsed.result {
            return result
        }
        guard parsed.operands.isEmpty else {
            return .failure(
                exitCode: 1,
                stderr: "uname: extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[0]))\n" + mspUnameHelpHint()
            )
        }

        var fields = parsed.fields
        if fields.isEmpty {
            fields.insert(.kernelName)
        }

        let isAll = parsed.requestedAll
        let values = MSPPOSIXVirtualIdentity.unameFields.compactMap { field -> String? in
            guard fields.contains(field) else {
                return nil
            }
            let value = field.value
            if isAll, (field == .processor || field == .hardwarePlatform), value == "unknown" {
                return nil
            }
            return value
        }
        return .success(stdout: values.joined(separator: " ") + "\n")
    }
}

private func mspUnameParse(arguments: [String]) -> (fields: Set<MSPUnameField>, requestedAll: Bool, operands: [String], result: MSPCommandResult?) {
    var fields: Set<MSPUnameField> = []
    var requestedAll = false
    var operands: [String] = []
    var parsingOptions = true

    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            switch argument {
            case "--all":
                fields = Set(MSPUnameField.allCases)
                requestedAll = true
            case "--kernel-name", "--sysname":
                fields.insert(.kernelName)
            case "--nodename":
                fields.insert(.nodeName)
            case "--kernel-release", "--release":
                fields.insert(.kernelRelease)
            case "--kernel-version":
                fields.insert(.kernelVersion)
            case "--machine":
                fields.insert(.machine)
            case "--processor":
                fields.insert(.processor)
            case "--hardware-platform":
                fields.insert(.hardwarePlatform)
            case "--operating-system":
                fields.insert(.operatingSystem)
            case "--help":
                return (fields, requestedAll, operands, .success(stdout: mspUnameUsage()))
            case "--version":
                return (fields, requestedAll, operands, .success(stdout: "uname (GNU coreutils) 9.1\n"))
            default:
                return (fields, requestedAll, operands, .failure(exitCode: 1, stderr: "uname: unrecognized option '\(argument)'\n" + mspUnameHelpHint()))
            }
            continue
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            for option in argument.dropFirst() {
                switch option {
                case "a":
                    fields = Set(MSPUnameField.allCases)
                    requestedAll = true
                case "s":
                    fields.insert(.kernelName)
                case "n":
                    fields.insert(.nodeName)
                case "r":
                    fields.insert(.kernelRelease)
                case "v":
                    fields.insert(.kernelVersion)
                case "m":
                    fields.insert(.machine)
                case "p":
                    fields.insert(.processor)
                case "i":
                    fields.insert(.hardwarePlatform)
                case "o":
                    fields.insert(.operatingSystem)
                default:
                    return (fields, requestedAll, operands, .failure(exitCode: 1, stderr: "uname: invalid option -- '\(option)'\n" + mspUnameHelpHint()))
                }
            }
            continue
        }
        operands.append(argument)
    }

    return (fields, requestedAll, operands, nil)
}

enum MSPUnameField: CaseIterable, Hashable {
    case kernelName
    case nodeName
    case kernelRelease
    case kernelVersion
    case machine
    case processor
    case hardwarePlatform
    case operatingSystem

    var value: String {
        switch self {
        case .kernelName:
            return "Linux"
        case .nodeName:
            return MSPPOSIXVirtualIdentity.profile.hostName
        case .kernelRelease:
            return "6.1.0-48-amd64"
        case .kernelVersion:
            return "#1 SMP PREEMPT_DYNAMIC Debian 6.1.172-1 (2026-05-15)"
        case .machine:
            return "x86_64"
        case .processor, .hardwarePlatform:
            return "unknown"
        case .operatingSystem:
            return "GNU/Linux"
        }
    }
}

private func mspUnameHelpHint() -> String {
    "Try 'uname --help' for more information.\n"
}

private func mspUnameUsage() -> String {
    """
    Usage: uname [OPTION]...
    Print certain system information.  With no OPTION, same as -s.

    """
}

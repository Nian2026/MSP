import MSPCore

public struct MSPIdCommand: MSPCommand {
    public let name = "id"
    public let summary: String? = "Print virtual user and group IDs."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = mspIdParse(arguments: invocation.arguments)
        if let result = parsed.result {
            return result
        }
        if parsed.justContext {
            return .failure(
                exitCode: 1,
                stderr: "id: --context (-Z) works only on an SELinux-enabled kernel\n"
            )
        }
        if [parsed.justUser, parsed.justGroup, parsed.justGroupList].filter({ $0 }).count > 1 {
            return .failure(exitCode: 1, stderr: "id: cannot print \"only\" of more than one choice\n")
        }
        let defaultFormat = !(parsed.justUser || parsed.justGroup || parsed.justGroupList)
        if defaultFormat, parsed.useName {
            return .failure(exitCode: 1, stderr: "id: cannot print only names in default format\n")
        }
        if defaultFormat, parsed.useReal {
            return .failure(exitCode: 1, stderr: "id: cannot print only real IDs in default format\n")
        }
        if defaultFormat, parsed.zeroTerminated {
            return .failure(exitCode: 1, stderr: "id: option --zero not permitted in default format\n")
        }

        let users: [MSPPOSIXVirtualUser]
        if parsed.operands.isEmpty {
            users = [MSPPOSIXVirtualIdentity.currentUser]
        } else {
            var resolved: [MSPPOSIXVirtualUser] = []
            var stderr = ""
            var ok = true
            for operand in parsed.operands {
                if let user = MSPPOSIXVirtualIdentity.user(namedOrID: operand) {
                    resolved.append(user)
                } else {
                    stderr += "id: \(MSPPOSIXCommandSupport.gnuQuote(operand)): no such user\n"
                    ok = false
                }
            }
            if !ok {
                return MSPCommandResult(stderr: stderr, exitCode: 1)
            }
            users = resolved
        }

        let separator = parsed.zeroTerminated ? "\0" : "\n"
        let stdout = users.map { user in
            mspIdRender(user: user, options: parsed)
        }.joined(separator: separator)
        return .success(stdout: stdout + separator)
    }
}

private struct MSPIdOptions {
    var justUser = false
    var justGroup = false
    var justGroupList = false
    var justContext = false
    var useName = false
    var useReal = false
    var zeroTerminated = false
    var operands: [String] = []
    var result: MSPCommandResult?
}

private func mspIdParse(arguments: [String]) -> MSPIdOptions {
    var options = MSPIdOptions()
    var parsingOptions = true

    for argument in arguments {
        if parsingOptions, argument == "--" {
            parsingOptions = false
            continue
        }
        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            switch argument {
            case "--context":
                options.justContext = true
            case "--group":
                options.justGroup = true
            case "--groups":
                options.justGroupList = true
            case "--name":
                options.useName = true
            case "--real":
                options.useReal = true
            case "--user":
                options.justUser = true
            case "--zero":
                options.zeroTerminated = true
            case "--help":
                options.result = .success(stdout: mspIdUsage())
                return options
            case "--version":
                options.result = .success(stdout: "id (GNU coreutils) 9.1\n")
                return options
            default:
                options.result = .failure(exitCode: 1, stderr: "id: unrecognized option '\(argument)'\n" + mspIdHelpHint())
                return options
            }
            continue
        }
        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            for option in argument.dropFirst() {
                switch option {
                case "a":
                    continue
                case "Z":
                    options.justContext = true
                case "g":
                    options.justGroup = true
                case "G":
                    options.justGroupList = true
                case "n":
                    options.useName = true
                case "r":
                    options.useReal = true
                case "u":
                    options.justUser = true
                case "z":
                    options.zeroTerminated = true
                default:
                    options.result = .failure(exitCode: 1, stderr: "id: invalid option -- '\(option)'\n" + mspIdHelpHint())
                    return options
                }
            }
            continue
        }
        options.operands.append(argument)
    }

    return options
}

private func mspIdRender(user: MSPPOSIXVirtualUser, options: MSPIdOptions) -> String {
    if options.justUser {
        return options.useName ? user.name : "\(user.uid)"
    }
    if options.justGroup {
        return options.useName ? user.groupName : "\(user.gid)"
    }
    if options.justGroupList {
        return options.useName ? user.groupName : "\(user.gid)"
    }
    return "uid=\(user.uid)(\(user.name)) gid=\(user.gid)(\(user.groupName)) groups=\(user.gid)(\(user.groupName))"
}

private func mspIdHelpHint() -> String {
    "Try 'id --help' for more information.\n"
}

private func mspIdUsage() -> String {
    """
    Usage: id [OPTION]... [USER]...
    Print user and group information for each specified USER.

    """
}

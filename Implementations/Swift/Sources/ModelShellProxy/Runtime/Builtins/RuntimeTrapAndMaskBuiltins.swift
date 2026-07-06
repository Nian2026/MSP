import Foundation
import MSPCore

extension RuntimeBuiltinContext {
    mutating func executeTrapCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard !arguments.isEmpty else {
            return .success(stdout: formattedTraps(for: Array(shellTraps.keys).sorted()))
        }

        var arguments = arguments
        if arguments.first == "--" {
            arguments.removeFirst()
        }
        guard !arguments.isEmpty else {
            return .failure(exitCode: 2, stderr: "trap: usage: trap [-lp] [[arg] signal_spec ...]\n")
        }

        if arguments.first == "-l" {
            return .success(stdout: formattedTrapSignalList())
        }

        if arguments.first == "-p" {
            let requested = Array(arguments.dropFirst())
            let signals: [String]
            if requested.isEmpty {
                signals = Array(shellTraps.keys).sorted()
            } else {
                do {
                    signals = try requested.map { try canonicalTrapSignal($0) }
                } catch let failure as MSPCommandFailure {
                    return failure.result
                } catch {
                    return .failure(exitCode: 1, stderr: "trap: \(error)\n")
                }
            }
            return .success(stdout: formattedTraps(for: signals))
        }

        if arguments.count == 1 {
            do {
                let signal = try canonicalTrapSignal(arguments[0])
                if appliesStateChange {
                    shellTraps.removeValue(forKey: signal)
                }
                return .success()
            } catch let failure as MSPCommandFailure {
                return failure.result
            } catch {
                return .failure(exitCode: 1, stderr: "trap: \(error)\n")
            }
        }

        let command = arguments[0]
        let rawSignals = Array(arguments.dropFirst())
        let signals: [String]
        do {
            signals = try rawSignals.map { try canonicalTrapSignal($0) }
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "trap: \(error)\n")
        }

        guard appliesStateChange else {
            return .success()
        }

        for signal in signals {
            if command == "-" {
                shellTraps.removeValue(forKey: signal)
            } else {
                shellTraps[signal] = command
            }
        }
        return .success()
    }

    mutating func executeUmaskCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        let parsed: RuntimeUmaskInvocation
        do {
            parsed = try parseRuntimeUmaskInvocation(arguments)
        } catch let failure as MSPCommandFailure {
            return diagnostics.shellBuiltinDiagnosticResult(failure.result)
        } catch {
            return .failure(exitCode: 2, stderr: "umask: \(error)\n")
        }

        let currentMask = configuration.fileCreationMask & 0o777
        guard let modeArgument = parsed.modeArgument else {
            return .success(stdout: formatUmask(mask: currentMask, invocation: parsed))
        }

        let nextMask: UInt16
        do {
            nextMask = try parseUmaskMode(modeArgument, currentMask: currentMask)
        } catch let failure as MSPCommandFailure {
            return diagnostics.shellBuiltinDiagnosticResult(failure.result)
        } catch {
            return .failure(exitCode: 1, stderr: "umask: \(error)\n")
        }

        if appliesStateChange {
            configuration.fileCreationMask = nextMask
        }
        if parsed.printSymbolic {
            return .success(stdout: symbolicUmask(mask: nextMask) + "\n")
        }
        return .success()
    }

    private func formattedTraps(for signals: [String]) -> String {
        signals.compactMap { signal in
            guard let body = shellTraps[signal] else {
                return nil
            }
            return "trap -- '\(escapedTrapBody(body))' \(signal)"
        }
        .joined(separator: "\n")
        .appending(signals.contains { shellTraps[$0] != nil } ? "\n" : "")
    }

    private func escapedTrapBody(_ body: String) -> String {
        body.replacingOccurrences(of: "'", with: #"'\''"#)
    }

    private func formattedTrapSignalList() -> String {
        let numberedSignals = Self.trapSignals.compactMap { signal -> String? in
            guard let number = signal.number else {
                return nil
            }
            return String(format: "%2d) %@", number, signal.canonical)
        }
        return numberedSignals.joined(separator: "\t") + "\n"
    }

    private func canonicalTrapSignal(_ rawSignal: String) throws -> String {
        guard let signal = Self.trapSignalLookup[rawSignal.uppercased()] else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "trap: \(rawSignal): invalid signal specification\n"
                )
            )
        }
        return signal
    }

    private static let trapSignals: [RuntimeTrapSignal] = [
        RuntimeTrapSignal(canonical: "EXIT", number: 0, aliases: ["0"]),
        RuntimeTrapSignal(canonical: "ERR", aliases: []),
        RuntimeTrapSignal(canonical: "DEBUG", aliases: []),
        RuntimeTrapSignal(canonical: "RETURN", aliases: []),
        RuntimeTrapSignal(canonical: "SIGHUP", number: 1, aliases: ["HUP", "1"]),
        RuntimeTrapSignal(canonical: "SIGINT", number: 2, aliases: ["INT", "2"]),
        RuntimeTrapSignal(canonical: "SIGQUIT", number: 3, aliases: ["QUIT", "3"]),
        RuntimeTrapSignal(canonical: "SIGILL", number: 4, aliases: ["ILL", "4"]),
        RuntimeTrapSignal(canonical: "SIGTRAP", number: 5, aliases: ["TRAP", "5"]),
        RuntimeTrapSignal(canonical: "SIGABRT", number: 6, aliases: ["ABRT", "IOT", "SIGIOT", "6"]),
        RuntimeTrapSignal(canonical: "SIGBUS", number: 7, aliases: ["BUS", "7"]),
        RuntimeTrapSignal(canonical: "SIGFPE", number: 8, aliases: ["FPE", "8"]),
        RuntimeTrapSignal(canonical: "SIGKILL", number: 9, aliases: ["KILL", "9"]),
        RuntimeTrapSignal(canonical: "SIGUSR1", number: 10, aliases: ["USR1", "10"]),
        RuntimeTrapSignal(canonical: "SIGSEGV", number: 11, aliases: ["SEGV", "11"]),
        RuntimeTrapSignal(canonical: "SIGUSR2", number: 12, aliases: ["USR2", "12"]),
        RuntimeTrapSignal(canonical: "SIGPIPE", number: 13, aliases: ["PIPE", "13"]),
        RuntimeTrapSignal(canonical: "SIGALRM", number: 14, aliases: ["ALRM", "14"]),
        RuntimeTrapSignal(canonical: "SIGTERM", number: 15, aliases: ["TERM", "15"]),
        RuntimeTrapSignal(canonical: "SIGCHLD", number: 17, aliases: ["CHLD", "CLD", "SIGCLD", "17"]),
        RuntimeTrapSignal(canonical: "SIGCONT", number: 18, aliases: ["CONT", "18"]),
        RuntimeTrapSignal(canonical: "SIGSTOP", number: 19, aliases: ["STOP", "19"]),
        RuntimeTrapSignal(canonical: "SIGTSTP", number: 20, aliases: ["TSTP", "20"]),
        RuntimeTrapSignal(canonical: "SIGTTIN", number: 21, aliases: ["TTIN", "21"]),
        RuntimeTrapSignal(canonical: "SIGTTOU", number: 22, aliases: ["TTOU", "22"]),
        RuntimeTrapSignal(canonical: "SIGURG", number: 23, aliases: ["URG", "23"]),
        RuntimeTrapSignal(canonical: "SIGXCPU", number: 24, aliases: ["XCPU", "24"]),
        RuntimeTrapSignal(canonical: "SIGXFSZ", number: 25, aliases: ["XFSZ", "25"]),
        RuntimeTrapSignal(canonical: "SIGVTALRM", number: 26, aliases: ["VTALRM", "26"]),
        RuntimeTrapSignal(canonical: "SIGPROF", number: 27, aliases: ["PROF", "27"]),
        RuntimeTrapSignal(canonical: "SIGWINCH", number: 28, aliases: ["WINCH", "28"]),
        RuntimeTrapSignal(canonical: "SIGIO", number: 29, aliases: ["IO", "POLL", "SIGPOLL", "29"]),
        RuntimeTrapSignal(canonical: "SIGPWR", number: 30, aliases: ["PWR", "30"]),
        RuntimeTrapSignal(canonical: "SIGSYS", number: 31, aliases: ["SYS", "31"])
    ]

    private static let trapSignalLookup: [String: String] = {
        var lookup: [String: String] = [:]
        for signal in trapSignals {
            lookup[signal.canonical] = signal.canonical
            if signal.canonical.hasPrefix("SIG") {
                lookup[String(signal.canonical.dropFirst(3))] = signal.canonical
            }
            if let number = signal.number {
                lookup[String(number)] = signal.canonical
            }
            for alias in signal.aliases {
                lookup[alias.uppercased()] = signal.canonical
            }
        }
        return lookup
    }()
}

private struct RuntimeTrapSignal {
    var canonical: String
    var number: Int?
    var aliases: [String]

    init(canonical: String, number: Int? = nil, aliases: [String]) {
        self.canonical = canonical
        self.number = number
        self.aliases = aliases
    }
}

private struct RuntimeUmaskInvocation {
    var printAsCommand = false
    var printSymbolic = false
    var modeArgument: String?
}

private func parseRuntimeUmaskInvocation(_ arguments: [String]) throws -> RuntimeUmaskInvocation {
    var invocation = RuntimeUmaskInvocation()
    var parsesOptions = true

    for argument in arguments {
        if parsesOptions, argument == "--" {
            parsesOptions = false
            continue
        }
        if parsesOptions, argument.hasPrefix("-"), argument != "-" {
            for option in argument.dropFirst() {
                switch option {
                case "p":
                    invocation.printAsCommand = true
                case "S":
                    invocation.printSymbolic = true
                default:
                    throw MSPCommandFailure(
                        result: .failure(
                            exitCode: 2,
                            stderr: "umask: -\(option): invalid option\numask: usage: umask [-p] [-S] [mode]\n"
                        )
                    )
                }
            }
            continue
        }
        if invocation.modeArgument == nil {
            invocation.modeArgument = argument
        }
    }

    return invocation
}

private func parseUmaskMode(_ rawMode: String, currentMask: UInt16) throws -> UInt16 {
    if rawMode.allSatisfy({ ("0"..."7").contains($0) }) {
        guard let parsed = UInt16(rawMode, radix: 8), parsed <= 0o777 else {
            throw MSPCommandFailure(
                result: .failure(exitCode: 1, stderr: "umask: \(rawMode): octal number out of range\n")
            )
        }
        return parsed & 0o777
    }

    if rawMode.allSatisfy(\.isNumber) {
        throw MSPCommandFailure(
            result: .failure(exitCode: 1, stderr: "umask: \(rawMode): octal number out of range\n")
        )
    }

    var allowedMode = (~currentMask) & 0o777
    for rawClause in rawMode.split(separator: ",", omittingEmptySubsequences: false) {
        try applySymbolicUmaskClause(String(rawClause), allowedMode: &allowedMode)
    }
    return (~allowedMode) & 0o777
}

private func applySymbolicUmaskClause(_ clause: String, allowedMode: inout UInt16) throws {
    var index = clause.startIndex
    var who = Set<Character>()
    while index < clause.endIndex {
        let character = clause[index]
        if character == "+" || character == "-" || character == "=" {
            break
        }
        guard character == "u" || character == "g" || character == "o" || character == "a" else {
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "umask: `\(character)': invalid symbolic mode operator\n"
                )
            )
        }
        if character == "a" {
            who.formUnion(["u", "g", "o"])
        } else {
            who.insert(character)
        }
        index = clause.index(after: index)
    }

    guard index < clause.endIndex else {
        throw MSPCommandFailure(
            result: .failure(exitCode: 1, stderr: "umask: `': invalid symbolic mode operator\n")
        )
    }

    let operation = clause[index]
    guard operation == "+" || operation == "-" || operation == "=" else {
        throw MSPCommandFailure(
            result: .failure(
                exitCode: 1,
                stderr: "umask: `\(operation)': invalid symbolic mode operator\n"
            )
        )
    }
    index = clause.index(after: index)

    let targets = who.isEmpty ? Set<Character>(["u", "g", "o"]) : who
    let targetMask = symbolicPermissionMask(for: targets)
    var permissionMask: UInt16 = 0
    while index < clause.endIndex {
        let permission = clause[index]
        switch permission {
        case "r", "w", "x":
            permissionMask |= symbolicPermissionMask(for: targets, permission: permission)
        case "u", "g", "o":
            permissionMask |= symbolicCopiedPermissionMask(
                from: permission,
                to: targets,
                allowedMode: allowedMode
            )
        default:
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "umask: `\(permission)': invalid symbolic mode character\n"
                )
            )
        }
        index = clause.index(after: index)
    }

    switch operation {
    case "+":
        allowedMode |= permissionMask
    case "-":
        allowedMode &= ~permissionMask
    case "=":
        allowedMode = (allowedMode & ~targetMask) | permissionMask
    default:
        break
    }
    allowedMode &= 0o777
}

private func symbolicPermissionMask(for targets: Set<Character>) -> UInt16 {
    var mask: UInt16 = 0
    if targets.contains("u") {
        mask |= 0o700
    }
    if targets.contains("g") {
        mask |= 0o070
    }
    if targets.contains("o") {
        mask |= 0o007
    }
    return mask
}

private func symbolicPermissionMask(for targets: Set<Character>, permission: Character) -> UInt16 {
    let bit: UInt16
    switch permission {
    case "r":
        bit = 0o4
    case "w":
        bit = 0o2
    case "x":
        bit = 0o1
    default:
        bit = 0
    }

    var mask: UInt16 = 0
    if targets.contains("u") {
        mask |= bit << 6
    }
    if targets.contains("g") {
        mask |= bit << 3
    }
    if targets.contains("o") {
        mask |= bit
    }
    return mask
}

private func symbolicCopiedPermissionMask(
    from source: Character,
    to targets: Set<Character>,
    allowedMode: UInt16
) -> UInt16 {
    let sourceTriplet: UInt16
    switch source {
    case "u":
        sourceTriplet = (allowedMode >> 6) & 0o7
    case "g":
        sourceTriplet = (allowedMode >> 3) & 0o7
    case "o":
        sourceTriplet = allowedMode & 0o7
    default:
        sourceTriplet = 0
    }

    var mask: UInt16 = 0
    if targets.contains("u") {
        mask |= sourceTriplet << 6
    }
    if targets.contains("g") {
        mask |= sourceTriplet << 3
    }
    if targets.contains("o") {
        mask |= sourceTriplet
    }
    return mask
}

private func formatUmask(mask: UInt16, invocation: RuntimeUmaskInvocation) -> String {
    if invocation.printSymbolic {
        let symbolic = symbolicUmask(mask: mask)
        return invocation.printAsCommand ? "umask -S \(symbolic)\n" : symbolic + "\n"
    }
    let octal = String(format: "%04o", mask & 0o777)
    return invocation.printAsCommand ? "umask \(octal)\n" : octal + "\n"
}

private func symbolicUmask(mask: UInt16) -> String {
    let allowedMode = (~mask) & 0o777
    return [
        "u=\(symbolicPermissionCharacters((allowedMode >> 6) & 0o7))",
        "g=\(symbolicPermissionCharacters((allowedMode >> 3) & 0o7))",
        "o=\(symbolicPermissionCharacters(allowedMode & 0o7))"
    ].joined(separator: ",")
}

private func symbolicPermissionCharacters(_ triplet: UInt16) -> String {
    var characters = ""
    if (triplet & 0o4) != 0 {
        characters += "r"
    }
    if (triplet & 0o2) != 0 {
        characters += "w"
    }
    if (triplet & 0o1) != 0 {
        characters += "x"
    }
    return characters
}

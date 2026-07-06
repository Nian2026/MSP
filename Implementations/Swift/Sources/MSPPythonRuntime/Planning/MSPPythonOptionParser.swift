enum MSPPythonOptionParser {
    static func moduleArgument(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" || argument == "-" {
                return nil
            }
            if argument == "-c" || argument.hasPrefix("-c") {
                return nil
            }
            if argument == "-m" {
                return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
            if argument.hasPrefix("-m"), argument.count > 2 {
                return String(argument.dropFirst(2))
            }
            if argument.hasPrefix("--") {
                index += longOptionSkip(argument)
                continue
            }
            if argument.hasPrefix("-"),
               let module = shortOptionClusterModule(
                   argument,
                   next: arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
               ) {
                return module
            }
            if !argument.hasPrefix("-") {
                return nil
            }
            index += 1
        }
        return nil
    }

    static func scriptArgumentIndex(in arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return arguments.indices.contains(index + 1) ? index + 1 : nil
            }
            if argument == "-" || argument == "-c" || argument.hasPrefix("-c")
                || argument == "-m" || argument.hasPrefix("-m") {
                return nil
            }
            if argument.hasPrefix("--") {
                index += longOptionSkip(argument)
                continue
            }
            if argument.hasPrefix("-") {
                if shortOptionClusterContainsTerminal(argument) {
                    return nil
                }
                index += shortOptionSkip(argument)
                continue
            }
            return index
        }
        return nil
    }

    static func launcherEntrypoint(in arguments: [String]) throws -> MSPPythonLauncherEntrypoint {
        var index = 0
        var requestsInteractive = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                if index + 1 < arguments.count {
                    return .script(arguments[index + 1], Array(arguments.dropFirst(index + 2)))
                }
                return requestsInteractive ? .interactive([]) : .standardInput([])
            }
            if argument == "-" {
                return .standardInput(Array(arguments.dropFirst(index + 1)))
            }
            if argument == "-c" {
                guard index + 1 < arguments.count else {
                    throw MSPPythonPlanningError.optionRequiresArgument("-c")
                }
                return .command(arguments[index + 1], Array(arguments.dropFirst(index + 2)))
            }
            if argument.hasPrefix("-c"), argument.count > 2 {
                return .command(String(argument.dropFirst(2)), Array(arguments.dropFirst(index + 1)))
            }
            if argument == "-m" {
                guard index + 1 < arguments.count else {
                    throw MSPPythonPlanningError.optionRequiresArgument("-m")
                }
                return .module(arguments[index + 1], Array(arguments.dropFirst(index + 2)))
            }
            if argument.hasPrefix("-m"), argument.count > 2 {
                return .module(String(argument.dropFirst(2)), Array(arguments.dropFirst(index + 1)))
            }
            if argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let optionText = Array(argument.dropFirst())
                var offset = 0
                var didSkipCurrentCluster = false
                while offset < optionText.count {
                    let option = optionText[offset]
                    if option == "c" {
                        let command = String(optionText.dropFirst(offset + 1))
                        if !command.isEmpty {
                            return .command(command, Array(arguments.dropFirst(index + 1)))
                        }
                        guard index + 1 < arguments.count else {
                            throw MSPPythonPlanningError.optionRequiresArgument("-c")
                        }
                        return .command(arguments[index + 1], Array(arguments.dropFirst(index + 2)))
                    }
                    if option == "m" {
                        let module = String(optionText.dropFirst(offset + 1))
                        if !module.isEmpty {
                            return .module(module, Array(arguments.dropFirst(index + 1)))
                        }
                        guard index + 1 < arguments.count else {
                            throw MSPPythonPlanningError.optionRequiresArgument("-m")
                        }
                        return .module(arguments[index + 1], Array(arguments.dropFirst(index + 2)))
                    }
                    if option == "W" || option == "X" {
                        index = launcherSkipOption(arguments, index: index)
                        didSkipCurrentCluster = true
                        break
                    }
                    if option == "i" {
                        requestsInteractive = true
                    }
                    offset += 1
                }
                if !didSkipCurrentCluster {
                    index += 1
                }
                continue
            }
            if argument.hasPrefix("--") {
                index = launcherSkipOption(arguments, index: index)
                continue
            }
            return .script(argument, Array(arguments.dropFirst(index + 1)))
        }
        return requestsInteractive ? .interactive([]) : .standardInput([])
    }

    static func requestsUnbufferedIO(in arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" || argument == "-" {
                return false
            }
            if argument == "-c" || argument.hasPrefix("-c")
                || argument == "-m" || argument.hasPrefix("-m") {
                return false
            }
            if argument.hasPrefix("--") {
                index += longOptionSkip(argument)
                continue
            }
            if argument.hasPrefix("-") {
                let optionText = Array(argument.dropFirst())
                var offset = 0
                var didSkipCurrentCluster = false
                while offset < optionText.count {
                    let option = optionText[offset]
                    if option == "u" {
                        return true
                    }
                    if option == "c" || option == "m" {
                        return false
                    }
                    if option == "W" || option == "X" {
                        index = launcherSkipOption(arguments, index: index)
                        didSkipCurrentCluster = true
                        break
                    }
                    offset += 1
                }
                if !didSkipCurrentCluster {
                    index += 1
                }
                continue
            }
            return false
        }
        return false
    }

    private static func longOptionSkip(_ argument: String) -> Int {
        switch argument {
        case "--check-hash-based-pycs":
            return 2
        default:
            return 1
        }
    }

    private static func shortOptionSkip(_ argument: String) -> Int {
        let optionText = Array(argument.dropFirst())
        if optionText.count == 1,
           optionText.first == "W" || optionText.first == "X" {
            return 2
        }
        return 1
    }

    private static func shortOptionClusterContainsTerminal(_ argument: String) -> Bool {
        for option in argument.dropFirst() {
            if option == "m" || option == "c" {
                return true
            }
            if option == "W" || option == "X" {
                return false
            }
        }
        return false
    }

    private static func shortOptionClusterModule(_ argument: String, next: String?) -> String? {
        let noValueOptions = Set("bBEIOqRsSuvV")
        let optionText = Array(argument.dropFirst())
        var offset = 0
        while offset < optionText.count {
            let option = optionText[offset]
            if option == "m" {
                let moduleStart = offset + 1
                if moduleStart < optionText.count {
                    return String(optionText[moduleStart...])
                }
                return next
            }
            if option == "c" {
                return nil
            }
            if option == "W" || option == "X" {
                return nil
            }
            guard noValueOptions.contains(option) else {
                return nil
            }
            offset += 1
        }
        return nil
    }

    private static func launcherSkipOption(_ arguments: [String], index: Int) -> Int {
        let argument = arguments[index]
        if argument == "-W" || argument == "-X" || argument == "--check-hash-based-pycs" {
            return index + 2
        }
        if argument.hasPrefix("--check-hash-based-pycs=") {
            return index + 1
        }
        if argument.hasPrefix("-W") || argument.hasPrefix("-X") {
            return index + 1
        }
        return index + 1
    }
}

enum MSPPythonLauncherEntrypoint: Equatable {
    case command(String, [String])
    case module(String, [String])
    case script(String, [String])
    case standardInput([String])
    case interactive([String])
}

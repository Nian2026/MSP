import MSPCore

extension RuntimeBuiltinContext {
    private static let recognizedShoptOptions: Set<String> = [
        "assoc_expand_once",
        "autocd",
        "cdable_vars",
        "cdspell",
        "checkhash",
        "checkjobs",
        "checkwinsize",
        "cmdhist",
        "compat31",
        "compat32",
        "compat40",
        "compat41",
        "compat42",
        "compat43",
        "compat44",
        "complete_fullquote",
        "direxpand",
        "dirspell",
        "dotglob",
        "execfail",
        "expand_aliases",
        "extdebug",
        "extglob",
        "extquote",
        "failglob",
        "force_fignore",
        "globasciiranges",
        "globskipdots",
        "globstar",
        "gnu_errfmt",
        "histappend",
        "histreedit",
        "histverify",
        "hostcomplete",
        "huponexit",
        "inherit_errexit",
        "interactive_comments",
        "lastpipe",
        "lithist",
        "localvar_inherit",
        "localvar_unset",
        "login_shell",
        "mailwarn",
        "no_empty_cmd_completion",
        "nocaseglob",
        "nocasematch",
        "noexpand_translation",
        "nullglob",
        "patsub_replacement",
        "progcomp",
        "progcomp_alias",
        "promptvars",
        "restricted_shell",
        "shift_verbose",
        "sourcepath",
        "varredir_close",
        "xpg_echo"
    ]

    mutating func executeReturnCommand(
        arguments: [String],
        lastExitCode: Int32
    ) -> MSPCommandResult {
        guard functionDepth > 0 || sourceDepth > 0 else {
            return .failure(exitCode: 2, stderr: "return: can only `return' from a function\n")
        }
        guard arguments.count <= 1 else {
            return .failure(exitCode: 2, stderr: "return: too many arguments\n")
        }
        let code: Int32
        if let rawCode = arguments.first {
            guard let parsed = Int32(rawCode) else {
                pendingFunctionReturnCode = 2
                return .failure(exitCode: 2, stderr: "return: \(rawCode): numeric argument required\n")
            }
            code = ((parsed % 256) + 256) % 256
        } else {
            code = lastExitCode
        }
        pendingFunctionReturnCode = code
        return MSPCommandResult(exitCode: code)
    }

    mutating func executeLoopControlCommand(
        name: String,
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard loopDepth > 0 else {
            return .failure(exitCode: 2, stderr: "\(name): only meaningful in a loop\n")
        }
        guard arguments.count <= 1 else {
            return .failure(exitCode: 2, stderr: "\(name): too many arguments\n")
        }
        let count: Int
        if let rawCount = arguments.first {
            guard let parsed = Int(rawCount), parsed > 0 else {
                return .failure(exitCode: 2, stderr: "\(name): numeric argument required\n")
            }
            count = parsed
        } else {
            count = 1
        }
        guard count > 0 else {
            return .failure(exitCode: 2, stderr: "\(name): numeric argument required\n")
        }
        if appliesStateChange {
            pendingLoopControl = name == "break"
                ? .breakLoop(count)
                : .continueLoop(count)
        }
        return MSPCommandResult(exitCode: 0)
    }

    mutating func executeExitCommand(
        arguments: [String],
        lastExitCode: Int32,
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard arguments.count <= 1 else {
            return .failure(exitCode: 2, stderr: "exit: too many arguments\n")
        }
        let code: Int32
        if let rawCode = arguments.first {
            guard let parsed = Int32(rawCode) else {
                return .failure(exitCode: 2, stderr: "exit: \(rawCode): numeric argument required\n")
            }
            code = ((parsed % 256) + 256) % 256
        } else {
            code = lastExitCode
        }
        if appliesStateChange {
            pendingShellExitCode = code
        }
        return MSPCommandResult(exitCode: code)
    }

    mutating func executeShiftCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        var operands: [String] = []
        for argument in arguments {
            if argument == "--" {
                continue
            }
            operands.append(argument)
        }
        guard operands.count <= 1 else {
            return .failure(exitCode: 2, stderr: "shift: too many arguments\n")
        }
        let rawCount = operands.first ?? "1"
        guard let count = Int(rawCount) else {
            return .failure(exitCode: 2, stderr: "shift: \(rawCount): numeric argument required\n")
        }
        guard count >= 0 else {
            return .failure(exitCode: 1, stderr: "shift: shift count out of range\n")
        }
        let available = max(0, positionalParameters.count - 1)
        guard count <= available else {
            return .failure(exitCode: 1, stderr: "shift: shift count out of range\n")
        }
        guard appliesStateChange, count > 0 else {
            return .success()
        }
        let commandName = positionalParameters.first ?? "msp"
        positionalParameters = [commandName] + Array(positionalParameters.dropFirst(count + 1))
        return .success()
    }

    mutating func executeSetCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        guard !arguments.isEmpty else {
            return .success()
        }
        if arguments.first == "--" {
            if appliesStateChange {
                positionalParameters = [positionalParameters.first ?? "msp"] + Array(arguments.dropFirst())
            }
            return .success()
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                if appliesStateChange {
                    positionalParameters = [positionalParameters.first ?? "msp"] + Array(arguments.dropFirst(index + 1))
                }
                return .success()
            }
            guard (argument.hasPrefix("-") || argument.hasPrefix("+")), argument != "-", argument != "+" else {
                return .failure(exitCode: 2, stderr: "set: unsupported argument \(argument)\n")
            }

            let enablesOption = argument.hasPrefix("-")
            let options = Array(argument.dropFirst())
            var optionIndex = 0
            while optionIndex < options.count {
                let option = options[optionIndex]
                switch option {
                case "e":
                    if appliesStateChange {
                        isErrexitEnabled = enablesOption
                    }
                case "f":
                    if appliesStateChange {
                        if enablesOption {
                            shellOptions.insert("noglob")
                        } else {
                            shellOptions.remove("noglob")
                        }
                    }
                case "u":
                    if appliesStateChange {
                        isNounsetEnabled = enablesOption
                    }
                case "x":
                    if appliesStateChange {
                        isXtraceEnabled = enablesOption
                    }
                case "E":
                    break
                case "o":
                    guard optionIndex == options.count - 1 else {
                        return .failure(exitCode: 2, stderr: "set: -o: option name required\n")
                    }
                    guard index + 1 < arguments.count else {
                        return .success(stdout: shellLongOptionStatus(scriptForm: !enablesOption))
                    }
                    let optionName = arguments[index + 1]
                    guard !optionName.hasPrefix("-"), !optionName.hasPrefix("+") else {
                        return .success(stdout: shellLongOptionStatus(scriptForm: !enablesOption))
                    }
                    guard setLongShellOption(optionName, enabled: enablesOption, appliesStateChange: appliesStateChange) else {
                        return .failure(
                            exitCode: 2,
                            stderr: diagnostics.diagnostic("set: \(optionName): invalid option name", lineNumber: nil)
                        )
                    }
                    index += 1
                default:
                    return .failure(
                        exitCode: 2,
                        stderr: diagnostics.diagnostic("set: -\(option): invalid option", lineNumber: nil)
                            + "set: usage: set [-abefhkmnptuvxBCEHPT] [-o option-name] [--] [-] [arg ...]\n"
                    )
                }
                optionIndex += 1
            }
            index += 1
        }

        return .success()
    }

    mutating func executeShoptCommand(
        arguments: [String],
        appliesStateChange: Bool
    ) -> MSPCommandResult {
        var setFlag = false
        var unsetFlag = false
        var printFlag = false
        var quietFlag = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                break
            }
            for option in argument.dropFirst() {
                switch option {
                case "s":
                    setFlag = true
                case "u":
                    unsetFlag = true
                case "p":
                    printFlag = true
                case "q":
                    quietFlag = true
                default:
                    return .failure(exitCode: 2, stderr: "shopt: -\(option): invalid option\n")
                }
            }
            index += 1
        }

        guard !(setFlag && unsetFlag) else {
            return .failure(
                exitCode: 1,
                stderr: "shopt: cannot set and unset shell options simultaneously\n"
            )
        }

        let optionNames = Array(arguments.dropFirst(index))
        for name in optionNames {
            guard Self.recognizedShoptOptions.contains(name) else {
                return .failure(exitCode: 1, stderr: "shopt: \(name): invalid shell option name\n")
            }
        }

        if setFlag || unsetFlag {
            if appliesStateChange {
                if setFlag {
                    shellOptions.formUnion(optionNames)
                } else {
                    shellOptions.subtract(optionNames)
                }
            }
            return .success()
        }

        let names = optionNames.isEmpty
            ? Array(Self.recognizedShoptOptions).sorted()
            : optionNames
        let allEnabled = names.allSatisfy { shellOptions.contains($0) }

        if quietFlag {
            return MSPCommandResult(exitCode: allEnabled ? 0 : 1)
        }

        let stdout = names
            .map { name in
                if printFlag {
                    return shellOptions.contains(name) ? "shopt -s \(name)" : "shopt -u \(name)"
                }
                return "\(paddedOptionName(name))\t\(shellOptions.contains(name) ? "on" : "off")"
            }
            .joined(separator: "\n") + "\n"
        return MSPCommandResult(stdout: stdout, exitCode: allEnabled ? 0 : 1)
    }

    private mutating func setLongShellOption(
        _ optionName: String,
        enabled: Bool,
        appliesStateChange: Bool
    ) -> Bool {
        guard appliesStateChange else {
            return ["errexit", "noglob", "nounset", "pipefail", "xtrace"].contains(optionName)
        }
        switch optionName {
        case "errexit":
            isErrexitEnabled = enabled
        case "noglob":
            if enabled {
                shellOptions.insert("noglob")
            } else {
                shellOptions.remove("noglob")
            }
        case "nounset":
            isNounsetEnabled = enabled
        case "pipefail":
            isPipefailEnabled = enabled
        case "xtrace":
            isXtraceEnabled = enabled
        default:
            return false
        }
        return true
    }

    private func shellLongOptionStatus(scriptForm: Bool) -> String {
        let options: [(String, Bool)] = [
            ("allexport", false),
            ("braceexpand", enablesBashParameterExtensions),
            ("emacs", false),
            ("errexit", isErrexitEnabled),
            ("errtrace", false),
            ("functrace", false),
            ("hashall", true),
            ("histexpand", false),
            ("history", false),
            ("ignoreeof", false),
            ("interactive-comments", true),
            ("keyword", false),
            ("monitor", false),
            ("noclobber", false),
            ("noexec", false),
            ("noglob", shellOptions.contains("noglob")),
            ("nolog", false),
            ("notify", false),
            ("nounset", isNounsetEnabled),
            ("onecmd", false),
            ("physical", false),
            ("pipefail", isPipefailEnabled),
            ("posix", false),
            ("privileged", false),
            ("verbose", false),
            ("vi", false),
            ("xtrace", isXtraceEnabled)
        ]
        if scriptForm {
            return options
                .map { "set \($0.1 ? "-" : "+")o \($0.0)" }
                .joined(separator: "\n") + "\n"
        }
        return options
            .map { "\(paddedOptionName($0.0))\t\($0.1 ? "on" : "off")" }
            .joined(separator: "\n") + "\n"
    }

    private func paddedOptionName(_ name: String) -> String {
        name + String(repeating: " ", count: max(0, 15 - name.count))
    }
}

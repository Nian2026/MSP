import Foundation
import MSPCore

struct MSPBaseEncodingParsedOptions {
    var kind: MSPBaseEncodingKind?
    var decode = false
    var ignoreGarbage = false
    var wrapColumn = 76
    var operands: [String] = []
    var result: MSPCommandResult?
}

func mspBaseEncodingParse(
    arguments: [String],
    command: String,
    fixedKind: MSPBaseEncodingKind?
) -> MSPBaseEncodingParsedOptions {
    var parsed = MSPBaseEncodingParsedOptions(kind: fixedKind)
    var parsingOptions = true
    var index = 0

    func fail(_ stderr: String) -> MSPBaseEncodingParsedOptions {
        var copy = parsed
        copy.result = .failure(exitCode: 1, stderr: stderr)
        return copy
    }

    while index < arguments.count {
        let argument = arguments[index]
        if parsingOptions, argument == "--" {
            parsingOptions = false
            index += 1
            continue
        }

        if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let optionName = String(parts[0])
            let inlineValue = parts.count == 2 ? String(parts[1]) : nil
            switch optionName {
            case "decode":
                parsed.decode = true
            case "ignore-garbage":
                parsed.ignoreGarbage = true
            case "wrap":
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else {
                    guard index + 1 < arguments.count else {
                        return fail("\(command): option '--wrap' requires an argument\n")
                    }
                    index += 1
                    value = arguments[index]
                }
                guard let column = Int(value), column >= 0 else {
                    return fail("\(command): invalid wrap size: \(MSPPOSIXCommandSupport.gnuQuote(value))\n")
                }
                parsed.wrapColumn = column
            case "base64":
                parsed.kind = .base64
            case "base64url":
                parsed.kind = .base64URL
            case "base32":
                parsed.kind = .base32
            case "base32hex":
                parsed.kind = .base32Hex
            case "base16":
                parsed.kind = .base16
            case "base2msbf":
                parsed.kind = .base2MSBF
            case "base2lsbf":
                parsed.kind = .base2LSBF
            case "help":
                parsed.result = .success(stdout: mspBaseEncodingUsage(command))
                return parsed
            case "version":
                parsed.result = .success(stdout: "\(command) (GNU coreutils) 9.1\n")
                return parsed
            default:
                return fail("\(command): unrecognized option '\(argument)'\n" + mspBaseEncodingHelpHint(command))
            }
            index += 1
            continue
        }

        if parsingOptions, argument.hasPrefix("-"), argument != "-" {
            let characters = Array(argument.dropFirst())
            var characterIndex = 0
            while characterIndex < characters.count {
                let option = characters[characterIndex]
                switch option {
                case "d":
                    parsed.decode = true
                    characterIndex += 1
                case "i":
                    parsed.ignoreGarbage = true
                    characterIndex += 1
                case "w":
                    let value: String
                    if characterIndex + 1 < characters.count {
                        value = String(characters[(characterIndex + 1)...])
                    } else {
                        guard index + 1 < arguments.count else {
                            return fail("\(command): option requires an argument -- 'w'\n")
                        }
                        index += 1
                        value = arguments[index]
                    }
                    guard let column = Int(value), column >= 0 else {
                        return fail("\(command): invalid wrap size: \(MSPPOSIXCommandSupport.gnuQuote(value))\n")
                    }
                    parsed.wrapColumn = column
                    characterIndex = characters.count
                default:
                    return fail("\(command): invalid option -- '\(option)'\n" + mspBaseEncodingHelpHint(command))
                }
            }
            index += 1
            continue
        }

        parsed.operands.append(argument)
        index += 1
    }

    return parsed
}

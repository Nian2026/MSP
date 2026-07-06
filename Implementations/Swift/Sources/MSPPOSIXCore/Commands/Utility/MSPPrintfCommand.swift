import Foundation
import MSPCore

public struct MSPPrintfCommand: MSPCommand {
    public let name = "printf"
    public let summary: String? = "Format and print text."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments == ["--help"] {
            return .success(stdout: Self.helpText)
        }
        if invocation.arguments == ["--version"] {
            return .success(stdout: "printf (MSP coreutils-compatible) 9.1\n")
        }
        var operands = invocation.arguments
        if operands.first == "--" {
            operands.removeFirst()
        }
        guard let format = operands.first else {
            throw MSPCommandFailure.usage("printf: missing format operand\n")
        }

        let arguments = Array(operands.dropFirst())
        var state = PrintfState(
            arguments: arguments,
            diagnosticInvocation: invocation.rawInput.isEmpty ? nil : invocation
        )
        var output = Data()
        var stderr = ""
        var exitCode: Int32 = 0
        repeat {
            let rendered = render(format, state: &state)
            output.append(rendered.data)
            stderr += rendered.stderr
            if rendered.exitCode != 0 {
                exitCode = rendered.exitCode
            }
            if rendered.stopOutput {
                break
            }
            if !rendered.consumedArgument {
                break
            }
        } while state.hasRemainingArguments

        return MSPCommandResult(stdoutData: output, stderr: stderr, exitCode: exitCode)
    }

    private static let helpText = """
    Usage: printf FORMAT [ARGUMENT]...
      or:  printf OPTION
    Print ARGUMENT(s) according to FORMAT, or execute according to OPTION.

          --help     display this help and exit
          --version  output version information and exit

    FORMAT controls the output as in C printf.  Interpreted sequences include
    \\\", \\\\, \\a, \\b, \\c, \\e, \\f, \\n, \\r, \\t, \\v, \\NNN, \\xHH, \\uHHHH,
    \\UHHHHHHHH, %%, %b, %c, %d, %i, %u, %o, %x, %X, %a, %A, %f, %F, %e,
    %E, %g, %G, and %s.

    """

    private func render(_ format: String, state: inout PrintfState) -> PrintfRenderResult {
        var output = Data()
        var index = format.startIndex
        var consumedArgument = false
        var stopOutput = false

        while index < format.endIndex {
            let character = format[index]
            if character == "\\" {
                let result = decodeBackslashEscape(in: format, at: index)
                output.append(result.data)
                index = result.nextIndex
                if result.stopOutput {
                    stopOutput = true
                    break
                }
                continue
            }

            guard character == "%" else {
                output.append(contentsOf: String(character).utf8)
                index = format.index(after: index)
                continue
            }

            let next = format.index(after: index)
            guard next < format.endIndex else {
                output.append(UInt8(ascii: "%"))
                index = next
                continue
            }
            if format[next] == "%" {
                output.append(UInt8(ascii: "%"))
                index = format.index(after: next)
                continue
            }

            let spec = parseFormatSpec(in: format, afterPercent: next)
            let argument = state.nextArgument(defaultValue: "")
            consumedArgument = true
            switch spec.conversion {
            case "b":
                let decoded = decodeBackslashEscapes(argument)
                output.append(decoded.data)
                if decoded.stopOutput {
                    stopOutput = true
                }
            case "c":
                output.append(contentsOf: String(argument.first ?? "\0").utf8)
            case "d", "i":
                let parsed = parsePrintfInteger(argument)
                if let diagnostic = parsed.diagnostic {
                    state.appendIntegerDiagnostic(argument, diagnostic: diagnostic)
                }
                output.append(contentsOf: String(format: integerFoundationFormat(spec), parsed.signed).utf8)
            case "u", "o", "x", "X":
                let parsed = parsePrintfInteger(argument)
                if let diagnostic = parsed.diagnostic {
                    state.appendIntegerDiagnostic(argument, diagnostic: diagnostic)
                }
                output.append(contentsOf: String(format: integerFoundationFormat(spec), parsed.unsigned).utf8)
            case "a", "A", "f", "F", "e", "E", "g", "G":
                output.append(contentsOf: String(format: spec.foundationFormat, Double(argument) ?? 0).utf8)
            case "s":
                output.append(contentsOf: String(format: spec.foundationFormat, argument).utf8)
            default:
                output.append(contentsOf: ("%" + spec.raw).utf8)
            }
            index = spec.nextIndex
            if stopOutput {
                break
            }
        }

        return PrintfRenderResult(
            data: output,
            stderr: state.drainStderr(),
            exitCode: state.drainExitCode(),
            consumedArgument: consumedArgument,
            stopOutput: stopOutput
        )
    }

    private func parseFormatSpec(
        in format: String,
        afterPercent start: String.Index
    ) -> PrintfFormatSpec {
        let conversions = Set("abcdiAeEfgFGosuxX")
        var index = start
        while index < format.endIndex {
            let character = format[index]
            if conversions.contains(character) {
                let next = format.index(after: index)
                let raw = String(format[start...index])
                let foundationConversion: Character = {
                    switch character {
                    case "b", "s":
                        return "@"
                    default:
                        return character
                    }
                }()
                let foundationRaw = String(raw.dropLast()) + String(foundationConversion)
                return PrintfFormatSpec(
                    raw: raw,
                    conversion: character,
                    foundationFormat: "%" + foundationRaw,
                    nextIndex: next
                )
            }
            index = format.index(after: index)
        }
        return PrintfFormatSpec(
            raw: String(format[start...]),
            conversion: "\0",
            foundationFormat: "%" + String(format[start...]),
            nextIndex: format.endIndex
        )
    }

    private func decodeBackslashEscapes(_ text: String) -> (data: Data, stopOutput: Bool) {
        var output = Data()
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\\" else {
                output.append(contentsOf: String(text[index]).utf8)
                index = text.index(after: index)
                continue
            }
            let result = decodeBackslashEscape(in: text, at: index)
            output.append(result.data)
            index = result.nextIndex
            if result.stopOutput {
                return (output, true)
            }
        }
        return (output, false)
    }

    private func decodeBackslashEscape(
        in text: String,
        at index: String.Index
    ) -> (data: Data, nextIndex: String.Index, stopOutput: Bool) {
        let next = text.index(after: index)
        guard next < text.endIndex else {
            return (Data([UInt8(ascii: "\\")]), next, false)
        }
        switch text[next] {
        case "\"":
            return (Data([UInt8(ascii: "\"")]), text.index(after: next), false)
        case "a":
            return (Data([0x07]), text.index(after: next), false)
        case "b":
            return (Data([0x08]), text.index(after: next), false)
        case "c":
            return (Data(), text.index(after: next), true)
        case "e", "E":
            return (Data([0x1b]), text.index(after: next), false)
        case "f":
            return (Data([0x0c]), text.index(after: next), false)
        case "n":
            return (Data([0x0a]), text.index(after: next), false)
        case "r":
            return (Data([0x0d]), text.index(after: next), false)
        case "t":
            return (Data([0x09]), text.index(after: next), false)
        case "v":
            return (Data([0x0b]), text.index(after: next), false)
        case "\\":
            return (Data([UInt8(ascii: "\\")]), text.index(after: next), false)
        case "x":
            return mspPrintfDecodeVariableWidthScalar(in: text, after: next, maxDigits: 2, radix: 16)
        case "u":
            return mspPrintfDecodeFixedWidthScalar(in: text, after: next, digits: 4)
        case "U":
            return mspPrintfDecodeFixedWidthScalar(in: text, after: next, digits: 8)
        case "0"..."7":
            var octal = String(text[next])
            var cursor = text.index(after: next)
            while cursor < text.endIndex, octal.count < 3, ("0"..."7").contains(text[cursor]) {
                octal.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            let value = UInt32(octal, radix: 8) ?? 0
            return (Data([UInt8(truncatingIfNeeded: value)]), cursor, false)
        default:
            var data = Data([UInt8(ascii: "\\")])
            data.append(contentsOf: String(text[next]).utf8)
            return (data, text.index(after: next), false)
        }
    }
}

private func mspPrintfDecodeVariableWidthScalar(
    in text: String,
    after marker: String.Index,
    maxDigits: Int,
    radix: Int
) -> (data: Data, nextIndex: String.Index, stopOutput: Bool) {
    var digits = ""
    var cursor = text.index(after: marker)
    while cursor < text.endIndex,
          digits.count < maxDigits,
          text[cursor].isPrintfHexDigit {
        digits.append(text[cursor])
        cursor = text.index(after: cursor)
    }
    guard !digits.isEmpty,
          let value = UInt32(digits, radix: radix),
          let scalar = UnicodeScalar(value) else {
        return (Data(("\\" + String(text[marker])).utf8), text.index(after: marker), false)
    }
    return (Data(String(scalar).utf8), cursor, false)
}

private func mspPrintfDecodeFixedWidthScalar(
    in text: String,
    after marker: String.Index,
    digits count: Int
) -> (data: Data, nextIndex: String.Index, stopOutput: Bool) {
    var digits = ""
    var cursor = text.index(after: marker)
    while cursor < text.endIndex,
          digits.count < count,
          text[cursor].isPrintfHexDigit {
        digits.append(text[cursor])
        cursor = text.index(after: cursor)
    }
    guard digits.count == count,
          let value = UInt32(digits, radix: 16),
          let scalar = UnicodeScalar(value) else {
        return (Data(("\\" + String(text[marker])).utf8), text.index(after: marker), false)
    }
    return (Data(String(scalar).utf8), cursor, false)
}

private struct PrintfState {
    var arguments: [String]
    var diagnosticInvocation: MSPCommandInvocation?
    var index = 0
    var stderr = ""
    var exitCode: Int32 = 0

    var hasRemainingArguments: Bool {
        index < arguments.count
    }

    mutating func nextArgument(defaultValue: String) -> String {
        guard hasRemainingArguments else {
            return defaultValue
        }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func drainStderr() -> String {
        defer { stderr = "" }
        return stderr
    }

    mutating func drainExitCode() -> Int32 {
        defer { exitCode = 0 }
        return exitCode
    }

    mutating func appendIntegerDiagnostic(_ argument: String, diagnostic: String) {
        if let diagnosticInvocation {
            stderr += mspPOSIXBashShellDiagnosticStderr(
                "printf: \(argument): \(mspPrintfBashIntegerDiagnostic(argument))\n",
                invocation: diagnosticInvocation
            )
        } else {
            stderr += "printf: \(mspPrintfGNUQuoted(argument)): \(diagnostic)\n"
        }
        exitCode = 1
    }
}

private struct PrintfRenderResult {
    var data: Data
    var stderr: String
    var exitCode: Int32
    var consumedArgument: Bool
    var stopOutput: Bool
}

private struct PrintfFormatSpec {
    var raw: String
    var conversion: Character
    var foundationFormat: String
    var nextIndex: String.Index
}

private struct PrintfIntegerArgument {
    var signed: Int64
    var unsigned: UInt64
    var diagnostic: String?
}

private func integerFoundationFormat(_ spec: PrintfFormatSpec) -> String {
    "%" + spec.raw.dropLast() + "ll" + String(spec.conversion)
}

private func mspPrintfGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private func mspPrintfBashIntegerDiagnostic(_ value: String) -> String {
    if value.hasPrefix("0x") {
        return "invalid hex number"
    }
    if value.count >= 2,
       value.first == "0",
       value.dropFirst().first?.isNumber == true {
        return "invalid octal number"
    }
    return "invalid number"
}

private func parsePrintfInteger(_ argument: String) -> PrintfIntegerArgument {
    guard !argument.isEmpty else {
        return PrintfIntegerArgument(signed: 0, unsigned: 0, diagnostic: nil)
    }

    if let first = argument.first,
       (first == "'" || first == "\""),
       let scalar = argument.dropFirst().unicodeScalars.first {
        let value = UInt64(scalar.value)
        return PrintfIntegerArgument(signed: Int64(value), unsigned: value, diagnostic: nil)
    }

    var text = argument
    var negative = false
    if text.first == "+" || text.first == "-" {
        negative = text.first == "-"
        text.removeFirst()
    }

    var radix = 10
    if text.lowercased().hasPrefix("0x") {
        radix = 16
        text.removeFirst(2)
    } else if text.hasPrefix("0"), text.count > 1 {
        radix = 8
    }

    var digits = ""
    for character in text {
        if character.isValidDigit(radix: radix) {
            digits.append(character)
            continue
        }
        break
    }

    let diagnostic: String?
    if digits.isEmpty {
        diagnostic = "expected a numeric value"
    } else if digits.count != text.count {
        diagnostic = "value not completely converted"
    } else {
        diagnostic = nil
    }

    let magnitude = UInt64(digits, radix: radix) ?? 0
    let signed: Int64
    if negative {
        if magnitude == UInt64(Int64.max) + 1 {
            signed = Int64.min
        } else {
            signed = -(Int64(magnitude > UInt64(Int64.max) ? Int64.max : Int64(magnitude)))
        }
    } else {
        signed = Int64(bitPattern: magnitude)
    }
    return PrintfIntegerArgument(
        signed: signed,
        unsigned: UInt64(bitPattern: signed),
        diagnostic: diagnostic
    )
}

private extension Character {
    var isPrintfHexDigit: Bool {
        unicodeScalars.count == 1 && (
            ("0"..."9").contains(self)
                || ("a"..."f").contains(self)
                || ("A"..."F").contains(self)
        )
    }

    func isValidDigit(radix: Int) -> Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else {
            return false
        }
        let value: UInt32
        switch scalar.value {
        case 48...57:
            value = scalar.value - 48
        case 65...70:
            value = scalar.value - 55
        case 97...102:
            value = scalar.value - 87
        default:
            return false
        }
        return value < UInt32(radix)
    }
}

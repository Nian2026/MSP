import Foundation
import MSPCore

public struct MSPSeqCommand: MSPStreamingCommand {
    public var name: String { "seq" }
    public var summary: String? { "Print a sequence of numbers." }

    private let spec = MSPPOSIXCommandSpec(
        name: "seq",
        allowedShortOptions: ["w"],
        allowedLongOptions: ["equal-width", "help", "version"],
        shortOptionsRequiringValue: ["s", "f"],
        longOptionsRequiringValue: ["separator", "format"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSeqUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "seq (GNU coreutils) 9.1\n")
        }
        let plan = try parsePlan(arguments: invocation.arguments)
        var output = ""
        try await emitSequence(plan: plan) { text in
            output += text
        }
        guard !output.isEmpty else {
            return .success()
        }
        return .success(stdout: output)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("--version") {
            return try await run(invocation: invocation, context: context)
        }
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }
        let plan = try parsePlan(arguments: invocation.arguments)
        do {
            try await emitSequence(plan: plan) { text in
                try await standardOutput.write(Data(text.utf8))
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func parsePlan(arguments: [String]) throws -> MSPSeqPlan {
        var separator = "\n"
        var equalWidth = false
        var format: String?
        let parsed = try spec.parse(arguments, treatNegativeNumbersAsOperands: true)
        for option in parsed.options {
            switch option.name {
            case .short("w"), .long("equal-width"):
                equalWidth = true
            case .short("s"), .long("separator"):
                separator = option.value ?? ""
            case .short("f"), .long("format"):
                format = option.value
            default:
                continue
            }
        }

        if parsed.operands.isEmpty {
            throw mspSeqUsage("seq: missing operand")
        }
        if parsed.operands.count > 3 {
            throw mspSeqUsage("seq: extra operand \(mspSeqQuote(parsed.operands[3]))")
        }
        if format != nil, equalWidth {
            throw mspSeqUsage("seq: format string may not be specified when printing equal width strings")
        }

        let operands = try parsed.operands.map { operand -> MSPSeqOperand in
            guard let parsed = MSPSeqOperand(rawValue: operand) else {
                throw mspSeqUsage("seq: invalid floating point argument: \(mspSeqQuote(operand))")
            }
            return parsed
        }
        let first: MSPSeqOperand
        let increment: MSPSeqOperand
        let last: MSPSeqOperand
        switch operands.count {
        case 1:
            first = MSPSeqOperand.one
            increment = MSPSeqOperand.one
            last = operands[0]
        case 2:
            first = operands[0]
            increment = MSPSeqOperand.one
            last = operands[1]
        default:
            first = operands[0]
            increment = operands[1]
            if increment.value == 0 {
                throw mspSeqUsage("seq: invalid Zero increment value: \(mspSeqQuote(parsed.operands[1]))")
            }
            last = operands[2]
        }

        let outputFormat = format.map { MSPSeqFormat.custom($0) }
            ?? MSPSeqFormat.defaultFormat(first: first, step: increment, last: last, equalWidth: equalWidth)
        return MSPSeqPlan(
            first: first.value,
            increment: increment.value,
            last: last.value,
            separator: separator,
            format: outputFormat
        )
    }

    private func emitSequence(
        plan: MSPSeqPlan,
        write: (String) async throws -> Void
    ) async throws {
        var current = plan.first
        var emitted = 0
        var buffer = ""
        while mspSeqShouldEmit(current, last: plan.last, step: plan.increment) {
            if emitted > 0 {
                buffer += plan.separator
            }
            buffer += plan.format.render(current)
            emitted += 1
            if buffer.utf8.count >= 16 * 1024 {
                try await write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            current = plan.first + Double(emitted) * plan.increment
            if current.isNaN || current.isInfinite {
                break
            }
        }
        guard emitted > 0 else {
            return
        }
        buffer += "\n"
        if !buffer.isEmpty {
            try await write(buffer)
        }
    }
}

private struct MSPSeqPlan {
    var first: Double
    var increment: Double
    var last: Double
    var separator: String
    var format: MSPSeqFormat
}

private struct MSPSeqOperand {
    static let one = MSPSeqOperand(value: 1, width: 1, precision: 0)

    var value: Double
    var width: Int
    var precision: Int

    init(value: Double, width: Int, precision: Int) {
        self.value = value
        self.width = width
        self.precision = precision
    }

    init?(rawValue: String) {
        guard let parsed = Double(rawValue), !parsed.isNaN else {
            return nil
        }
        value = parsed

        var text = rawValue.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("+") {
            text.removeFirst()
        }

        width = 0
        precision = Int.max
        if !text.contains("."), !text.contains("p") {
            precision = 0
        }

        if !text.contains("x"), !text.contains("X"), parsed.isFinite {
            width = text.count
            if let decimalIndex = text.firstIndex(of: ".") {
                let afterDecimal = text.index(after: decimalIndex)
                let exponentIndex = text[afterDecimal...].firstIndex { $0 == "e" || $0 == "E" } ?? text.endIndex
                let fractionLength = text.distance(from: afterDecimal, to: exponentIndex)
                precision = fractionLength
                if fractionLength == 0 {
                    width -= 1
                } else if decimalIndex == text.startIndex || !text[text.index(before: decimalIndex)].isNumber {
                    width += 1
                }
            }

            if let exponentIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                let exponentText = String(text[text.index(after: exponentIndex)...])
                let exponent = max(Int(exponentText) ?? 0, Int.min + 1)
                precision += exponent < 0 ? -exponent : -min(precision, exponent)
                width -= text.distance(from: exponentIndex, to: text.endIndex)
                if exponent < 0 {
                    if let decimalIndex = text.firstIndex(of: ".") {
                        if exponentIndex == text.index(after: decimalIndex) {
                            width += 1
                        }
                    } else {
                        width += 1
                    }
                    width += -exponent
                } else {
                    if text.contains("."), precision == 0 {
                        width -= 1
                    }
                    width += exponent
                }
            }
            width = max(width, 0)
        }
    }
}

private enum MSPSeqFormat {
    case custom(String)
    case fixed(precision: Int, equalWidth: Int?)
    case generated(format: String)

    static func defaultFormat(
        first: MSPSeqOperand,
        step: MSPSeqOperand,
        last: MSPSeqOperand,
        equalWidth: Bool
    ) -> MSPSeqFormat {
        let precision = max(first.precision, step.precision)
        if precision != Int.max, last.precision != Int.max {
            if equalWidth {
                var firstWidth = first.width + (precision - first.precision)
                var lastWidth = last.width + (precision - last.precision)
                if last.precision != 0, precision == 0 {
                    lastWidth -= 1
                }
                if last.precision == 0, precision != 0 {
                    lastWidth += 1
                }
                if first.precision == 0, precision != 0 {
                    firstWidth += 1
                }
                return .fixed(precision: precision, equalWidth: max(firstWidth, lastWidth))
            }
            return .fixed(precision: precision, equalWidth: nil)
        }
        return .generated(format: "%g")
    }

    func render(_ value: Double) -> String {
        switch self {
        case .custom(let format):
            return mspSeqRenderCustomFormat(format, value: value)
        case .generated(let format):
            return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
        case .fixed(let precision, let equalWidth):
            let formatted = String(format: "%.\(precision)f", locale: Locale(identifier: "en_US_POSIX"), value)
            guard let equalWidth, formatted.count < equalWidth else {
                return formatted
            }
            if formatted.hasPrefix("-") {
                return "-" + String(repeating: "0", count: equalWidth - formatted.count) + formatted.dropFirst()
            }
            return String(repeating: "0", count: equalWidth - formatted.count) + formatted
        }
    }
}

private func mspSeqRenderCustomFormat(_ format: String, value: Double) -> String {
    guard let directive = mspSeqFirstDirective(in: format) else {
        return format
    }
    let prefix = mspSeqDecodePercentLiterals(String(format[..<directive.percentIndex]))
    let suffix = mspSeqDecodePercentLiterals(String(format[directive.endIndex...]))
    let precision = directive.precision ?? 6
    let numberFormat = "%.\(precision)\(directive.conversion)"
    let number = String(format: numberFormat, locale: Locale(identifier: "en_US_POSIX"), value)
    return prefix + mspSeqPadFormattedNumber(
        number,
        width: directive.width,
        zeroPad: directive.flags.contains("0") && !directive.flags.contains("-"),
        leftAlign: directive.flags.contains("-")
    ) + suffix
}

private struct MSPSeqPrintfDirective {
    var percentIndex: String.Index
    var endIndex: String.Index
    var flags: Set<Character>
    var width: Int?
    var precision: Int?
    var conversion: Character
}

private func mspSeqFirstDirective(in format: String) -> MSPSeqPrintfDirective? {
    var index = format.startIndex
    while index < format.endIndex {
        guard format[index] == "%" else {
            format.formIndex(after: &index)
            continue
        }
        let percentIndex = index
        format.formIndex(after: &index)
        if index < format.endIndex, format[index] == "%" {
            format.formIndex(after: &index)
            continue
        }

        var flags = Set<Character>()
        while index < format.endIndex, "-+#0 '".contains(format[index]) {
            flags.insert(format[index])
            format.formIndex(after: &index)
        }

        let widthStart = index
        while index < format.endIndex, format[index].isNumber {
            format.formIndex(after: &index)
        }
        let width = widthStart == index ? nil : Int(format[widthStart..<index])

        var precision: Int?
        if index < format.endIndex, format[index] == "." {
            format.formIndex(after: &index)
            let precisionStart = index
            while index < format.endIndex, format[index].isNumber {
                format.formIndex(after: &index)
            }
            precision = precisionStart == index ? 0 : Int(format[precisionStart..<index])
        }

        if index < format.endIndex, format[index] == "L" {
            format.formIndex(after: &index)
        }
        guard index < format.endIndex else {
            return nil
        }
        let conversion = format[index]
        guard "efgEFG".contains(conversion) else {
            return nil
        }
        format.formIndex(after: &index)
        return MSPSeqPrintfDirective(
            percentIndex: percentIndex,
            endIndex: index,
            flags: flags,
            width: width,
            precision: precision,
            conversion: conversion
        )
    }
    return nil
}

private func mspSeqPadFormattedNumber(
    _ number: String,
    width: Int?,
    zeroPad: Bool,
    leftAlign: Bool
) -> String {
    guard let width, number.count < width else {
        return number
    }
    let padding = String(repeating: zeroPad ? "0" : " ", count: width - number.count)
    if leftAlign {
        return number + padding
    }
    if zeroPad, number.hasPrefix("-") {
        return "-" + padding + number.dropFirst()
    }
    return padding + number
}

private func mspSeqDecodePercentLiterals(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "%",
           text.index(after: index) < text.endIndex,
           text[text.index(after: index)] == "%" {
            result.append("%")
            index = text.index(index, offsetBy: 2)
        } else {
            result.append(text[index])
            text.formIndex(after: &index)
        }
    }
    return result
}

private func mspSeqShouldEmit(_ current: Double, last: Double, step: Double) -> Bool {
    guard step != 0 else {
        return false
    }
    let tolerance = max(abs(step) * 1e-12, 1e-12)
    return step < 0 ? current >= last - tolerance : current <= last + tolerance
}

private func mspSeqUsage(_ message: String) -> MSPCommandFailure {
    MSPCommandFailure(result: .failure(
        exitCode: 1,
        stderr: message + "\nTry 'seq --help' for more information.\n"
    ))
}

private func mspSeqQuote(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private let mspSeqUsageText = """
Usage: seq [OPTION]... LAST
  or:  seq [OPTION]... FIRST LAST
  or:  seq [OPTION]... FIRST INCREMENT LAST
Print numbers from FIRST to LAST, in steps of INCREMENT.

  -f, --format=FORMAT      use printf style floating-point FORMAT
  -s, --separator=STRING   use STRING to separate numbers (default: \\n)
  -w, --equal-width        equalize width by padding with leading zeroes
      --help        display this help and exit
      --version     output version information and exit

"""

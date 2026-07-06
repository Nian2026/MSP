import Foundation
import MSPCore

public struct MSPNumfmtCommand: MSPStreamingCommand {
    public let name = "numfmt"
    public let summary: String? = "Reformat numbers in text."

    private let spec = MSPPOSIXCommandSpec(
        name: "numfmt",
        allowedLongOptions: ["help", "version"],
        longOptionsRequiringValue: ["field", "from", "to", "suffix", "padding"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspNumfmtUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "numfmt (GNU coreutils) 9.1\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        let configuration = try numfmtConfiguration(from: parsed.options)
        let text: String
        if !parsed.operands.isEmpty {
            text = parsed.operands.joined(separator: "\n")
        } else {
            text = String(decoding: context.standardInput, as: UTF8.self)
        }
        var outputLines: [String] = []
        for line in mspPOSIXLines(text) {
            let result = numfmtLine(
                line,
                configuration: configuration
            )
            if let error = result.error {
                return MSPCommandResult(
                    stdout: outputLines.isEmpty ? result.outputPrefix : mspPOSIXJoinedLines(outputLines) + result.outputPrefix,
                    stderr: error,
                    exitCode: 2
                )
            }
            outputLines.append(result.outputPrefix)
        }
        return .success(stdout: mspPOSIXJoinedLines(outputLines))
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("--version") {
            return try await run(invocation: invocation, context: context)
        }
        let parsed = try spec.parse(invocation.arguments)
        let configuration = try numfmtConfiguration(from: parsed.options)
        guard parsed.operands.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        var buffer = Data()
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex..<(newlineIndex + 1))
                    if let failure = try await streamNumfmtLine(
                        lineData,
                        configuration: configuration,
                        standardOutput: standardOutput
                    ) {
                        return failure
                    }
                }
            }
            if !buffer.isEmpty {
                if let failure = try await streamNumfmtLine(
                    buffer,
                    configuration: configuration,
                    standardOutput: standardOutput
                ) {
                    return failure
                }
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func streamNumfmtLine(
        _ lineData: Data,
        configuration: NumfmtConfiguration,
        standardOutput: any MSPCommandOutputStream
    ) async throws -> MSPCommandResult? {
        let line = String(decoding: lineData, as: UTF8.self)
        let result = numfmtLine(line, configuration: configuration)
        if let error = result.error {
            if !result.outputPrefix.isEmpty {
                try await standardOutput.write(Data(result.outputPrefix.utf8))
            }
            return MSPCommandResult(stdoutData: Data(), stderr: error, exitCode: 2)
        }
        try await standardOutput.write(Data((result.outputPrefix + "\n").utf8))
        return nil
    }
}

private let mspNumfmtUsage = """
Usage: numfmt [OPTION]... [NUMBER]...
Reformat NUMBER(s), or the numbers from standard input.

"""

private struct NumfmtLineResult {
    var outputPrefix: String
    var error: String? = nil
}

private struct NumfmtConfiguration {
    var fieldIndex = 1
    var fromMode = "none"
    var toMode = "none"
    var suffix = ""
    var padding: Int?
}

private func numfmtConfiguration(from options: [MSPPOSIXOption]) throws -> NumfmtConfiguration {
    var configuration = NumfmtConfiguration()
    for option in options {
        switch option.name {
        case .long("field"):
            guard let value = option.value,
                  let first = value.split(separator: ",").first,
                  let parsedField = Int(first),
                  parsedField > 0 else {
                throw MSPCommandFailure.usage("numfmt: invalid --field value\n")
            }
            configuration.fieldIndex = parsedField
        case .long("from"):
            configuration.fromMode = option.value ?? "none"
        case .long("to"):
            configuration.toMode = option.value ?? "none"
        case .long("suffix"):
            configuration.suffix = option.value ?? ""
        case .long("padding"):
            guard let value = option.value, let parsedPadding = Int(value) else {
                throw MSPCommandFailure.usage("numfmt: invalid --padding value\n")
            }
            configuration.padding = parsedPadding
        default:
            continue
        }
    }
    return configuration
}

private func numfmtLine(
    _ line: String,
    configuration: NumfmtConfiguration
) -> NumfmtLineResult {
    let fields = numfmtFields(in: line)
    let index = configuration.fieldIndex - 1
    guard index >= 0, index < fields.count else {
        return NumfmtLineResult(outputPrefix: line)
    }
    let field = fields[index]
    let rawNumber = String(line[field])
    guard let number = numfmtInputValue(rawNumber, fromMode: configuration.fromMode) else {
        return NumfmtLineResult(
            outputPrefix: String(line[..<field.lowerBound]),
            error: "numfmt: invalid number: \(mspNumfmtGNUQuoted(rawNumber))\n"
        )
    }
    var value = formattedNumfmtValue(number, toMode: configuration.toMode) + configuration.suffix
    if let padding = configuration.padding {
        let width = abs(padding)
        if value.count < width {
            let fill = String(repeating: " ", count: width - value.count)
            value = padding >= 0 ? fill + value : value + fill
        }
    }
    return NumfmtLineResult(
        outputPrefix: String(line[..<field.lowerBound]) + value + String(line[field.upperBound...])
    )
}

private func numfmtInputValue(_ rawNumber: String, fromMode: String) -> Double? {
    let normalizedMode = fromMode.lowercased()
    if normalizedMode == "none" {
        return Double(rawNumber)
    }

    var text = rawNumber.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
        return nil
    }

    var multiplier = 1.0
    if let suffix = text.last,
       let power = numfmtSuffixPower(suffix) {
        switch normalizedMode {
        case "si":
            multiplier = pow(1000.0, Double(power))
        case "iec":
            multiplier = pow(1024.0, Double(power))
        case "auto":
            multiplier = pow(1000.0, Double(power))
        default:
            return nil
        }
        text.removeLast()
    } else if normalizedMode != "si" && normalizedMode != "iec" && normalizedMode != "auto" {
        return nil
    }

    guard text.range(of: #"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
          let number = Double(text) else {
        return nil
    }
    return number * multiplier
}

private func numfmtSuffixPower(_ suffix: Character) -> Int? {
    switch suffix {
    case "K": return 1
    case "M": return 2
    case "G": return 3
    case "T": return 4
    case "P": return 5
    case "E": return 6
    case "Z": return 7
    case "Y": return 8
    default: return nil
    }
}

private func numfmtFields(in line: String) -> [Range<String.Index>] {
    var fields: [Range<String.Index>] = []
    var index = line.startIndex
    while index < line.endIndex {
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        let start = index
        while index < line.endIndex, line[index] != " ", line[index] != "\t" {
            index = line.index(after: index)
        }
        if start < index {
            fields.append(start..<index)
        }
    }
    return fields
}

private func mspNumfmtGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

private func formattedNumfmtValue(_ number: Double, toMode: String) -> String {
    switch toMode.lowercased() {
    case "iec", "iec-i":
        let units = toMode.lowercased() == "iec-i" ? ["", "Ki", "Mi", "Gi", "Ti", "Pi"] : ["", "K", "M", "G", "T", "P"]
        var value = number
        var unitIndex = 0
        while abs(value) >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        guard unitIndex > 0 else {
            return String(Int(number.rounded()))
        }
        let numeric = abs(value) >= 10
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return numeric + units[unitIndex]
    case "si":
        let units = ["", "K", "M", "G", "T", "P"]
        var value = number
        var unitIndex = 0
        while abs(value) >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        guard unitIndex > 0 else {
            return String(Int(number.rounded()))
        }
        let numeric = abs(value) >= 10
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return numeric + units[unitIndex]
    default:
        return String(Int(number.rounded()))
    }
}

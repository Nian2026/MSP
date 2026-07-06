import Foundation
import MSPCore

public struct MSPFoldCommand: MSPStreamingCommand {
    public let name = "fold"
    public let summary: String? = "Wrap input lines to a requested width."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let configuration = try MSPFoldConfiguration(arguments: invocation.arguments)
        let input = try await mspTextLayoutData(operands: configuration.operands, context: context, command: name)
        var stdout = Data()
        for item in input.inputs {
            stdout.append(renderFold(data: item.data, configuration: configuration))
        }
        return MSPCommandResult(
            stdoutData: stdout,
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let configuration = try MSPFoldConfiguration(arguments: invocation.arguments)
        guard configuration.operands.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }
        var state = MSPFoldRenderState(configuration: configuration)
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                let output = state.process(chunk)
                if !output.isEmpty {
                    try await standardOutput.write(output)
                }
            }
            let output = state.finish()
            if !output.isEmpty {
                try await standardOutput.write(output)
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private static let helpText = """
    Usage: fold [OPTION]... [FILE]...
    Wrap input lines in each FILE, writing to standard output.

      -b, --bytes       count bytes rather than columns
      -s, --spaces      break at spaces
      -w, --width=WIDTH use WIDTH columns instead of 80
          --help        display this help and exit
          --version     output version information and exit
    """
}

private struct MSPFoldConfiguration {
    var width = 80
    var countBytes = false
    var breakSpaces = false
    var operands: [String] = []

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "-b" || argument == "--bytes" {
                countBytes = true
                index += 1
                continue
            }
            if argument == "-s" || argument == "--spaces" {
                breakSpaces = true
                index += 1
                continue
            }
            if argument == "-w" || argument == "--width" {
                index += 1
                guard index < arguments.count else {
                    throw invalidWidth("")
                }
                width = try parseWidth(arguments[index])
                index += 1
                continue
            }
            if argument.hasPrefix("-w"), argument.count > 2 {
                width = try parseWidth(String(argument.dropFirst(2)))
                index += 1
                continue
            }
            if argument.hasPrefix("--width=") {
                width = try parseWidth(String(argument.dropFirst("--width=".count)))
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument.dropFirst().allSatisfy(\.isNumber) {
                width = try parseWidth(String(argument.dropFirst()))
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw MSPCommandFailure.usage("fold: unsupported option -- \(argument.dropFirst().first ?? "?")\n")
            }
            operands.append(argument)
            index += 1
        }
    }

    private func parseWidth(_ text: String) throws -> Int {
        guard let value = Int(text), value > 0 else {
            throw invalidWidth(text)
        }
        return value
    }

    private func invalidWidth(_ text: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(
            stderr: "fold: invalid number of columns: \(MSPPOSIXCommandSupport.gnuQuote(text))\n"
        ))
    }
}

private func renderFold(data: Data, configuration: MSPFoldConfiguration) -> Data {
    var state = MSPFoldRenderState(configuration: configuration)
    var output = state.process(data)
    output.append(state.finish())
    return output
}

private struct MSPFoldRenderState {
    var configuration: MSPFoldConfiguration
    var line: [UInt8] = []
    var column = 0

    mutating func process(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            if byte == 0x0A {
                output.append(contentsOf: line)
                output.append(0x0A)
                line.removeAll(keepingCapacity: true)
                column = 0
                continue
            }

            while true {
                let nextColumn = adjustedColumn(column, byte: byte)
                guard nextColumn > configuration.width else {
                    column = nextColumn
                    line.append(byte)
                    break
                }

                if configuration.breakSpaces,
                   let blankIndex = line.lastIndex(where: { $0 == 0x20 || $0 == 0x09 }) {
                    let end = blankIndex + 1
                    output.append(contentsOf: line[..<end])
                    output.append(0x0A)
                    line = Array(line[end...])
                    column = recalculateColumn()
                    continue
                }

                if line.isEmpty {
                    line.append(byte)
                    column = nextColumn
                    break
                }
                output.append(contentsOf: line)
                output.append(0x0A)
                line.removeAll(keepingCapacity: true)
                column = 0
            }
        }
        return output
    }

    mutating func finish() -> Data {
        let output = Data(line)
        line.removeAll(keepingCapacity: true)
        column = 0
        return output
    }

    private func adjustedColumn(_ current: Int, byte: UInt8) -> Int {
        if configuration.countBytes {
            return current + 1
        }
        switch byte {
        case 0x08:
            return max(0, current - 1)
        case 0x0D:
            return 0
        case 0x09:
            return current + (8 - current % 8)
        default:
            return current + 1
        }
    }

    private func recalculateColumn() -> Int {
        line.reduce(0) { adjustedColumn($0, byte: $1) }
    }
}

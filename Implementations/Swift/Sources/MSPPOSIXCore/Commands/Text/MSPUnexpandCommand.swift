import Foundation
import MSPCore

public struct MSPUnexpandCommand: MSPStreamingCommand {
    public let name = "unexpand"
    public let summary: String? = "Convert spaces to tabs."

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
        let configuration = try MSPUnexpandConfiguration(arguments: invocation.arguments)
        let input = try unexpandOutput(configuration: configuration, context: context)
        return MSPCommandResult(
            stdoutData: input.stdout,
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
        let configuration = try MSPUnexpandConfiguration(arguments: invocation.arguments)
        guard configuration.operands.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }
        var renderer = MSPUnexpandRenderer(configuration: configuration)
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                let output = renderer.append(chunk)
                if !output.isEmpty {
                    try await standardOutput.write(output)
                }
            }
            let output = renderer.finish()
            if !output.isEmpty {
                try await standardOutput.write(output)
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private static let helpText = """
    Usage: unexpand [OPTION]... [FILE]...
    Convert blanks in each FILE to tabs, writing to standard output.

      -a, --all          convert all blanks, instead of just initial blanks
          --first-only   convert only leading blanks
      -t, --tabs=LIST   use comma separated list of tab positions
          --help        display this help and exit
          --version     output version information and exit
    """

    private func unexpandOutput(
        configuration: MSPUnexpandConfiguration,
        context: MSPCommandContext
    ) throws -> (stdout: Data, diagnostics: [String], exitCode: Int32) {
        if configuration.operands.isEmpty {
            do {
                return (
                    renderUnexpand(
                        data: try MSPPOSIXCommandSupport.standardInputData(from: context),
                        configuration: configuration
                    ),
                    [],
                    0
                )
            } catch {
                return (Data(), ["\(name): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"], 1)
            }
        }

        var fileSystem: (any MSPWorkspaceFileSystem)?
        var standardInputConsumed = false
        var stdout = Data()
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        for operand in configuration.operands {
            if operand == "-" {
                let data: Data
                if standardInputConsumed {
                    data = Data()
                } else {
                    standardInputConsumed = true
                    do {
                        data = try MSPPOSIXCommandSupport.standardInputData(from: context)
                    } catch {
                        diagnostics.append("\(name): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                        exitCode = 1
                        continue
                    }
                }
                stdout.append(renderUnexpand(data: data, configuration: configuration))
                continue
            }

            do {
                if fileSystem == nil {
                    fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                }
                var renderer = MSPUnexpandRenderer(configuration: configuration)
                var offset: UInt64 = 0
                while true {
                    let chunk = try fileSystem!.readFileRange(
                        operand,
                        from: context.currentDirectory,
                        offset: offset,
                        length: 32 * 1024
                    )
                    guard !chunk.isEmpty else {
                        break
                    }
                    stdout.append(renderer.append(chunk))
                    offset += UInt64(chunk.count)
                }
                stdout.append(renderer.finish())
            } catch {
                diagnostics.append(
                    "\(name): \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                )
                exitCode = 1
            }
        }

        return (stdout, diagnostics, exitCode)
    }
}

private struct MSPUnexpandConfiguration {
    var tabStops = MSPTextLayoutTabStops.default
    var convertAll = false
    var operands: [String] = []

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "-a" || argument == "--all" {
                convertAll = true
                index += 1
                continue
            }
            if argument == "--first-only" {
                convertAll = false
                index += 1
                continue
            }
            if argument == "-t" || argument == "--tabs" {
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("unexpand: option requires an argument -- t\n")
                }
                tabStops = try MSPTextLayoutTabStops.parse(arguments[index], command: "unexpand")
                convertAll = true
                index += 1
                continue
            }
            if argument.hasPrefix("-t"), argument.count > 2 {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst(2)), command: "unexpand")
                convertAll = true
                index += 1
                continue
            }
            if argument.hasPrefix("--tabs=") {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst("--tabs=".count)), command: "unexpand")
                convertAll = true
                index += 1
                continue
            }
            if argument.hasPrefix("-"),
               argument != "-",
               MSPTextLayoutTabStops.canParseObsoleteOption(String(argument.dropFirst())) {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst()), command: "unexpand")
                convertAll = true
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw MSPCommandFailure.usage("unexpand: unsupported option -- \(argument.dropFirst().first ?? "?")\n")
            }
            operands.append(argument)
            index += 1
        }
    }
}

private func renderUnexpand(data: Data, configuration: MSPUnexpandConfiguration) -> Data {
    var renderer = MSPUnexpandRenderer(configuration: configuration)
    var output = renderer.append(data)
    output.append(renderer.finish())
    return output
}

private struct MSPUnexpandRenderer {
    var configuration: MSPUnexpandConfiguration
    var line: [UInt8] = []

    mutating func append(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            if byte == 0x0A {
                output.append(renderUnexpandLine(line, configuration: configuration))
                output.append(0x0A)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        return output
    }

    mutating func finish() -> Data {
        guard !line.isEmpty else {
            return Data()
        }
        let output = renderUnexpandLine(line, configuration: configuration)
        line.removeAll(keepingCapacity: true)
        return output
    }
}

private func renderUnexpandLine(_ line: [UInt8], configuration: MSPUnexpandConfiguration) -> Data {
    var output = Data()
    var index = 0
    var column = 0
    var mayConvert = true

    while index < line.count {
        let byte = line[index]
        if mayConvert, byte == 0x20 || byte == 0x09 {
            let startColumn = column
            var endColumn = column
            var blankCount = 0
            while index < line.count, line[index] == 0x20 || line[index] == 0x09 {
                if line[index] == 0x09 {
                    endColumn = configuration.tabStops.next(after: endColumn) ?? (endColumn + 1)
                } else {
                    endColumn += 1
                }
                blankCount += 1
                index += 1
            }
            output.append(renderTabsAndSpaces(
                from: startColumn,
                to: endColumn,
                originalBlankCount: blankCount,
                tabStops: configuration.tabStops
            ))
            column = endColumn
            if !configuration.convertAll, index < line.count {
                mayConvert = false
            }
            continue
        }

        output.append(byte)
        switch byte {
        case 0x08:
            column = max(0, column - 1)
        case 0x09:
            column = configuration.tabStops.next(after: column) ?? (column + 1)
        default:
            column += 1
        }
        if byte != 0x20, byte != 0x09, !configuration.convertAll {
            mayConvert = false
        }
        index += 1
    }
    return output
}

private func renderTabsAndSpaces(
    from startColumn: Int,
    to endColumn: Int,
    originalBlankCount: Int,
    tabStops: MSPTextLayoutTabStops
) -> Data {
    var output = Data()
    var column = startColumn
    while let next = tabStops.next(after: column), next <= endColumn, next - column > 1 {
        output.append(0x09)
        column = next
    }
    while column < endColumn {
        output.append(0x20)
        column += 1
    }
    if output.count >= originalBlankCount {
        return Data(repeatElement(UInt8(0x20), count: originalBlankCount))
    }
    return output
}

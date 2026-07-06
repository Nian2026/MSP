import Foundation
import MSPCore

public struct MSPExpandCommand: MSPStreamingCommand {
    public let name = "expand"
    public let summary: String? = "Convert tabs to spaces."

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
        let configuration = try MSPExpandConfiguration(arguments: invocation.arguments)
        let input = try expandOutput(configuration: configuration, context: context)
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
        let configuration = try MSPExpandConfiguration(arguments: invocation.arguments)
        guard configuration.operands.isEmpty,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }
        var renderer = MSPExpandRenderer(configuration: configuration)
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                let output = renderer.append(chunk)
                if !output.isEmpty {
                    try await standardOutput.write(output)
                }
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private static let helpText = """
    Usage: expand [OPTION]... [FILE]...
    Convert tabs in each FILE to spaces, writing to standard output.

      -i, --initial       do not convert tabs after non blanks
      -t, --tabs=LIST    use comma separated list of tab positions
          --help         display this help and exit
          --version      output version information and exit
    """

    private func expandOutput(
        configuration: MSPExpandConfiguration,
        context: MSPCommandContext
    ) throws -> (stdout: Data, diagnostics: [String], exitCode: Int32) {
        if configuration.operands.isEmpty {
            do {
                return (
                    renderExpand(
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
                stdout.append(renderExpand(data: data, configuration: configuration))
                continue
            }

            do {
                if fileSystem == nil {
                    fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                }
                var renderer = MSPExpandRenderer(configuration: configuration)
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

private struct MSPExpandConfiguration {
    var tabStops = MSPTextLayoutTabStops.default
    var initialOnly = false
    var operands: [String] = []

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "-i" || argument == "--initial" {
                initialOnly = true
                index += 1
                continue
            }
            if argument == "-t" || argument == "--tabs" {
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure.usage("expand: option requires an argument -- t\n")
                }
                tabStops = try MSPTextLayoutTabStops.parse(arguments[index], command: "expand")
                index += 1
                continue
            }
            if argument.hasPrefix("-t"), argument.count > 2 {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst(2)), command: "expand")
                index += 1
                continue
            }
            if argument.hasPrefix("--tabs=") {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst("--tabs=".count)), command: "expand")
                index += 1
                continue
            }
            if argument.hasPrefix("-"),
               argument != "-",
               MSPTextLayoutTabStops.canParseObsoleteOption(String(argument.dropFirst())) {
                tabStops = try MSPTextLayoutTabStops.parse(String(argument.dropFirst()), command: "expand")
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                throw MSPCommandFailure.usage("expand: unsupported option -- \(argument.dropFirst().first ?? "?")\n")
            }
            operands.append(argument)
            index += 1
        }
    }
}

private func renderExpand(data: Data, configuration: MSPExpandConfiguration) -> Data {
    var renderer = MSPExpandRenderer(configuration: configuration)
    return renderer.append(data)
}

private struct MSPExpandRenderer {
    var configuration: MSPExpandConfiguration
    var column = 0
    var converting = true

    mutating func append(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            if byte == 0x0A {
                output.append(byte)
                column = 0
                converting = true
                continue
            }

            if converting, byte == 0x09 {
                let next = configuration.tabStops.next(after: column) ?? (column + 1)
                let spaces = max(1, next - column)
                output.append(contentsOf: repeatElement(UInt8(0x20), count: spaces))
                column = next
                continue
            }

            output.append(byte)
            switch byte {
            case 0x08:
                column = max(0, column - 1)
            default:
                column += 1
            }
            if configuration.initialOnly, byte != 0x20, byte != 0x09 {
                converting = false
            }
        }
        return output
    }
}

import Foundation
import MSPCore

public struct MSPStringsCommand: MSPStreamingCommand {
    public let name = "strings"
    public let summary: String? = "Print printable strings in binary data."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        do {
            let configuration = try MSPStringsConfiguration(arguments: invocation.arguments)
            if configuration.help {
                return .success(stdout: mspStringsUsageText)
            }
            if configuration.version {
                return .success(stdout: "GNU strings (GNU Binutils for Debian) 2.40\n")
            }
            let input = try await mspTextLayoutData(
                operands: configuration.operands,
                context: context,
                command: name,
                fileReadDiagnostic: { displayPath, _ in
                    "strings: '\(displayPath)': No such file"
                }
            )
            var stdout = Data()
            for item in input.inputs {
                stdout.append(renderStrings(data: item.data, label: item.label, configuration: configuration))
            }
            return MSPCommandResult(
                stdoutData: stdout,
                stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
                exitCode: input.exitCode
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        }
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let configuration = try MSPStringsConfiguration(arguments: invocation.arguments)
        guard configuration.operands.isEmpty, !configuration.help, !configuration.version else {
            return try await run(invocation: invocation, context: context)
        }
        return try await mspTextLayoutRunStreamingFromStandardInput(
            invocation: invocation,
            context: context,
            command: run(invocation:context:)
        )
    }
}

private struct MSPStringsConfiguration {
    var minimumLength = 4
    var radix: Character?
    var encoding: Character = "s"
    var operands: [String] = []
    var help = false
    var version = false
    var printFileName = false
    var includeAllWhitespace = false
    var outputSeparator = "\n"

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "--help" || argument == "-h" {
                help = true
                index += 1
                continue
            }
            if argument == "--version" || argument == "-v" || argument == "-V" {
                version = true
                index += 1
                continue
            }
            if argument == "-f" || argument == "--print-file-name" {
                printFileName = true
                index += 1
                continue
            }
            if argument == "-w" || argument == "--include-all-whitespace" {
                includeAllWhitespace = true
                index += 1
                continue
            }
            if argument == "-a" || argument == "--all" || argument == "-d" || argument == "--data" {
                index += 1
                continue
            }
            if argument == "-o" {
                radix = "o"
                index += 1
                continue
            }
            if argument == "-n" || argument == "--bytes" {
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw MSPCommandFailure(result: .failure(stderr: "strings: invalid integer argument\n"))
                }
                minimumLength = value
                index += 1
                continue
            }
            if argument.hasPrefix("--bytes=") {
                let valueText = String(argument.dropFirst("--bytes=".count))
                guard let value = Int(valueText), value > 0 else {
                    throw MSPCommandFailure(result: .failure(stderr: "strings: invalid integer argument\n"))
                }
                minimumLength = value
                index += 1
                continue
            }
            if argument == "-t" || argument == "--radix" {
                index += 1
                guard index < arguments.count, let value = arguments[index].first, ["o", "d", "x"].contains(value) else {
                    throw MSPCommandFailure(result: .failure(stderr: "strings: invalid radix\n"))
                }
                radix = value
                index += 1
                continue
            }
            if argument.hasPrefix("-t"), argument.count > 2, let value = argument.last, ["o", "d", "x"].contains(value) {
                radix = value
                index += 1
                continue
            }
            if argument.hasPrefix("--radix="), let value = argument.last, ["o", "d", "x"].contains(value) {
                radix = value
                index += 1
                continue
            }
            if argument == "-e" || argument == "--encoding" {
                index += 1
                guard index < arguments.count, let value = MSPStringsConfiguration.parseEncoding(arguments[index]) else {
                    throw MSPCommandFailure(result: .failure(stderr: "strings: invalid encoding\n"))
                }
                encoding = value
                index += 1
                continue
            }
            if argument.hasPrefix("-e"), argument.count > 2, let value = MSPStringsConfiguration.parseEncoding(String(argument.dropFirst(2))) {
                encoding = value
                index += 1
                continue
            }
            if argument.hasPrefix("--encoding="), let value = MSPStringsConfiguration.parseEncoding(String(argument.dropFirst("--encoding=".count))) {
                encoding = value
                index += 1
                continue
            }
            if argument == "-s" || argument == "--output-separator" {
                index += 1
                guard index < arguments.count else {
                    throw MSPCommandFailure(result: .failure(stderr: "strings: option requires an argument -- 's'\n" + mspStringsUsageText))
                }
                outputSeparator = arguments[index]
                index += 1
                continue
            }
            if argument.hasPrefix("--output-separator=") {
                outputSeparator = String(argument.dropFirst("--output-separator=".count))
                index += 1
                continue
            }
            if argument.hasPrefix("-"),
               argument.count > 1,
               argument.dropFirst().allSatisfy(\.isNumber),
               let value = Int(argument.dropFirst()),
               value > 0 {
                minimumLength = value
                index += 1
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                let option = argument.dropFirst().first ?? "?"
                throw MSPCommandFailure(result: .failure(
                    stderr: "strings: invalid option -- '\(option)'\n" + mspStringsUsageText
                ))
            }
            operands.append(argument)
            index += 1
        }
    }

    private static func parseEncoding(_ text: String) -> Character? {
        guard text.count == 1, let value = text.first, ["s", "S", "b", "l", "B", "L"].contains(value) else {
            return nil
        }
        return value
    }
}

private func renderStrings(data: Data, label: String?, configuration: MSPStringsConfiguration) -> Data {
    switch configuration.encoding {
    case "S":
        return renderByteStrings(data: data, label: label, configuration: configuration, includeEightBit: true)
    case "l":
        return renderWideStrings(data: data, label: label, configuration: configuration, width: 2, littleEndian: true)
    case "b":
        return renderWideStrings(data: data, label: label, configuration: configuration, width: 2, littleEndian: false)
    case "L":
        return renderWideStrings(data: data, label: label, configuration: configuration, width: 4, littleEndian: true)
    case "B":
        return renderWideStrings(data: data, label: label, configuration: configuration, width: 4, littleEndian: false)
    default:
        return renderByteStrings(data: data, label: label, configuration: configuration, includeEightBit: false)
    }
}

private func renderByteStrings(data: Data, label: String?, configuration: MSPStringsConfiguration, includeEightBit: Bool) -> Data {
    let bytes = [UInt8](data)
    var output = Data()
    var index = 0
    while index < bytes.count {
        guard isStringsGraphic(bytes[index], includeAllWhitespace: configuration.includeAllWhitespace, includeEightBit: includeEightBit) else {
            index += 1
            continue
        }
        let start = index
        var run: [UInt8] = []
        while index < bytes.count, isStringsGraphic(bytes[index], includeAllWhitespace: configuration.includeAllWhitespace, includeEightBit: includeEightBit) {
            run.append(bytes[index])
            index += 1
        }
        if run.count >= configuration.minimumLength {
            appendStringsRecord(run, offset: start, label: label, configuration: configuration, to: &output)
        }
    }
    return output
}

private func renderWideStrings(data: Data, label: String?, configuration: MSPStringsConfiguration, width: Int, littleEndian: Bool) -> Data {
    let bytes = [UInt8](data)
    var output = Data()
    var index = 0
    while index + width <= bytes.count {
        guard stringsGraphicScalar(bytes: bytes, at: index, width: width, littleEndian: littleEndian, configuration: configuration) != nil else {
            index += width
            continue
        }
        let start = index
        var run: [UInt8] = []
        while index + width <= bytes.count,
              let next = stringsGraphicScalar(bytes: bytes, at: index, width: width, littleEndian: littleEndian, configuration: configuration) {
            run.append(next)
            index += width
        }
        if run.count >= configuration.minimumLength {
            appendStringsRecord(run, offset: start, label: label, configuration: configuration, to: &output)
        }
    }
    return output
}

private func stringsGraphicScalar(
    bytes: [UInt8],
    at index: Int,
    width: Int,
    littleEndian: Bool,
    configuration: MSPStringsConfiguration
) -> UInt8? {
    let scalar: UInt32
    if littleEndian {
        scalar = bytes[index..<index + width].enumerated().reduce(UInt32(0)) { partial, item in
            partial | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    } else {
        scalar = bytes[index..<index + width].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
    guard scalar <= UInt32(UInt8.max) else {
        return nil
    }
    let byte = UInt8(scalar)
    return isStringsGraphic(byte, includeAllWhitespace: configuration.includeAllWhitespace, includeEightBit: configuration.encoding == "S") ? byte : nil
}

private func isStringsGraphic(_ byte: UInt8, includeAllWhitespace: Bool, includeEightBit: Bool) -> Bool {
    if includeAllWhitespace, (0x09...0x0D).contains(byte) {
        return true
    }
    if includeEightBit, byte > 0x7F {
        return true
    }
    return byte == 0x09 || (0x20...0x7E).contains(byte)
}

private func appendStringsRecord(
    _ bytes: [UInt8],
    offset: Int,
    label: String?,
    configuration: MSPStringsConfiguration,
    to output: inout Data
) {
    if configuration.printFileName, let label {
        output.append(contentsOf: "\(label): ".utf8)
    }
    if let radix = configuration.radix {
        let prefix: String
        switch radix {
        case "o":
            prefix = String(format: "%7o ", offset)
        case "x":
            prefix = String(format: "%7x ", offset)
        default:
            prefix = String(format: "%7d ", offset)
        }
        output.append(contentsOf: prefix.utf8)
    }
    output.append(contentsOf: bytes)
    output.append(contentsOf: configuration.outputSeparator.utf8)
}

private let mspStringsUsageText = """
Usage: strings [option(s)] [file(s)]
 Display printable strings in [file(s)] (stdin by default)
 The options are:
  -a - --all                Scan the entire file, not just the data section [default]
  -d --data                 Only scan the data sections in the file
  -f --print-file-name      Print the name of the file before each string
  -n <number>               Locate & print any sequence of at least <number>
    --bytes=<number>         displayable characters.  (The default is 4).
  -t --radix={o,d,x}        Print the location of the string in base 8, 10 or 16
  -w --include-all-whitespace Include all whitespace as valid string characters
  -o                        An alias for --radix=o
  -T --target=<BFDNAME>     Specify the binary file format
  -e --encoding={s,S,b,l,B,L} Select character size and endianness:
                            s = 7-bit, S = 8-bit, {b,l} = 16-bit, {B,L} = 32-bit
  --unicode={default|show|invalid|hex|escape|highlight}
  -U {d|s|i|x|e|h}          Specify how to treat UTF-8 encoded unicode characters
  -s --output-separator=<string> String used to separate strings in output.
  @<file>                   Read options from <file>
  -h --help                 Display this information
  -v -V --version           Print the program's version number
strings: supported targets: elf64-x86-64 elf32-i386 elf32-iamcu elf32-x86-64 pei-i386 pe-x86-64 pei-x86-64 elf64-little elf64-big elf32-little elf32-big pe-bigobj-x86-64 pe-i386 pdb srec symbolsrec verilog tekhex binary ihex plugin

"""

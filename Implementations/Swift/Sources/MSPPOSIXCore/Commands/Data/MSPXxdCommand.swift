import Foundation
import MSPCore

public struct MSPXxdCommand: MSPCommand {
    public let name = "xxd"
    public let summary: String? = "Make a hex dump."

    private let spec = MSPPOSIXCommandSpec(
        name: "xxd",
        allowedShortOptions: ["p", "r", "u", "h", "v"],
        shortOptionsRequiringValue: ["c", "g", "l"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("-h") || invocation.arguments.contains("--help") {
            return .success(stdout: mspXxdUsage)
        }
        if invocation.arguments.contains("-v") || invocation.arguments.contains("--version") {
            return .success(stdout: "xxd 2022-01-14 by Juergen Weigert et al.\n")
        }
        let normalizedArguments = invocation.arguments.map { $0 == "-ps" ? "-p" : $0 }
        let parsed = try spec.parse(normalizedArguments)
        var plain = false
        var reverse = false
        var uppercase = false
        var byteLimit: Int?
        var bytesPerRow = 16
        var groupSize = 2
        for option in parsed.options {
            switch option.name {
            case .short("p"):
                plain = true
            case .short("r"):
                reverse = true
            case .short("u"):
                uppercase = true
            case .short("c"):
                bytesPerRow = positiveIntegerOrDefault(option.value, defaultValue: 16)
            case .short("g"):
                groupSize = groupInteger(option.value)
            case .short("l"):
                byteLimit = lengthInteger(option.value)
            default:
                continue
            }
        }
        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.operands,
            context: context,
            command: name
        )
        let rawData = input.inputs.reduce(into: Data()) { data, input in data.append(input.data) }
        if reverse {
            let decoded = plain ? reversePlainHex(rawData) : reversePlainHex(rawData)
            return MSPCommandResult(
                stdoutData: decoded,
                stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
                exitCode: input.exitCode == 0 ? 0 : 2
            )
        }
        var visibleData = rawData
        if let byteLimit, visibleData.count > byteLimit {
            visibleData = visibleData.prefix(byteLimit)
        }
        let stdout: String
        if plain {
            let format = uppercase ? "%02X" : "%02x"
            stdout = visibleData.isEmpty ? "" : visibleData.map { String(format: format, $0) }.joined() + "\n"
        } else {
            var lines: [String] = []
            var offset = 0
            while offset < visibleData.count {
                let end = min(offset + bytesPerRow, visibleData.count)
                let chunk = Array(visibleData[offset..<end])
                let hex = xxdHexColumn(row: chunk, bytesPerRow: bytesPerRow, groupSize: groupSize, uppercase: uppercase)
                let ascii = chunk.map { byte -> Character in
                    (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
                }.map(String.init).joined()
                lines.append(String(format: "%08x: %@  %@", offset, hex, ascii))
                offset += bytesPerRow
            }
            stdout = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }
        return MSPCommandResult(
            stdout: stdout,
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode == 0 ? 0 : 2
        )
    }

    private func lengthInteger(_ value: String?) -> Int? {
        guard let parsed = cStyleInteger(value) else {
            return 0
        }
        return parsed < 0 ? nil : parsed
    }

    private func groupInteger(_ value: String?) -> Int {
        guard let parsed = cStyleInteger(value) else {
            return 0
        }
        return parsed < 0 ? 2 : parsed
    }

    private func positiveIntegerOrDefault(_ value: String?, defaultValue: Int) -> Int {
        guard let parsed = cStyleInteger(value), parsed > 0 else {
            return defaultValue
        }
        return parsed
    }

    private func cStyleInteger(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else {
            return nil
        }
        var sign = 1
        var index = value.startIndex
        if value[index] == "-" {
            sign = -1
            index = value.index(after: index)
        } else if value[index] == "+" {
            index = value.index(after: index)
        }
        let start = index
        while index < value.endIndex, value[index].isNumber {
            index = value.index(after: index)
        }
        guard start != index else {
            return nil
        }
        return sign * (Int(value[start..<index]) ?? 0)
    }

    private func reversePlainHex(_ data: Data) -> Data {
        var output = Data()
        var highNibble: UInt8?
        for byte in data {
            if byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
                continue
            }
            guard let nibble = hexNibble(byte) else {
                continue
            }
            if let high = highNibble {
                output.append((high << 4) | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }
        return output
    }

    private func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}

private let mspXxdUsage = """
Usage: xxd [options] [infile [outfile]]
Make a hexdump or do the reverse.

"""

private func xxdHexColumn(row: [UInt8], bytesPerRow: Int, groupSize: Int, uppercase: Bool = false) -> String {
    var hex = ""
    let format = uppercase ? "%02X" : "%02x"
    for index in 0..<bytesPerRow {
        if index < row.count {
            hex += String(format: format, row[index])
        } else {
            hex += "  "
        }
        if shouldInsertGroupSeparator(afterByteIndex: index, bytesPerRow: bytesPerRow, groupSize: groupSize) {
            hex += " "
        }
    }
    return hex
}

private func shouldInsertGroupSeparator(afterByteIndex index: Int, bytesPerRow: Int, groupSize: Int) -> Bool {
    guard groupSize > 0 else { return false }
    let nextIndex = index + 1
    return nextIndex < bytesPerRow && nextIndex % groupSize == 0
}

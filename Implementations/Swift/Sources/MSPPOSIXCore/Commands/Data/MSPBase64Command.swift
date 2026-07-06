import Foundation
import MSPCore

public struct MSPBase64Command: MSPCommand {
    public let name = "base64"
    public let summary: String? = "Base64 encode or decode data."

    private let spec = MSPPOSIXCommandSpec(
        name: "base64",
        allowedShortOptions: ["d", "i"],
        allowedLongOptions: ["decode", "ignore-garbage", "help", "version"],
        shortOptionsRequiringValue: ["w"],
        longOptionsRequiringValue: ["wrap"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspBase64Usage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "base64 (GNU coreutils) 9.1\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        try spec.requireOperandCount(parsed.operands, max: 1)
        let decode = parsed.options.contains { $0.matches(short: "d", long: "decode") }
        let ignoreGarbage = parsed.options.contains { $0.matches(short: "i", long: "ignore-garbage") }
        let wrapColumn = try wrapColumn(from: parsed.options)
        if parsed.operands.count == 1, parsed.operands[0] != "-" {
            return try runFileOperand(
                parsed.operands[0],
                context: context,
                decode: decode,
                ignoreGarbage: ignoreGarbage,
                wrapColumn: wrapColumn
            )
        }
        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.operands,
            context: context,
            command: name
        )
        let data = input.inputs.reduce(into: Data()) { output, input in output.append(input.data) }
        if decode {
            let decoded = decodedData(from: data, ignoreGarbage: ignoreGarbage)
            let diagnostics = input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n"
            return MSPCommandResult(
                stdoutData: decoded.data,
                stderr: diagnostics + (decoded.invalid ? "base64: invalid input\n" : ""),
                exitCode: decoded.invalid ? 1 : input.exitCode
            )
        }
        return MSPCommandResult(
            stdout: wrapped(data.base64EncodedString(), column: wrapColumn),
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    private func runFileOperand(
        _ operand: String,
        context: MSPCommandContext,
        decode: Bool,
        ignoreGarbage: Bool,
        wrapColumn: Int
    ) throws -> MSPCommandResult {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            if decode {
                var decoder = MSPBase64StreamingDecoder(ignoreGarbage: ignoreGarbage)
                try readFileChunks(fileSystem: fileSystem, path: operand, currentDirectory: context.currentDirectory) { chunk in
                    decoder.append(chunk)
                }
                let decoded = decoder.finalize()
                return MSPCommandResult(
                    stdoutData: decoded.data,
                    stderr: decoded.invalid ? "base64: invalid input\n" : "",
                    exitCode: decoded.invalid ? 1 : 0
                )
            }

            var encoder = MSPBase64StreamingEncoder(wrapColumn: wrapColumn)
            try readFileChunks(fileSystem: fileSystem, path: operand, currentDirectory: context.currentDirectory) { chunk in
                encoder.append(chunk)
            }
            return .success(stdout: encoder.finalize())
        } catch {
            return MSPCommandResult(
                stderr: "base64: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                exitCode: 1
            )
        }
    }

    private func readFileChunks(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        chunkSize: Int = 32 * 1024,
        consume: (Data) throws -> Void
    ) throws {
        let info = try fileSystem.stat(path, from: currentDirectory)
        guard let size = info.size else {
            try consume(fileSystem.readFile(path, from: currentDirectory))
            return
        }
        var offset: UInt64 = 0
        while offset < UInt64(max(0, size)) {
            let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: chunkSize)
            guard !chunk.isEmpty else {
                break
            }
            try consume(chunk)
            offset += UInt64(chunk.count)
        }
    }

    private func wrapColumn(from options: [MSPPOSIXOption]) throws -> Int {
        var column = 76
        for option in options {
            if option.matches(short: "w") || option.matches(long: "wrap") {
                guard let value = option.value, let parsed = Int(value), parsed >= 0 else {
                    throw MSPCommandFailure(
                        result: .failure(
                            exitCode: 1,
                            stderr: "base64: invalid wrap size: \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? ""))\n"
                        )
                    )
                }
                column = parsed
            }
        }
        return column
    }

    private func decodedData(from data: Data, ignoreGarbage: Bool) -> MSPBase64DecodeResult {
        var significant: [UInt8] = []
        var invalid = false
        for byte in data {
            if mspBase64Value(byte) != nil || byte == UInt8(ascii: "=") {
                significant.append(byte)
            } else if mspBase64IsWhitespace(byte) || ignoreGarbage {
                continue
            } else {
                invalid = true
                break
            }
        }

        var decoded = Data()
        var index = 0
        var sawPadding = false
        while index + 4 <= significant.count {
            let quartet = Array(significant[index..<(index + 4)])
            if sawPadding {
                invalid = true
                break
            }
            guard let bytes = mspBase64DecodeQuartet(quartet) else {
                invalid = true
                break
            }
            decoded.append(contentsOf: bytes)
            sawPadding = quartet.contains(UInt8(ascii: "="))
            index += 4
        }

        if index < significant.count {
            if sawPadding {
                invalid = true
            } else {
                decoded.append(contentsOf: mspBase64DecodePartial(Array(significant[index...])))
                invalid = true
            }
        }

        return MSPBase64DecodeResult(data: decoded, invalid: invalid)
    }

    private func wrapped(_ text: String, column: Int) -> String {
        guard !text.isEmpty else {
            return ""
        }
        guard column > 0 else {
            return text
        }
        guard text.count > column else {
            return text + "\n"
        }
        var lines: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: column, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private let mspBase64Usage = """
Usage: base64 [OPTION]... [FILE]
Base64 encode or decode FILE, or standard input, to standard output.

"""

private struct MSPBase64DecodeResult {
    var data: Data
    var invalid: Bool
}

private struct MSPBase64StreamingEncoder {
    var wrapColumn: Int
    private var carry = Data()
    private var output = ""
    private var currentColumn = 0

    init(wrapColumn: Int) {
        self.wrapColumn = wrapColumn
    }

    mutating func append(_ data: Data) {
        var buffer = carry
        buffer.append(data)
        let encodableCount = (buffer.count / 3) * 3
        guard encodableCount > 0 else {
            carry = buffer
            return
        }
        appendEncoded(buffer.prefix(encodableCount).base64EncodedString())
        carry = buffer.count > encodableCount ? Data(buffer.dropFirst(encodableCount)) : Data()
    }

    mutating func finalize() -> String {
        if !carry.isEmpty {
            appendEncoded(carry.base64EncodedString())
            carry.removeAll()
        }
        if wrapColumn > 0, !output.isEmpty, !output.hasSuffix("\n") {
            output.append("\n")
        }
        return output
    }

    private mutating func appendEncoded(_ encoded: String) {
        guard wrapColumn > 0 else {
            output.append(encoded)
            return
        }
        for character in encoded {
            output.append(character)
            currentColumn += 1
            if currentColumn == wrapColumn {
                output.append("\n")
                currentColumn = 0
            }
        }
    }
}

private struct MSPBase64StreamingDecoder {
    var ignoreGarbage: Bool
    private var significant: [UInt8] = []
    private var decoded = Data()
    private var invalid = false
    private var sawPadding = false

    init(ignoreGarbage: Bool) {
        self.ignoreGarbage = ignoreGarbage
    }

    mutating func append(_ data: Data) {
        guard !invalid else {
            return
        }
        for byte in data {
            if mspBase64Value(byte) != nil || byte == UInt8(ascii: "=") {
                significant.append(byte)
                processCompleteQuartets()
            } else if mspBase64IsWhitespace(byte) || ignoreGarbage {
                continue
            } else {
                invalid = true
                return
            }
            if invalid {
                return
            }
        }
    }

    mutating func finalize() -> MSPBase64DecodeResult {
        if !significant.isEmpty {
            if sawPadding {
                invalid = true
            } else {
                decoded.append(contentsOf: mspBase64DecodePartial(significant))
                invalid = true
            }
        }
        return MSPBase64DecodeResult(data: decoded, invalid: invalid)
    }

    private mutating func processCompleteQuartets() {
        while significant.count >= 4 {
            if sawPadding {
                invalid = true
                return
            }
            let quartet = Array(significant.prefix(4))
            significant.removeFirst(4)
            guard let bytes = mspBase64DecodeQuartet(quartet) else {
                invalid = true
                return
            }
            decoded.append(contentsOf: bytes)
            sawPadding = quartet.contains(UInt8(ascii: "="))
        }
    }
}

private func mspBase64IsWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x09 || byte == 0x0a || byte == 0x0b || byte == 0x0c || byte == 0x0d || byte == 0x20
}

private func mspBase64Value(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"):
        return byte - UInt8(ascii: "A")
    case UInt8(ascii: "a")...UInt8(ascii: "z"):
        return byte - UInt8(ascii: "a") + 26
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0") + 52
    case UInt8(ascii: "+"):
        return 62
    case UInt8(ascii: "/"):
        return 63
    default:
        return nil
    }
}

private func mspBase64DecodeQuartet(_ quartet: [UInt8]) -> [UInt8]? {
    guard quartet.count == 4,
          let first = mspBase64Value(quartet[0]),
          let second = mspBase64Value(quartet[1]) else {
        return nil
    }
    if quartet[2] == UInt8(ascii: "=") {
        guard quartet[3] == UInt8(ascii: "=") else {
            return nil
        }
        return [(first << 2) | (second >> 4)]
    }
    guard let third = mspBase64Value(quartet[2]) else {
        return nil
    }
    if quartet[3] == UInt8(ascii: "=") {
        return [
            (first << 2) | (second >> 4),
            ((second & 0x0f) << 4) | (third >> 2)
        ]
    }
    guard let fourth = mspBase64Value(quartet[3]) else {
        return nil
    }
    return [
        (first << 2) | (second >> 4),
        ((second & 0x0f) << 4) | (third >> 2),
        ((third & 0x03) << 6) | fourth
    ]
}

private func mspBase64DecodePartial(_ partial: [UInt8]) -> [UInt8] {
    guard partial.count >= 2,
          let first = mspBase64Value(partial[0]),
          let second = mspBase64Value(partial[1]) else {
        return []
    }
    if partial.count == 2 || partial[2] == UInt8(ascii: "=") {
        return [(first << 2) | (second >> 4)]
    }
    guard let third = mspBase64Value(partial[2]) else {
        return []
    }
    return [
        (first << 2) | (second >> 4),
        ((second & 0x0f) << 4) | (third >> 2)
    ]
}

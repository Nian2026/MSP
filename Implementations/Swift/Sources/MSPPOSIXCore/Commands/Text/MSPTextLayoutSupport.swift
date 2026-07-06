import Foundation
import MSPCore

struct MSPTextLayoutTabStops {
    var stops: [Int]
    var repeatedSize: Int?
    var extendSize: Int? = nil
    var incrementSize: Int? = nil

    static let `default` = MSPTextLayoutTabStops(stops: [], repeatedSize: 8)

    static func canParseObsoleteOption(_ text: String) -> Bool {
        guard text.first?.isNumber == true else {
            return false
        }
        return canParseTabList(text)
    }

    static func parse(_ text: String, command: String) throws -> MSPTextLayoutTabStops {
        var values: [Int] = []
        var extendSize: Int?
        var incrementSize: Int?
        var modifier: Character?
        var digits = ""
        var index = text.startIndex

        func commitDigits() throws {
            guard !digits.isEmpty else {
                return
            }
            guard let value = Int(digits) else {
                throw MSPCommandFailure(result: .failure(
                    stderr: "\(command): tab stop is too large \(MSPPOSIXCommandSupport.gnuQuote(digits))\n"
                ))
            }
            switch modifier {
            case "/":
                if extendSize != nil {
                    throw MSPCommandFailure(result: .failure(
                        stderr: "\(command): '/' specifier only allowed with the last value\n"
                    ))
                }
                extendSize = value
            case "+":
                if incrementSize != nil {
                    throw MSPCommandFailure(result: .failure(
                        stderr: "\(command): '+' specifier only allowed with the last value\n"
                    ))
                }
                incrementSize = value
            default:
                values.append(value)
            }
            digits.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "," || character == " " || character == "\t" {
                try commitDigits()
                index = text.index(after: index)
                continue
            }
            if character == "/" || character == "+" {
                if !digits.isEmpty {
                    let rest = String(text[index...])
                    throw MSPCommandFailure(result: .failure(
                        stderr: "\(command): '\(character)' specifier not at start of number: \(MSPPOSIXCommandSupport.gnuQuote(rest))\n"
                    ))
                }
                modifier = character
                index = text.index(after: index)
                continue
            }
            if character.isNumber {
                digits.append(character)
                index = text.index(after: index)
                continue
            }
            throw tabStopFailure(command: command, text: String(text[index...]))
        }
        try commitDigits()
        if values.isEmpty, extendSize == nil, incrementSize == nil {
            return .default
        }
        if values.contains(0) || extendSize == 0 || incrementSize == 0 {
            throw MSPCommandFailure(result: .failure(stderr: "\(command): tab size cannot be 0\n"))
        }
        for pair in zip(values, values.dropFirst()) where pair.1 <= pair.0 {
            throw MSPCommandFailure(result: .failure(stderr: "\(command): tab sizes must be ascending\n"))
        }
        if extendSize != nil, incrementSize != nil {
            throw MSPCommandFailure(result: .failure(
                stderr: "\(command): '/' specifier is mutually exclusive with '+'\n"
            ))
        }
        if values.count == 1, extendSize == nil, incrementSize == nil {
            return MSPTextLayoutTabStops(stops: [], repeatedSize: values[0])
        }
        if values.isEmpty, let extendSize {
            return MSPTextLayoutTabStops(stops: [], repeatedSize: extendSize)
        }
        if values.isEmpty, let incrementSize {
            return MSPTextLayoutTabStops(stops: [], repeatedSize: incrementSize)
        }
        return MSPTextLayoutTabStops(
            stops: values,
            repeatedSize: nil,
            extendSize: extendSize,
            incrementSize: incrementSize
        )
    }

    func next(after column: Int) -> Int? {
        if let repeatedSize {
            return column + (repeatedSize - (column % repeatedSize))
        }
        if let stop = stops.first(where: { $0 > column }) {
            return stop
        }
        if let extendSize {
            return column + (extendSize - (column % extendSize))
        }
        if let incrementSize, let endTab = stops.last {
            return column + (incrementSize - ((column - endTab) % incrementSize))
        }
        return nil
    }

    private static func canParseTabList(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
            character.isNumber || character == "," || character == " " || character == "\t" || character == "/" || character == "+"
        }
    }

    private static func tabStopFailure(command: String, text: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(
            stderr: "\(command): tab size contains invalid character(s): \(MSPPOSIXCommandSupport.gnuQuote(text))\n"
        ))
    }
}

func mspTextLayoutLineRecords(_ data: Data) -> [(bytes: [UInt8], hasNewline: Bool)] {
    let bytes = [UInt8](data)
    guard !bytes.isEmpty else {
        return []
    }
    var records: [(bytes: [UInt8], hasNewline: Bool)] = []
    var start = 0
    for index in bytes.indices where bytes[index] == 0x0A {
        records.append((Array(bytes[start..<index]), true))
        start = index + 1
    }
    if start < bytes.count {
        records.append((Array(bytes[start..<bytes.count]), false))
    }
    return records
}

func mspTextLayoutData(
    operands: [String],
    context: MSPCommandContext,
    command: String,
    fileReadDiagnostic: ((String, String) -> String)? = nil
) async throws -> (inputs: [MSPPOSIXInput], diagnostics: [String], exitCode: Int32) {
    try await MSPPOSIXCommandSupport.inputData(
        operands: operands,
        context: context,
        command: command,
        fileReadDiagnostic: fileReadDiagnostic
    )
}

func mspTextLayoutCollectStandardInput(_ context: MSPCommandContext) async throws -> Data {
    try await MSPPOSIXCommandSupport.collectedStandardInputData(from: context)
}

func mspTextLayoutRunStreamingFromStandardInput(
    invocation: MSPCommandInvocation,
    context: MSPCommandContext,
    command: (MSPCommandInvocation, MSPCommandContext) async throws -> MSPCommandResult
) async throws -> MSPCommandResult {
    var bufferedContext = context
    bufferedContext.standardInput = try await mspTextLayoutCollectStandardInput(context)
    bufferedContext.standardInputStream = nil
    return try await command(invocation, bufferedContext)
}

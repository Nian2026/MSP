import Foundation
import MSPCore

enum MSPXargsStreamingRecord {
    case value(String)
    case logicalLine([String])
}

struct MSPXargsStreamingInputProcessor {
    private enum Mode {
        case defaultWords
        case delimitedValue(Data)
        case lineValue
        case logicalLine
    }

    private enum WordState {
        case space
        case normal
        case quote(UInt8)
        case backslash
    }

    private let options: MSPXargsStreamingOptions
    private let mode: Mode
    private var stopped = false
    private var token = Data()
    private var wordState = WordState.space
    private var wordStarted = false
    private var pendingDelimiter = Data()

    init(options: MSPXargsStreamingOptions) {
        self.options = options
        if let maxLines = options.maxLines,
           options.replacement == nil,
           options.delimiter == nil,
           !options.nullDelimited,
           maxLines > 0 {
            self.mode = .logicalLine
        } else if options.replacement != nil {
            self.mode = .lineValue
        } else if options.nullDelimited {
            self.mode = .delimitedValue(Data([0]))
        } else if let delimiter = options.delimiter {
            self.mode = .delimitedValue(Data(String(delimiter).utf8))
        } else {
            self.mode = .defaultWords
        }
    }

    var shouldStopConsumingInput: Bool {
        stopped
    }

    mutating func append(_ chunk: Data) throws -> [MSPXargsStreamingRecord] {
        guard !stopped, !chunk.isEmpty else {
            return []
        }
        switch mode {
        case .defaultWords:
            return try appendDefaultWords(chunk)
        case .delimitedValue(let delimiter):
            return appendDelimited(chunk, delimiter: delimiter)
        case .lineValue:
            return appendLineValues(chunk)
        case .logicalLine:
            return try appendLogicalLines(chunk)
        }
    }

    mutating func finish() throws -> [MSPXargsStreamingRecord] {
        guard !stopped else {
            return []
        }
        switch mode {
        case .defaultWords:
            if case .quote(let quote) = wordState {
                let quoteName = quote == UInt8(ascii: "'") ? "single quote" : "double quote"
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "xargs: unmatched \(quoteName); by default quotes are special to xargs unless you use the -0 option\n"
                ))
            }
            if case .backslash = wordState {
                token.append(UInt8(ascii: "\\"))
            }
            guard wordStarted || !token.isEmpty else {
                return []
            }
            let value = stringAndResetToken()
            return emitValue(value).map { [$0] } ?? []
        case .delimitedValue:
            if !pendingDelimiter.isEmpty {
                token.append(pendingDelimiter)
                pendingDelimiter.removeAll(keepingCapacity: true)
            }
            guard !token.isEmpty else {
                return []
            }
            let value = stringAndResetToken()
            return emitValue(value).map { [$0] } ?? []
        case .lineValue:
            guard !token.isEmpty else {
                return []
            }
            let value = stringAndResetToken()
            return emitValue(value).map { [$0] } ?? []
        case .logicalLine:
            guard !token.isEmpty else {
                return []
            }
            return try emitLogicalLineAndReset()
        }
    }

    private mutating func appendDefaultWords(_ chunk: Data) throws -> [MSPXargsStreamingRecord] {
        var records: [MSPXargsStreamingRecord] = []
        for byte in chunk {
            switch wordState {
            case .space:
                if Self.isWhitespace(byte) {
                    continue
                }
                wordState = .normal
                try consumeNormalWordByte(byte, records: &records)
            case .normal:
                try consumeNormalWordByte(byte, records: &records)
            case .quote(let quote):
                if byte == quote {
                    wordState = .normal
                    wordStarted = true
                } else if Self.isNewline(byte) {
                    let quoteName = quote == UInt8(ascii: "'") ? "single quote" : "double quote"
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "xargs: unmatched \(quoteName); by default quotes are special to xargs unless you use the -0 option\n"
                    ))
                } else {
                    token.append(byte)
                    wordStarted = true
                }
            case .backslash:
                token.append(byte)
                wordStarted = true
                wordState = .normal
            }
            if stopped {
                break
            }
        }
        return records
    }

    private mutating func consumeNormalWordByte(
        _ byte: UInt8,
        records: inout [MSPXargsStreamingRecord]
    ) throws {
        if Self.isWhitespace(byte) {
            if wordStarted || !token.isEmpty {
                if let record = emitValue(stringAndResetToken()) {
                    records.append(record)
                }
            }
            wordState = .space
            wordStarted = false
            return
        }
        switch byte {
        case UInt8(ascii: "\\"):
            wordState = .backslash
        case UInt8(ascii: "'"), UInt8(ascii: "\""):
            wordState = .quote(byte)
            wordStarted = true
        default:
            token.append(byte)
            wordStarted = true
        }
    }

    private mutating func appendDelimited(
        _ chunk: Data,
        delimiter: Data
    ) -> [MSPXargsStreamingRecord] {
        guard !delimiter.isEmpty else {
            token.append(chunk)
            return []
        }
        var records: [MSPXargsStreamingRecord] = []
        for byte in chunk {
            pendingDelimiter.append(byte)
            while pendingDelimiter.count > delimiter.count {
                token.append(pendingDelimiter.removeFirst())
            }
            if pendingDelimiter == delimiter {
                pendingDelimiter.removeAll(keepingCapacity: true)
                if let record = emitValue(stringAndResetToken()) {
                    records.append(record)
                }
                if stopped {
                    break
                }
            } else if !delimiter.starts(with: pendingDelimiter) {
                token.append(pendingDelimiter.removeFirst())
            }
        }
        return records
    }

    private mutating func appendLineValues(_ chunk: Data) -> [MSPXargsStreamingRecord] {
        var records: [MSPXargsStreamingRecord] = []
        for byte in chunk {
            if Self.isNewline(byte) {
                if !token.isEmpty,
                   let record = emitValue(stringAndResetToken()) {
                    records.append(record)
                } else {
                    token.removeAll(keepingCapacity: true)
                }
                if stopped {
                    break
                }
            } else {
                token.append(byte)
            }
        }
        return records
    }

    private mutating func appendLogicalLines(_ chunk: Data) throws -> [MSPXargsStreamingRecord] {
        var records: [MSPXargsStreamingRecord] = []
        for byte in chunk {
            if Self.isNewline(byte) {
                records.append(contentsOf: try emitLogicalLineAndReset())
                if stopped {
                    break
                }
            } else {
                token.append(byte)
            }
        }
        return records
    }

    private mutating func emitValue(_ value: String) -> MSPXargsStreamingRecord? {
        if case .delimitedValue = mode {
            return .value(value)
        }
        if let eofMarker = options.eofMarker,
           !eofMarker.isEmpty,
           value == eofMarker {
            stopped = true
            return nil
        }
        return .value(value)
    }

    private mutating func emitLogicalLineAndReset() throws -> [MSPXargsStreamingRecord] {
        let rawLine = stringAndResetToken()
        let words = try mspPOSIXXargsShellWords(from: rawLine)
        guard !words.isEmpty else {
            return []
        }
        if let eofMarker = options.eofMarker,
           !eofMarker.isEmpty,
           let eofIndex = words.firstIndex(of: eofMarker) {
            stopped = true
            let prefix = Array(words[..<eofIndex])
            return prefix.isEmpty ? [] : [.logicalLine(prefix)]
        }
        return [.logicalLine(words)]
    }

    private mutating func stringAndResetToken() -> String {
        let value = String(decoding: token, as: UTF8.self)
        token.removeAll(keepingCapacity: true)
        return value
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    private static func isNewline(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }
}

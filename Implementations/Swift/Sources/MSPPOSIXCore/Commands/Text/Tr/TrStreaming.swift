import Foundation
import MSPCore

func streamTrScalarOutput(
    standardInput: any MSPCommandInputStream,
    standardOutput: any MSPCommandOutputStream,
    processor: inout TrScalarProcessor
) async throws {
    var pending = Data()
    while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
        pending.append(chunk)
        let split = trDecodableUTF8Prefix(in: pending)
        pending = split.remainder
        let output = processor.process(split.text)
        if !output.isEmpty {
            try await standardOutput.write(Data(output.utf8))
        }
    }
    if !pending.isEmpty {
        let output = processor.process(String(decoding: pending, as: UTF8.self))
        if !output.isEmpty {
            try await standardOutput.write(Data(output.utf8))
        }
    }
}

func streamTrByteOutput(
    standardInput: any MSPCommandInputStream,
    standardOutput: any MSPCommandOutputStream,
    processor: inout TrByteProcessor
) async throws {
    while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
        let output = processor.process(chunk)
        if !output.isEmpty {
            try await standardOutput.write(output)
        }
    }
}

private func trDecodableUTF8Prefix(in data: Data) -> (text: String, remainder: Data) {
    let incompleteLength = trTrailingIncompleteUTF8Length(in: data)
    guard incompleteLength > 0 else {
        return (String(decoding: data, as: UTF8.self), Data())
    }
    let prefixEnd = data.count - incompleteLength
    return (
        String(decoding: data.prefix(prefixEnd), as: UTF8.self),
        Data(data.suffix(incompleteLength))
    )
}

private func trTrailingIncompleteUTF8Length(in data: Data) -> Int {
    guard !data.isEmpty else {
        return 0
    }
    var leadIndex = data.count - 1
    while leadIndex >= 0, trIsUTF8ContinuationByte(data[leadIndex]) {
        if leadIndex == 0 {
            return 0
        }
        leadIndex -= 1
    }
    let expectedLength = trUTF8SequenceLength(lead: data[leadIndex])
    guard expectedLength > 1 else {
        return 0
    }
    let availableLength = data.count - leadIndex
    return availableLength < expectedLength ? availableLength : 0
}

private func trIsUTF8ContinuationByte(_ byte: UInt8) -> Bool {
    byte & 0b1100_0000 == 0b1000_0000
}

private func trUTF8SequenceLength(lead byte: UInt8) -> Int {
    if byte & 0b1000_0000 == 0 {
        return 1
    }
    if byte & 0b1110_0000 == 0b1100_0000 {
        return 2
    }
    if byte & 0b1111_0000 == 0b1110_0000 {
        return 3
    }
    if byte & 0b1111_1000 == 0b1111_0000 {
        return 4
    }
    return 0
}

import Foundation
import MSPCore

final class MSPPOSIXLineStreamReader {
    private let stream: any MSPCommandInputStream
    private var buffer = Data()
    private var reachedEOF = false

    init(stream: any MSPCommandInputStream) {
        self.stream = stream
    }

    func readLine(maxBytes: Int = 32 * 1024) async throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)
                return String(decoding: lineData, as: UTF8.self)
            }

            if reachedEOF {
                guard !buffer.isEmpty else {
                    return nil
                }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: false)
                return String(decoding: lineData, as: UTF8.self)
            }

            if let chunk = try await stream.read(maxBytes: maxBytes) {
                buffer.append(chunk)
            } else {
                reachedEOF = true
            }
        }
    }
}

func mspPOSIXTextRecords(in data: Data, delimiter: UInt8) -> [Data] {
    guard !data.isEmpty else {
        return []
    }
    var records: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == delimiter {
        records.append(data.subdata(in: start..<index))
        start = index + 1
    }
    if start < data.endIndex {
        records.append(data.subdata(in: start..<data.endIndex))
    }
    return records
}

func mspPOSIXRecordsOutput(_ records: [Data], delimiter: UInt8) -> Data {
    guard !records.isEmpty else {
        return Data()
    }
    return records.reduce(into: Data()) { output, record in
        output.append(record)
        output.append(delimiter)
    }
}

func mspPOSIXLines(_ text: String) -> [String] {
    guard !text.isEmpty else {
        return []
    }
    var lines: [String] = []
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\n" {
            lines.append(String(text[start..<index]))
            index = text.index(after: index)
            start = index
            continue
        }
        index = text.index(after: index)
    }
    if start < text.endIndex {
        lines.append(String(text[start..<text.endIndex]))
    }
    return lines
}

func mspPOSIXJoinedLines(_ lines: [String]) -> String {
    guard !lines.isEmpty else {
        return ""
    }
    return lines.joined(separator: "\n") + "\n"
}

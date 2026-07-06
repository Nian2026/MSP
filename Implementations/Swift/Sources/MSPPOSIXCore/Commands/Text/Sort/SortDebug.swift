import Foundation

func sortDebugOutput(records: [SortRecord], options: SortOptions) -> Data {
    var output = Data()
    for record in records {
        let line = String(decoding: record.data, as: UTF8.self)
        output.append(Data(line.replacingOccurrences(of: "\t", with: ">").utf8))
        output.append(0x0A)
        for mark in sortDebugMarks(line: line, options: options) {
            output.append(Data(mark.utf8))
            output.append(0x0A)
        }
    }
    return output
}

private func sortDebugMarks(line: String, options: SortOptions) -> [String] {
    guard !options.keys.isEmpty else {
        return [line.isEmpty ? "^ no match for key" : String(repeating: "_", count: line.utf8.count)]
    }
    return options.keys.map { key in
        let ordering = key.effectiveOrdering(options: options)
        let bytes = Array(line.utf8)
        let separator = sortFieldSeparatorByte(options.fieldSeparator)
        let start = min(bytes.count, sortKeyStart(in: bytes, key: key, ordering: ordering, separator: separator))
        let end = min(bytes.count, max(start, sortKeyEnd(in: bytes, key: key, ordering: ordering, separator: separator)))
        if end == start {
            return String(repeating: " ", count: start) + "^ no match for key"
        }
        return String(repeating: " ", count: start) + String(repeating: "_", count: end - start)
    }
}

import Foundation

struct MSPJoinRow {
    var fields: [Data]
    var key: Data
    var originalText: Data
    var lineNumber: Int
}

struct MSPJoinRowGroup {
    var key: Data
    var rows: ArraySlice<MSPJoinRow>
    var endIndex: Int
}

func mspJoinRows(
    in data: Data,
    recordDelimiter: UInt8,
    separator: Data?,
    joinField: Int,
    ignoreCase: Bool
) -> [MSPJoinRow] {
    mspPOSIXTextRecords(in: data, delimiter: recordDelimiter).enumerated().compactMap { offset, record in
        let fields = mspJoinFields(in: record, separator: separator)
        let key = mspJoinKey(fields, field: joinField, ignoreCase: ignoreCase)
        return MSPJoinRow(fields: fields, key: key, originalText: record, lineNumber: offset + 1)
    }
}

func mspFirstDisorderedJoinLine(in rows: [MSPJoinRow]) -> (line: Int, text: String)? {
    guard rows.count > 1 else {
        return nil
    }
    for index in 1..<rows.count where mspJoinCompare(rows[index - 1].key, rows[index].key) > 0 {
        return (line: rows[index].lineNumber, text: String(decoding: rows[index].originalText, as: UTF8.self))
    }
    return nil
}

func mspJoinRowGroup(in rows: [MSPJoinRow], startingAt startIndex: Int) -> MSPJoinRowGroup {
    let key = rows[startIndex].key
    var endIndex = startIndex + 1
    while endIndex < rows.count, rows[endIndex].key == key {
        endIndex += 1
    }
    return MSPJoinRowGroup(key: key, rows: rows[startIndex..<endIndex], endIndex: endIndex)
}

func mspJoinCompare(_ left: Data, _ right: Data) -> Int {
    let leftBytes = Array(left)
    let rightBytes = Array(right)
    let count = min(leftBytes.count, rightBytes.count)
    for index in 0..<count {
        if leftBytes[index] < rightBytes[index] {
            return -1
        }
        if leftBytes[index] > rightBytes[index] {
            return 1
        }
    }
    if leftBytes.count == rightBytes.count {
        return 0
    }
    return leftBytes.count < rightBytes.count ? -1 : 1
}

private func mspJoinFields(in line: Data, separator: Data?) -> [Data] {
    if let separator {
        if separator == Data([0x0A]) {
            return [line]
        }
        let byte = separator.first ?? 0x0A
        var fields: [Data] = []
        var current = Data()
        for value in line {
            if value == byte {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(value)
            }
        }
        fields.append(current)
        return fields
    }

    var fields: [Data] = []
    var current = Data()
    for value in line {
        if value == 0x20 || value == 0x09 {
            if !current.isEmpty {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            }
        } else {
            current.append(value)
        }
    }
    if !current.isEmpty {
        fields.append(current)
    }
    return fields
}

private func mspJoinKey(_ fields: [Data], field: Int, ignoreCase: Bool) -> Data {
    let index = field - 1
    let key = index >= 0 && index < fields.count ? fields[index] : Data()
    return ignoreCase ? mspJoinASCIIFolded(key) : key
}

private func mspJoinASCIIFolded(_ data: Data) -> Data {
    Data(data.map { byte in
        if byte >= 0x41 && byte <= 0x5A {
            return byte + 0x20
        }
        return byte
    })
}

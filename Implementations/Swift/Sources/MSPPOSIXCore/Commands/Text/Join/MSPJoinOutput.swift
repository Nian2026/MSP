import Foundation

enum MSPJoinOutputField: Equatable {
    case joinField
    case fileField(file: Int, field: Int)
}

func mspJoinOutputLine(
    key: Data,
    firstRow: [Data]?,
    secondRow: [Data]?,
    firstJoinField: Int,
    secondJoinField: Int,
    outputFields: [MSPJoinOutputField]?,
    autoCounts: (first: Int, second: Int)?,
    separator: Data,
    emptyReplacement: Data?
) -> Data {
    let displayKey = mspJoinDisplayKey(
        firstRow: firstRow,
        secondRow: secondRow,
        firstJoinField: firstJoinField,
        secondJoinField: secondJoinField,
        fallbackKey: key
    )
    if let autoCounts {
        return mspJoinAutoOutputLine(
            displayKey: displayKey,
            firstRow: firstRow,
            secondRow: secondRow,
            firstJoinField: firstJoinField,
            secondJoinField: secondJoinField,
            firstFieldCount: autoCounts.first,
            secondFieldCount: autoCounts.second,
            separator: separator,
            emptyReplacement: emptyReplacement
        )
    }
    guard let outputFields else {
        if let firstRow, let secondRow {
            var row = [displayKey]
            row.append(contentsOf: mspRemainingJoinFields(firstRow, excluding: firstJoinField))
            row.append(contentsOf: mspRemainingJoinFields(secondRow, excluding: secondJoinField))
            return mspJoinJoinedData(row, separator: separator)
        }
        return mspJoinJoinedData(firstRow ?? secondRow ?? [], separator: separator)
    }
    return mspJoinJoinedData(outputFields.map { outputField in
        switch outputField {
        case .joinField:
            return displayKey
        case .fileField(let file, let field):
            let row = file == 1 ? firstRow : secondRow
            guard let row else { return emptyReplacement ?? Data() }
            let index = field - 1
            guard index >= 0, index < row.count else { return emptyReplacement ?? Data() }
            return row[index]
        }
    }, separator: separator)
}

func mspJoinOutputData(_ lines: [Data], delimiter: UInt8) -> Data {
    var data = Data()
    for line in lines {
        data.append(line)
        data.append(delimiter)
    }
    return data
}

private func mspJoinAutoOutputLine(
    displayKey: Data,
    firstRow: [Data]?,
    secondRow: [Data]?,
    firstJoinField: Int,
    secondJoinField: Int,
    firstFieldCount: Int,
    secondFieldCount: Int,
    separator: Data,
    emptyReplacement: Data?
) -> Data {
    var row = [displayKey]
    row.append(contentsOf: mspJoinAutoRemainingFields(
        firstRow,
        joinField: firstJoinField,
        fieldCount: firstFieldCount,
        emptyReplacement: emptyReplacement
    ))
    row.append(contentsOf: mspJoinAutoRemainingFields(
        secondRow,
        joinField: secondJoinField,
        fieldCount: secondFieldCount,
        emptyReplacement: emptyReplacement
    ))
    return mspJoinJoinedData(row, separator: separator)
}

private func mspJoinAutoRemainingFields(
    _ fields: [Data]?,
    joinField: Int,
    fieldCount: Int,
    emptyReplacement: Data?
) -> [Data] {
    guard fieldCount > 0 else {
        return []
    }
    return (1...fieldCount).compactMap { field in
        guard field != joinField else {
            return nil
        }
        let index = field - 1
        guard let fields, fields.indices.contains(index) else {
            return emptyReplacement ?? Data()
        }
        return fields[index]
    }
}

private func mspJoinDisplayKey(
    firstRow: [Data]?,
    secondRow: [Data]?,
    firstJoinField: Int,
    secondJoinField: Int,
    fallbackKey: Data
) -> Data {
    if let firstRow {
        let index = firstJoinField - 1
        if firstRow.indices.contains(index) {
            return firstRow[index]
        }
    }
    if let secondRow {
        let index = secondJoinField - 1
        if secondRow.indices.contains(index) {
            return secondRow[index]
        }
    }
    return fallbackKey
}

private func mspRemainingJoinFields(_ fields: [Data], excluding field: Int) -> [Data] {
    let excludedIndex = field - 1
    return fields.enumerated().compactMap { offset, value in
        offset == excludedIndex ? nil : value
    }
}

private func mspJoinJoinedData(_ fields: [Data], separator: Data) -> Data {
    var output = Data()
    for (index, field) in fields.enumerated() {
        if index > 0 {
            output.append(separator)
        }
        output.append(field)
    }
    return output
}

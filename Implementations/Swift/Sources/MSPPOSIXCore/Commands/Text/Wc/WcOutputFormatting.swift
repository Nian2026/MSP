import Foundation

func wcLine(
    row: WcRow,
    selection: WcSelection,
    countColumnWidth: Int?
) -> String {
    var parts: [String] = []
    if selection.lines {
        parts.append(wcCountField(row.counts.lines, width: countColumnWidth))
    }
    if selection.words {
        parts.append(wcCountField(row.counts.words, width: countColumnWidth))
    }
    if selection.characters {
        parts.append(wcCountField(row.counts.characters, width: countColumnWidth))
    }
    if selection.bytes {
        parts.append(wcCountField(row.counts.bytes, width: countColumnWidth))
    }
    if selection.maxLineLength {
        parts.append(wcCountField(row.counts.maxLineLength, width: countColumnWidth))
    }
    if let label = row.label {
        parts.append(label)
    }
    return parts.joined(separator: " ")
}

func wcCountColumnWidth(
    rows: [WcRow],
    operandCount: Int,
    selection: WcSelection
) -> Int? {
    let maximumDigits = wcMaximumCountDigits(rows: rows, selection: selection)
    if operandCount == 0 {
        return selection.selectedCount > 1 ? max(7, maximumDigits) : nil
    }
    if operandCount == 1 {
        if rows.contains(where: { $0.label == "-" }) && selection.selectedCount > 1 {
            return max(7, maximumDigits)
        }
        return selection.selectedCount > 1 ? maximumDigits : nil
    }
    if rows.contains(where: { $0.label == "-" }) {
        return max(7, maximumDigits)
    }
    return max(wcTotalByteColumnWidth(rows: rows), maximumDigits)
}

func wcMaximumCountDigits(rows: [WcRow], selection: WcSelection) -> Int {
    rows.flatMap { row in
        var counts: [Int64] = []
        if selection.lines {
            counts.append(row.counts.lines)
        }
        if selection.words {
            counts.append(row.counts.words)
        }
        if selection.bytes {
            counts.append(row.counts.bytes)
        }
        if selection.characters {
            counts.append(row.counts.characters)
        }
        if selection.maxLineLength {
            counts.append(row.counts.maxLineLength)
        }
        return counts
    }
    .map { String($0).count }
    .max() ?? 1
}

func wcTotalByteColumnWidth(rows: [WcRow]) -> Int {
    let totalBytes = rows
        .filter { $0.label != "total" }
        .reduce(into: Int64(0)) { total, row in
            total += row.counts.bytes
        }
    return String(totalBytes).count
}

func wcCountField(_ value: Int64, width: Int?) -> String {
    let rendered = String(value)
    guard let width, rendered.count < width else {
        return rendered
    }
    return String(repeating: " ", count: width - rendered.count) + rendered
}

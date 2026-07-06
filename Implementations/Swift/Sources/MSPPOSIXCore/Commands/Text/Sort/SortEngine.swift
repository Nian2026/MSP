import Foundation

struct SortRecord {
    var data: Data
    var originalIndex: Int
}

func checkSorted(_ records: [Data], label: String, options: SortOptions) -> String? {
    guard records.count > 1 else {
        return nil
    }
    for index in 1..<records.count {
        if compareSortRecords(
            records[index - 1],
            records[index],
            options: options,
            useLastResortComparison: !(options.unique || options.stable)
        ) == .orderedDescending {
            return "sort: \(label):\(index + 1): disorder: \(String(decoding: records[index], as: UTF8.self))"
        }
    }
    return nil
}

func sortRecordsEquivalentForUnique(_ lhs: Data, _ rhs: Data, options: SortOptions) -> Bool {
    compareSortRecords(lhs, rhs, options: options, useLastResortComparison: false) == .orderedSame
}

func sortedSortInputs(_ inputs: [MSPPOSIXInput], options: SortOptions) -> [SortRecord] {
    var records = mspPOSIXTextRecords(
        in: inputs.reduce(into: Data()) { data, input in data.append(input.data) },
        delimiter: options.zeroTerminated ? 0 : 0x0A
    ).enumerated().map { offset, data in
        SortRecord(data: data, originalIndex: offset)
    }

    records.sort { lhs, rhs in
        let comparison = compareSortRecords(
            lhs.data,
            rhs.data,
            options: options,
            useLastResortComparison: !(options.unique || options.stable)
        )
        if comparison == .orderedSame {
            return lhs.originalIndex < rhs.originalIndex
        }
        return comparison == .orderedAscending
    }
    return records
}

func mergePresortedSortInputs(_ inputs: [MSPPOSIXInput], options: SortOptions) -> [SortRecord] {
    var streams = inputs.enumerated().map { inputIndex, input in
        SortMergeStream(
            inputIndex: inputIndex,
            records: mspPOSIXTextRecords(
                in: input.data,
                delimiter: options.zeroTerminated ? 0 : 0x0A
            )
        )
    }
    var merged: [SortRecord] = []
    var originalIndex = 0
    while let streamIndex = nextSortMergeStreamIndex(streams, options: options) {
        let data = streams[streamIndex].records[streams[streamIndex].offset]
        merged.append(SortRecord(data: data, originalIndex: originalIndex))
        originalIndex += 1
        streams[streamIndex].offset += 1
    }
    return merged
}

private struct SortMergeStream {
    var inputIndex: Int
    var records: [Data]
    var offset = 0

    var current: Data? {
        offset < records.count ? records[offset] : nil
    }
}

private func nextSortMergeStreamIndex(_ streams: [SortMergeStream], options: SortOptions) -> Int? {
    var selectedIndex: Int?
    for index in streams.indices {
        guard let candidate = streams[index].current else {
            continue
        }
        guard let currentSelectedIndex = selectedIndex,
              let selected = streams[currentSelectedIndex].current else {
            selectedIndex = index
            continue
        }
        let comparison = compareSortRecords(
            candidate,
            selected,
            options: options,
            useLastResortComparison: false
        )
        if comparison == .orderedAscending
            || comparison == .orderedSame && streams[index].inputIndex < streams[currentSelectedIndex].inputIndex {
            selectedIndex = index
        }
    }
    return selectedIndex
}

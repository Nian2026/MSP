import Foundation

extension MSPHeadTailCommand {
    func select(_ data: Data, selection: HeadTailSelection) -> Data {
        switch selection.unit {
        case .bytes:
            return selectBytes(data, selection: selection)
        case .lines:
            return selectRecords(data, selection: selection)
        }
    }

    private func selectBytes(_ data: Data, selection: HeadTailSelection) -> Data {
        switch selection.direction {
        case .head:
            return Data(data.prefix(selection.count))
        case .headAllButLast:
            return Data(data.prefix(max(0, data.count - selection.count)))
        case .tail:
            return Data(data.suffix(selection.count))
        case .tailFromStart:
            let start = max(selection.count - 1, 0)
            return start < data.count ? Data(data.dropFirst(start)) : Data()
        }
    }

    private func selectRecords(_ data: Data, selection: HeadTailSelection) -> Data {
        let ranges = recordRanges(in: data, separator: selection.separator)
        let selected: ArraySlice<Range<Int>>
        switch selection.direction {
        case .head:
            selected = ranges.prefix(selection.count)
        case .headAllButLast:
            selected = ranges.dropLast(min(selection.count, ranges.count))
        case .tail:
            selected = ranges.suffix(selection.count)
        case .tailFromStart:
            let start = max(selection.count - 1, 0)
            selected = start < ranges.count ? ranges[start...] : ArraySlice<Range<Int>>()
        }
        var output = Data()
        for range in selected {
            output.append(data.subdata(in: range))
        }
        return output
    }

    private func recordRanges(in data: Data, separator: UInt8) -> [Range<Int>] {
        guard !data.isEmpty else {
            return []
        }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in data.indices where data[index] == separator {
            let end = index + 1
            ranges.append(start..<end)
            start = end
        }
        if start < data.count {
            ranges.append(start..<data.count)
        }
        return ranges
    }
}

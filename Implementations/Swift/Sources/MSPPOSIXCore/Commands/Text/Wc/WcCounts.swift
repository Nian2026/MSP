import Foundation

struct WcRow {
    var counts: WcCounts
    var label: String?
}

struct WcInputResult {
    var rows: [WcRow]
    var diagnostics: [String]
    var exitCode: Int32
}

struct WcCounts {
    var lines: Int64 = 0
    var words: Int64 = 0
    var bytes: Int64 = 0
    var characters: Int64 = 0
    var maxLineLength: Int64 = 0

    init() {}

    init(data: Data) {
        var counter = WcStreamingCounter()
        counter.append(data)
        counter.finish()
        self = counter.counts
    }

    static func total(of rows: [WcRow]) -> WcCounts {
        rows.reduce(into: WcCounts()) { total, row in
            total.lines += row.counts.lines
            total.words += row.counts.words
            total.bytes += row.counts.bytes
            total.characters += row.counts.characters
            total.maxLineLength = max(total.maxLineLength, row.counts.maxLineLength)
        }
    }
}

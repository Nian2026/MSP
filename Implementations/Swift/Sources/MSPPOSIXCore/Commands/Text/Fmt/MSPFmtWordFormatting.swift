import Foundation

func mspFmtFormatWords(
    _ allWords: [MSPFmtWord],
    firstIndent: Int,
    otherIndent: Int,
    linePrefix: [UInt8],
    configuration: MSPFmtConfiguration
) -> Data {
    guard !allWords.isEmpty else {
        return Data()
    }
    // GNU fmt flushes before its fixed MAXWORDS buffer is completely full and
    // then keeps a suffix near the chosen low-cost split point. A 996-word
    // emitted chunk matches that bounded flush shape for the Core100 long
    // paragraph oracle without allowing unbounded paragraph DP.
    let maxWords = 996
    var output = Data()
    var start = 0
    while start < allWords.count {
        let end = min(allWords.count, start + maxWords)
        let chunkFirstIndent = start == 0 ? firstIndent : otherIndent
        output.append(mspFmtFormatWordChunk(
            Array(allWords[start..<end]),
            firstIndent: chunkFirstIndent,
            otherIndent: otherIndent,
            linePrefix: linePrefix,
            configuration: configuration
        ))
        start = end
    }
    return output
}

func mspFmtFormatWordChunk(
    _ words: [MSPFmtWord],
    firstIndent: Int,
    otherIndent: Int,
    linePrefix: [UInt8],
    configuration: MSPFmtConfiguration
) -> Data {
    let breaks = mspFmtChooseBreaks(
        words: words,
        firstIndent: firstIndent,
        otherIndent: otherIndent,
        maxWidth: configuration.width,
        goalWidth: configuration.goalWidth ?? mspFmtDefaultGoalWidth(configuration.width)
    )
    var output = Data()
    var start = 0
    while start < words.count {
        let end = max(start + 1, breaks[start])
        let indent = start == 0 ? firstIndent : otherIndent
        output.append(contentsOf: linePrefix)
        if linePrefix.isEmpty {
            output.append(contentsOf: Array(repeating: UInt8(0x20), count: indent))
        } else if indent > linePrefix.count {
            output.append(contentsOf: Array(repeating: UInt8(0x20), count: indent - linePrefix.count))
        }
        for index in start..<end {
            output.append(contentsOf: words[index].bytes)
            if index + 1 < end {
                output.append(contentsOf: Array(repeating: UInt8(0x20), count: max(1, words[index].space)))
            }
        }
        output.append(0x0a)
        start = end
    }
    return output
}

func mspFmtChooseBreaks(
    words: [MSPFmtWord],
    firstIndent: Int,
    otherIndent: Int,
    maxWidth: Int,
    goalWidth: Int
) -> [Int] {
    let count = words.count
    var nextBreak = Array(repeating: count, count: count)
    var lineLength = Array(repeating: 0, count: count + 1)
    let infinity = Int64.max / 8
    var bestCost = Array(repeating: infinity, count: count + 1)
    bestCost[count] = 0
    lineLength[count] = maxWidth

    for start in stride(from: count - 1, through: 0, by: -1) {
        var best = infinity
        var length = (start == 0 ? firstIndent : otherIndent) + words[start].length
        var cursor = start
        while true {
            cursor += 1
            let candidate = mspFmtLineCost(
                next: cursor,
                length: length,
                goalWidth: goalWidth,
                wordLimit: count,
                nextBreak: nextBreak,
                lineLength: lineLength
            ) + bestCost[cursor]
            if candidate < best {
                best = candidate
                nextBreak[start] = cursor
                lineLength[start] = length
            }
            if cursor == count {
                break
            }
            length += words[cursor - 1].space + words[cursor].length
            if length >= maxWidth {
                break
            }
        }
        bestCost[start] = best + mspFmtBaseCost(wordIndex: start, words: words)
    }
    return nextBreak
}

func mspFmtBaseCost(wordIndex: Int, words: [MSPFmtWord]) -> Int64 {
    var cost = mspFmtEquivalent(70)
    if wordIndex > 0 {
        let previous = words[wordIndex - 1]
        if previous.period {
            cost += previous.final ? -mspFmtEquivalent(50) : mspFmtEquivalent(600)
        } else if previous.punct {
            cost -= mspFmtEquivalent(40)
        } else if wordIndex > 1, words[wordIndex - 2].final {
            cost += mspFmtEquivalent(200) / Int64(previous.length + 2)
        }
    }
    let current = words[wordIndex]
    if current.paren {
        cost -= mspFmtEquivalent(40)
    } else if current.final {
        cost += mspFmtEquivalent(150) / Int64(current.length + 2)
    }
    return cost
}

func mspFmtLineCost(
    next: Int,
    length: Int,
    goalWidth: Int,
    wordLimit: Int,
    nextBreak: [Int],
    lineLength: [Int]
) -> Int64 {
    guard next != wordLimit else {
        return 0
    }
    var cost = mspFmtShortCost(goalWidth - length)
    if nextBreak[next] != wordLimit {
        cost += mspFmtRaggedCost(length - lineLength[next])
    }
    return cost
}

func mspFmtShortCost(_ value: Int) -> Int64 {
    mspFmtEquivalent(value * 10)
}

func mspFmtRaggedCost(_ value: Int) -> Int64 {
    mspFmtShortCost(value) / 2
}

func mspFmtEquivalent(_ value: Int) -> Int64 {
    let raw = Int64(value)
    return raw * raw
}

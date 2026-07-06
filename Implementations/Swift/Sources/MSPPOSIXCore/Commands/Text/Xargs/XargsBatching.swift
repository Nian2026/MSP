import Foundation
import MSPCore

func mspPOSIXXargsRenderedLength(_ words: [String]) -> Int {
    guard !words.isEmpty else {
        return 0
    }
    return words.reduce(0) { total, word in
        total + mspPOSIXShellQuotedLength(word)
    } + max(0, words.count - 1)
}

func mspPOSIXXargsRenderedAdditionLength(
    _ words: [String],
    afterWordCount existingWordCount: Int
) -> Int {
    guard !words.isEmpty else {
        return 0
    }
    let separatorCount = max(0, words.count - 1) + (existingWordCount > 0 ? 1 : 0)
    return words.reduce(0) { total, word in
        total + mspPOSIXShellQuotedLength(word)
    } + separatorCount
}

func mspPOSIXXargsBatches(
    commandWords: [String],
    values: [String],
    maxArgs: Int?,
    maxCharacters: Int
) throws -> [[String]] {
    var batches: [[String]] = []
    var current = commandWords

    guard mspPOSIXXargsRenderedLength(commandWords) <= maxCharacters else {
        throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
    }

    for value in values {
        let candidate = current + [value]
        let currentValueCount = current.count - commandWords.count
        if currentValueCount > 0,
           (maxArgs.map({ currentValueCount >= $0 }) ?? false
                || mspPOSIXXargsRenderedLength(candidate) > maxCharacters) {
            batches.append(current)
            current = commandWords
        }

        let next = current + [value]
        guard mspPOSIXXargsRenderedLength(next) <= maxCharacters else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
        }
        current = next
    }

    if current.count > commandWords.count {
        batches.append(current)
    }
    return batches
}
func mspPOSIXXargsLineBatches(
    commandWords: [String],
    lines: [[String]],
    maxLines: Int,
    maxArgs: Int?,
    maxCharacters: Int
) throws -> [[String]] {
    var batches: [[String]] = []
    var current = commandWords
    var currentLines = 0
    var currentValues = 0

    guard mspPOSIXXargsRenderedLength(commandWords) <= maxCharacters else {
        throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
    }

    for lineWords in lines where !lineWords.isEmpty {
        let wouldExceedLines = currentLines > 0 && currentLines >= maxLines
        let wouldExceedArgs = maxArgs.map { currentValues > 0 && currentValues + lineWords.count > $0 } ?? false
        let candidate = current + lineWords
        if currentValues > 0, wouldExceedLines || wouldExceedArgs || mspPOSIXXargsRenderedLength(candidate) > maxCharacters {
            batches.append(current)
            current = commandWords
            currentLines = 0
            currentValues = 0
        }

        let next = current + lineWords
        guard mspPOSIXXargsRenderedLength(next) <= maxCharacters else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "xargs: command line too long\n"))
        }
        current = next
        currentLines += 1
        currentValues += lineWords.count
    }

    if currentValues > 0 {
        batches.append(current)
    }
    return batches
}

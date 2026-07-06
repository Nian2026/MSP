import Foundation
import MSPCore

func grepStreamStandardInput(
    options: GrepOptions,
    compiled: [NSRegularExpression],
    standardInput: any MSPCommandInputStream,
    standardOutput: any MSPCommandOutputStream
) async throws -> MSPCommandResult {
    if options.maxCount == 0 {
        await standardInput.closeRead()
        return MSPCommandResult(exitCode: 1)
    }

    var buffer = Data()
    var lineNumber = 0
    var matchedCount = 0
    var anyMatched = false

    func processLine(_ lineData: Data) async throws -> Bool {
        guard options.maxCount.map({ matchedCount < $0 }) ?? true else {
            return false
        }
        lineNumber += 1
        let line = String(decoding: lineData, as: UTF8.self)
        let fragments = grepFragments(line: line, options: options, compiled: compiled)
        let matched = options.invertMatch ? fragments.isEmpty : !fragments.isEmpty
        guard matched else {
            return true
        }
        matchedCount += 1
        anyMatched = true

        if options.quiet {
            return false
        }
        if options.filesWithMatches {
            try await standardOutput.write(Data("(standard input)\n".utf8))
            return false
        }
        let prefix = grepPrefix(
            sourcePath: nil,
            alwaysPrefixPath: false,
            nullFileName: options.nullFileName,
            lineNumber: options.showLineNumbers ? lineNumber : nil,
            byteOffset: nil,
            initialTab: options.initialTab,
            colorAlways: options.colorAlways
        )
        if options.onlyMatching, !options.invertMatch {
            for fragment in fragments where !fragment.isEmpty {
                try await standardOutput.write(Data((prefix + grepColorMatch(fragment, options: options) + "\n").utf8))
            }
        } else {
            try await standardOutput.write(Data((prefix + grepColorLine(line, fragments: fragments, options: options) + "\n").utf8))
        }
        return options.maxCount.map { matchedCount < $0 } ?? true
    }

    while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
        buffer.append(chunk)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard try await processLine(Data(lineData)) else {
                await standardInput.closeRead()
                return MSPCommandResult(exitCode: anyMatched ? 0 : 1)
            }
        }
    }
    if !buffer.isEmpty {
        _ = try await processLine(buffer)
    }
    return MSPCommandResult(exitCode: anyMatched ? 0 : 1)
}

import Foundation
import MSPCore

func searchRgFile(
    _ candidate: RgFileCandidate,
    fileSystem: any MSPWorkspaceFileSystem,
    query: RgQuery,
    matcher: RgMatcher,
    prefixPath: Bool,
    output: any RgOutputWriter,
    state: RgRunState
) async throws {
    let data: Data
    do {
        data = try fileSystem.readFile(candidate.info.virtualPath, from: "/")
    } catch {
        state.hadDiagnostics = true
        if !query.noMessages {
            try await output.appendDiagnostic(rgFileSystemDiagnostic(path: candidate.displayPath, error: error))
        }
        return
    }
    try await searchRgData(
        data,
        displayPath: candidate.displayPath,
        query: query,
        matcher: matcher,
        prefixPath: prefixPath,
        reportBinaryMatches: candidate.reportBinaryMatches,
        output: output,
        state: state
    )
}

func searchRgStandardInput(
    _ data: Data,
    query: RgQuery,
    matcher: RgMatcher,
    output: any RgOutputWriter,
    state: RgRunState
) async throws {
    try await searchRgData(
        data,
        displayPath: "<stdin>",
        query: query,
        matcher: matcher,
        prefixPath: query.forceWithFilename,
        reportBinaryMatches: true,
        output: output,
        state: state
    )
}

private func searchRgData(
    _ data: Data,
    displayPath: String,
    query: RgQuery,
    matcher: RgMatcher,
    prefixPath: Bool,
    reportBinaryMatches: Bool,
    output: any RgOutputWriter,
    state: RgRunState
) async throws {
    state.currentFileMatchCount = 0
    let binaryOffset = data.firstIndex(of: 0).map {
        data.distance(from: data.startIndex, to: $0)
    }
    if binaryOffset != nil, !reportBinaryMatches {
        return
    }
    let text = String(decoding: data, as: UTF8.self)
    let lines = mspPOSIXRgLines(text)
    var fileMatched = false
    for (index, line) in lines.enumerated() {
        guard matcher.matches(line) else {
            if !query.invertMatch {
                continue
            }
            try await recordRgMatch(
                line: line,
                lineIndex: index,
                displayPath: displayPath,
                query: query,
                prefixPath: prefixPath,
                suppressLineOutput: binaryOffset != nil,
                output: output,
                state: state,
                fileMatched: &fileMatched
            )
            continue
        }
        if query.invertMatch {
            continue
        }
        try await recordRgMatch(
            line: line,
            lineIndex: index,
            displayPath: displayPath,
            query: query,
            prefixPath: prefixPath,
            suppressLineOutput: binaryOffset != nil,
            output: output,
            state: state,
            fileMatched: &fileMatched
        )
    }
    if query.count {
        if state.currentFileMatchCount > 0 {
            let countLine = rgCountLine(
                count: state.currentFileMatchCount,
                displayPath: displayPath,
                prefixPath: prefixPath,
                query: query
            )
            try await output.appendStdoutLine(countLine)
        }
        state.currentFileMatchCount = 0
    }
    if query.filesWithMatches, fileMatched {
        try await output.appendStdoutLine(displayPath)
    }
    if let binaryOffset,
       fileMatched,
       !query.quiet,
       !query.count,
       !query.filesWithMatches {
        let pathPrefix = prefixPath && !query.forceWithoutFilename
            ? displayPath + ": "
            : ""
        try await output.appendStdoutLine(
            "\(pathPrefix)binary file matches (found \"\\0\" byte around offset \(binaryOffset))"
        )
    }
}

private func recordRgMatch(
    line: String,
    lineIndex: Int,
    displayPath: String,
    query: RgQuery,
    prefixPath: Bool,
    suppressLineOutput: Bool,
    output: any RgOutputWriter,
    state: RgRunState,
    fileMatched: inout Bool
) async throws {
    state.anyMatched = true
    fileMatched = true
    state.currentFileMatchCount += 1
    guard !query.quiet, !query.count, !suppressLineOutput else {
        return
    }
    if query.filesWithMatches {
        return
    }
    var row = ""
    if prefixPath && !query.forceWithoutFilename {
        row += displayPath + ":"
    }
    if query.lineNumber {
        row += "\(lineIndex + 1):"
    }
    row += line
    try await output.appendStdoutLine(row)
}

private func rgCountLine(count: Int, displayPath: String, prefixPath: Bool, query: RgQuery) -> String {
    if prefixPath && !query.forceWithoutFilename {
        return "\(displayPath):\(count)"
    }
    return "\(count)"
}

private func mspPOSIXRgLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: .newlines)
    if text.hasSuffix("\n") || text.hasSuffix("\r") {
        lines.removeLast()
    }
    return lines
}

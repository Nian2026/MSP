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
    let text = String(decoding: data, as: UTF8.self)
    let lines = mspPOSIXRgLines(text)
    var fileMatched = false
    state.currentFileMatchCount = 0
    for (index, line) in lines.enumerated() {
        guard matcher.matches(line) else {
            if !query.invertMatch {
                continue
            }
            try await recordRgMatch(
                line: line,
                lineIndex: index,
                candidate: candidate,
                query: query,
                prefixPath: prefixPath,
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
            candidate: candidate,
            query: query,
            prefixPath: prefixPath,
            output: output,
            state: state,
            fileMatched: &fileMatched
        )
    }
    if query.count {
        let countLine = rgCountLine(
            count: state.currentFileMatchCount,
            candidate: candidate,
            prefixPath: prefixPath,
            query: query
        )
        try await output.appendStdoutLine(countLine)
        state.currentFileMatchCount = 0
    }
    if query.filesWithMatches, fileMatched {
        try await output.appendStdoutLine(candidate.displayPath)
    }
}

private func recordRgMatch(
    line: String,
    lineIndex: Int,
    candidate: RgFileCandidate,
    query: RgQuery,
    prefixPath: Bool,
    output: any RgOutputWriter,
    state: RgRunState,
    fileMatched: inout Bool
) async throws {
    state.anyMatched = true
    fileMatched = true
    state.currentFileMatchCount += 1
    guard !query.quiet, !query.count else {
        return
    }
    if query.filesWithMatches {
        return
    }
    var row = ""
    if prefixPath && !query.forceWithoutFilename {
        row += candidate.displayPath + ":"
    }
    if query.lineNumber {
        row += "\(lineIndex + 1):"
    }
    row += line
    try await output.appendStdoutLine(row)
}

private func rgCountLine(count: Int, candidate: RgFileCandidate, prefixPath: Bool, query: RgQuery) -> String {
    if prefixPath && !query.forceWithoutFilename {
        return "\(candidate.displayPath):\(count)"
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

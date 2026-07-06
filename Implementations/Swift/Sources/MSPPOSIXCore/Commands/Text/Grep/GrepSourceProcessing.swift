import Foundation

final class GrepRunState {
    var rows: [String] = []
    var diagnostics: [String] = []
    var anyMatched = false
    var errorSeen = false
    var stopAll = false
    var suppressMessages = false
}

struct GrepSource {
    var path: String?
    var data: Data
}

func grepProcessSource(
    _ source: GrepSource,
    options: GrepOptions,
    compiled: [NSRegularExpression],
    alwaysPrefixPath: Bool,
    state: GrepRunState
) {
    let displayPath = (source.path == nil || source.path == "standard input")
        ? (options.label ?? source.path)
        : source.path
    if source.data.contains(0), options.binaryMode == .withoutMatch {
        return
    }
    let lines = options.nullData
        ? String(decoding: source.data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        : mspPOSIXLines(String(decoding: source.data, as: UTF8.self))
    let byteOffsets = options.byteOffset ? grepByteOffsets(lines: lines, nullData: options.nullData) : []
    var matchedCount = 0
    var selectedLineIndexes: Set<Int> = []
    var contextLineIndexes: Set<Int> = []
    var fragmentsByLine: [Int: [String]] = [:]
    let binaryOutputSuppressed = source.data.contains(0)
        && options.binaryMode == .binary
        && !options.nullData
        && !options.countOnly
        && !options.filesWithMatches
        && !options.filesWithoutMatches
        && !options.quiet

    for (index, line) in lines.enumerated() {
        guard options.maxCount.map({ matchedCount < $0 }) ?? true else {
            break
        }
        let fragments = grepFragments(line: line, options: options, compiled: compiled)
        let matched = options.invertMatch ? fragments.isEmpty : !fragments.isEmpty
        guard matched else { continue }
        matchedCount += 1
        if binaryOutputSuppressed {
            state.diagnostics.append("grep: \(displayPath ?? "(standard input)"): binary file matches")
            state.anyMatched = true
            return
        }
        selectedLineIndexes.insert(index)
        fragmentsByLine[index] = fragments

        if options.hasContext, !options.onlyMatching {
            if index > 0, options.beforeContext > 0 {
                for contextIndex in max(0, index - options.beforeContext)..<index
                    where !selectedLineIndexes.contains(contextIndex) {
                    contextLineIndexes.insert(contextIndex)
                }
            }
            if options.afterContext > 0, index + 1 < lines.count {
                for contextIndex in (index + 1)...min(lines.count - 1, index + options.afterContext)
                    where !selectedLineIndexes.contains(contextIndex) {
                    contextLineIndexes.insert(contextIndex)
                }
            }
        }

        if options.quiet {
            state.anyMatched = true
            state.stopAll = true
            return
        }
        if options.filesWithMatches {
            state.rows.append(displayPath ?? "(standard input)")
            state.anyMatched = true
            return
        }
        if options.countOnly {
            continue
        }

        let lineNumber = options.showLineNumbers ? index + 1 : nil
        let byteOffset = options.byteOffset && index < byteOffsets.count ? byteOffsets[index] : nil
        if options.onlyMatching, !options.invertMatch {
            for fragment in fragmentsByLine[index] ?? [] where !fragment.isEmpty {
                state.rows.append(grepPrefix(
                    sourcePath: displayPath,
                    alwaysPrefixPath: alwaysPrefixPath,
                    nullFileName: options.nullFileName,
                    lineNumber: lineNumber,
                    byteOffset: byteOffset,
                    initialTab: options.initialTab,
                    selected: true,
                    colorAlways: options.colorAlways
                ) + grepColorMatch(fragment, options: options))
            }
        } else if !options.hasContext {
            state.rows.append(grepPrefix(
                sourcePath: displayPath,
                alwaysPrefixPath: alwaysPrefixPath,
                nullFileName: options.nullFileName,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                initialTab: options.initialTab,
                selected: true,
                colorAlways: options.colorAlways
            ) + grepColorLine(line, fragments: fragmentsByLine[index] ?? [], options: options))
        }
    }

    if options.hasContext, !options.onlyMatching, !options.countOnly, !options.filesWithMatches, !options.filesWithoutMatches {
        var lastPrinted: Int?
        let printableLineIndexes = selectedLineIndexes.union(contextLineIndexes).sorted()
        for index in printableLineIndexes {
            if let lastPrinted, index > lastPrinted + 1, let groupSeparator = options.groupSeparator {
                state.rows.append(groupSeparator)
            }
            let selected = selectedLineIndexes.contains(index)
            let lineNumber = options.showLineNumbers ? index + 1 : nil
            let byteOffset = options.byteOffset && index < byteOffsets.count ? byteOffsets[index] : nil
            state.rows.append(grepPrefix(
                sourcePath: displayPath,
                alwaysPrefixPath: alwaysPrefixPath,
                nullFileName: options.nullFileName,
                lineNumber: lineNumber,
                byteOffset: byteOffset,
                initialTab: options.initialTab,
                selected: selected,
                colorAlways: options.colorAlways
            ) + (selected
                ? grepColorLine(lines[index], fragments: fragmentsByLine[index] ?? [], options: options)
                : lines[index]))
            lastPrinted = index
        }
    }

    if options.filesWithoutMatches {
        if matchedCount == 0, let path = displayPath {
            state.rows.append(path)
            state.anyMatched = true
        }
        return
    }
    if matchedCount > 0 {
        state.anyMatched = true
    }
    if options.countOnly {
        state.rows.append(grepPrefix(
            sourcePath: displayPath,
            alwaysPrefixPath: alwaysPrefixPath,
            nullFileName: options.nullFileName,
            lineNumber: nil,
            byteOffset: nil,
            initialTab: false,
            selected: true,
            colorAlways: options.colorAlways
        ) + String(matchedCount))
    }
}

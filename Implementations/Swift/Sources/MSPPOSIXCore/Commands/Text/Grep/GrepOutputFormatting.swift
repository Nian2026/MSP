import Foundation

func grepPrefix(
    sourcePath: String?,
    alwaysPrefixPath: Bool,
    nullFileName: Bool,
    lineNumber: Int?,
    byteOffset: Int?,
    initialTab: Bool,
    selected: Bool = true,
    colorAlways: Bool = false
) -> String {
    var prefix = ""
    let separator = selected ? ":" : "-"
    if let sourcePath, alwaysPrefixPath {
        prefix += grepColorField(sourcePath, color: "35", enabled: colorAlways)
            + (nullFileName ? "\0" : grepColorField(separator, color: "36", enabled: colorAlways))
    }
    if let byteOffset {
        prefix += grepColorField("\(byteOffset)", color: "32", enabled: colorAlways)
            + grepColorField(separator, color: "36", enabled: colorAlways)
    }
    if let lineNumber {
        prefix += grepColorField("\(lineNumber)", color: "32", enabled: colorAlways)
            + grepColorField(separator, color: "36", enabled: colorAlways)
    }
    if initialTab, !prefix.isEmpty {
        prefix += "\t"
    }
    return prefix
}

func grepColorLine(_ line: String, fragments: [String], options: GrepOptions) -> String {
    guard options.colorAlways, !fragments.isEmpty else {
        return line
    }
    var output = ""
    var searchStart = line.startIndex
    for fragment in fragments where !fragment.isEmpty {
        guard let range = line.range(of: fragment, range: searchStart..<line.endIndex) else {
            continue
        }
        output += line[searchStart..<range.lowerBound]
        output += grepColorMatch(String(line[range]), options: options)
        searchStart = range.upperBound
    }
    output += line[searchStart..<line.endIndex]
    return output
}

func grepColorMatch(_ value: String, options: GrepOptions) -> String {
    grepColorField(value, color: "01;31", enabled: options.colorAlways)
}

func grepColorField(_ value: String, color: String, enabled: Bool) -> String {
    guard enabled, !color.isEmpty else {
        return value
    }
    return "\u{1B}[\(color)m\u{1B}[K\(value)\u{1B}[m\u{1B}[K"
}

func grepByteOffsets(lines: [String], nullData: Bool) -> [Int] {
    var offsets: [Int] = []
    var offset = 0
    for line in lines {
        offsets.append(offset)
        offset += line.utf8.count + 1
    }
    return offsets
}

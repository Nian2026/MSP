import Foundation
import MSPShellLanguage

public func mspShellFieldSplit(_ text: String, ifs: String = " \t\n") -> [String] {
    guard !text.isEmpty else {
        return []
    }
    guard !ifs.isEmpty else {
        return [text]
    }

    let ifsCharacters = Set(ifs)
    let ifsWhitespace = Set(" \t\n").intersection(ifsCharacters)
    let ifsHard = ifsCharacters.subtracting(Set(" \t\n"))

    if ifsHard.isEmpty {
        return text.split(whereSeparator: { ifsWhitespace.contains($0) }).map(String.init)
    }

    var fields: [String] = []
    var current = ""
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        guard ifsCharacters.contains(character) else {
            current.append(character)
            index = text.index(after: index)
            continue
        }

        var hardCount = 0
        while index < text.endIndex, ifsCharacters.contains(text[index]) {
            if ifsHard.contains(text[index]) {
                hardCount += 1
            }
            index = text.index(after: index)
        }

        if hardCount == 0 {
            if !current.isEmpty {
                fields.append(current)
                current = ""
            }
        } else {
            fields.append(current)
            current = ""
            if hardCount > 1 {
                fields.append(contentsOf: Array(repeating: "", count: hardCount - 1))
            }
        }
    }

    if !current.isEmpty {
        fields.append(current)
    }
    return fields
}

public func mspShellReadFields(_ line: String, ifs: String = " \t\n", maxFields: Int) -> [String] {
    guard maxFields > 1 else {
        return [line]
    }
    guard !ifs.isEmpty else {
        return [line] + Array(repeating: "", count: max(0, maxFields - 1))
    }

    var ifsWhitespace: Set<Character> = []
    var ifsNonWhitespace: Set<Character> = []
    for character in ifs {
        if mspShellIsIFSWhitespace(character) {
            ifsWhitespace.insert(character)
        } else {
            ifsNonWhitespace.insert(character)
        }
    }

    var fields: [String] = []
    var index = line.startIndex

    func isDelimiter(_ character: Character) -> Bool {
        ifsWhitespace.contains(character) || ifsNonWhitespace.contains(character)
    }

    func skipIFSWhitespace() -> String.Index {
        var cursor = index
        while cursor < line.endIndex, ifsWhitespace.contains(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    for _ in 0..<(maxFields - 1) {
        index = skipIFSWhitespace()
        if index < line.endIndex, ifsNonWhitespace.contains(line[index]) {
            fields.append("")
            index = line.index(after: index)
            continue
        }
        guard index < line.endIndex else {
            fields.append("")
            continue
        }
        let fieldStart = index
        while index < line.endIndex, !isDelimiter(line[index]) {
            index = line.index(after: index)
        }
        fields.append(String(line[fieldStart..<index]))
        if index < line.endIndex, ifsWhitespace.contains(line[index]) {
            repeat {
                index = line.index(after: index)
            } while index < line.endIndex && ifsWhitespace.contains(line[index])
        } else if index < line.endIndex {
            index = line.index(after: index)
        }
    }

    index = skipIFSWhitespace()
    fields.append(mspShellTrimTrailingIFSWhitespace(String(line[index...]), ifsWhitespace: ifsWhitespace))
    return fields
}

public func mspShellReadAllFields(_ line: String, ifs: String = " \t\n") -> [String] {
    guard !ifs.isEmpty else {
        return line.isEmpty ? [] : [line]
    }

    var ifsWhitespace: Set<Character> = []
    var ifsNonWhitespace: Set<Character> = []
    for character in ifs {
        if mspShellIsIFSWhitespace(character) {
            ifsWhitespace.insert(character)
        } else {
            ifsNonWhitespace.insert(character)
        }
    }

    var fields: [String] = []
    var index = line.startIndex

    func isDelimiter(_ character: Character) -> Bool {
        ifsWhitespace.contains(character) || ifsNonWhitespace.contains(character)
    }

    func skipIFSWhitespace() {
        while index < line.endIndex, ifsWhitespace.contains(line[index]) {
            index = line.index(after: index)
        }
    }

    while true {
        skipIFSWhitespace()
        guard index < line.endIndex else {
            break
        }
        if ifsNonWhitespace.contains(line[index]) {
            fields.append("")
            index = line.index(after: index)
            continue
        }

        let fieldStart = index
        while index < line.endIndex, !isDelimiter(line[index]) {
            index = line.index(after: index)
        }
        fields.append(String(line[fieldStart..<index]))
        if index < line.endIndex, ifsWhitespace.contains(line[index]) {
            repeat {
                index = line.index(after: index)
            } while index < line.endIndex && ifsWhitespace.contains(line[index])
        } else if index < line.endIndex {
            index = line.index(after: index)
        }
    }

    return fields
}

private func mspShellIsIFSWhitespace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\n"
}

private func mspShellTrimTrailingIFSWhitespace(
    _ value: String,
    ifsWhitespace: Set<Character>
) -> String {
    var end = value.endIndex
    while end > value.startIndex {
        let previous = value.index(before: end)
        guard ifsWhitespace.contains(value[previous]) else {
            break
        }
        end = previous
    }
    return String(value[..<end])
}

import Foundation
import MSPShellLanguage

func mspSubstringValue(_ value: String, offset: Int, length: Int?) throws -> String {
    if let length, length < 0 {
        throw MSPShellExpansionError.arithmetic("substring expression < 0")
    }
    let characters = Array(value)
    let count = characters.count
    let start = offset < 0 ? max(0, count + offset) : min(offset, count)
    let end = min(count, start + (length ?? (count - start)))
    guard end > start else {
        return ""
    }
    return String(characters[start..<end])
}

func mspRemoveGlobPrefix(_ pattern: String, from value: String, longest: Bool) throws -> String {
    let indices = Array(value.indices) + [value.endIndex]
    let ordered = longest ? indices.reversed() : indices
    for index in ordered {
        let prefix = String(value[..<index])
        if mspGlobPattern(pattern, matches: prefix, pathSeparatorsAreSpecial: false) {
            return String(value[index...])
        }
    }
    return value
}

func mspRemoveGlobSuffix(_ pattern: String, from value: String, longest: Bool) throws -> String {
    let indices = Array(value.indices) + [value.endIndex]
    let ordered = longest ? indices : indices.reversed()
    for index in ordered {
        let suffix = String(value[index...])
        if mspGlobPattern(pattern, matches: suffix, pathSeparatorsAreSpecial: false) {
            return String(value[..<index])
        }
    }
    return value
}

public func mspShellGlobPattern(
    _ pattern: String,
    matches value: String,
    pathSeparatorsAreSpecial: Bool = true
) -> Bool {
    mspGlobPattern(pattern, matches: value, pathSeparatorsAreSpecial: pathSeparatorsAreSpecial)
}

private func mspGlobPattern(
    _ pattern: String,
    matches value: String,
    pathSeparatorsAreSpecial: Bool = true
) -> Bool {
    MSPGlobPattern(parts: [.init(text: pattern, globActive: true)])
        .matches(value, pathSeparatorsAreSpecial: pathSeparatorsAreSpecial)
}

func mspShellDecodeBackslashEscapes(_ value: String) -> String {
    var output = ""
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        guard character == "\\" else {
            output.append(character)
            index = value.index(after: index)
            continue
        }
        let next = value.index(after: index)
        guard next < value.endIndex else {
            output.append(character)
            index = next
            continue
        }
        switch value[next] {
        case "n":
            output.append("\n")
        case "t":
            output.append("\t")
        case "r":
            output.append("\r")
        case "\\":
            output.append("\\")
        case "0":
            output.append("\0")
        default:
            output.append(value[next])
        }
        index = value.index(after: next)
    }
    return output
}

struct MSPGlobPattern {
    private struct CharacterPart {
        var value: Character
        var globActive: Bool
    }

    var parts: [MSPShellExpandedField.Part]

    init(parts: [MSPShellExpandedField.Part]) {
        self.parts = parts
    }

    private var characters: [CharacterPart] {
        parts.flatMap { part in
            part.text.map { CharacterPart(value: $0, globActive: part.globActive) }
        }
    }

    func matches(
        _ path: String,
        pathSeparatorsAreSpecial: Bool = true,
        caseInsensitive: Bool = false,
        extendedGlob: Bool = false,
        globStar: Bool = false
    ) -> Bool {
        let pattern = "^" + regexBody(
            pathSeparatorsAreSpecial: pathSeparatorsAreSpecial,
            extendedGlob: extendedGlob,
            globStar: globStar
        ) + "$"
        var options: String.CompareOptions = [.regularExpression]
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return path.range(of: pattern, options: options) != nil
    }

    func explicitlyMatchesHiddenComponents(in path: String) -> Bool {
        let patternComponents = componentParts()
        let pathComponents = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for (index, component) in pathComponents.enumerated() where component.hasPrefix(".") {
            guard index < patternComponents.count,
                  componentExplicitlyStartsWithDot(patternComponents[index]) else {
                return false
            }
        }
        return true
    }

    private func componentParts() -> [[MSPShellExpandedField.Part]] {
        var components: [[MSPShellExpandedField.Part]] = [[]]
        for part in parts {
            var remainder = part.text[...]
            while let slashIndex = remainder.firstIndex(of: "/") {
                let prefix = String(remainder[..<slashIndex])
                if !prefix.isEmpty {
                    components[components.count - 1].append(
                        .init(text: prefix, globActive: part.globActive)
                    )
                }
                components.append([])
                remainder = remainder[remainder.index(after: slashIndex)...]
            }
            if !remainder.isEmpty {
                components[components.count - 1].append(
                    .init(text: String(remainder), globActive: part.globActive)
                )
            }
        }
        return components.filter { !$0.isEmpty }
    }

    private func componentExplicitlyStartsWithDot(_ component: [MSPShellExpandedField.Part]) -> Bool {
        for part in component {
            guard let first = part.text.first else {
                continue
            }
            return first == "."
        }
        return false
    }

    private func regexBody(
        pathSeparatorsAreSpecial: Bool = true,
        extendedGlob: Bool = false,
        globStar: Bool = false
    ) -> String {
        var result = ""
        let characters = characters
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            guard character.globActive else {
                result += NSRegularExpression.escapedPattern(for: String(character.value))
                index = characters.index(after: index)
                continue
            }
            if extendedGlob,
               let group = extendedGlobGroup(
                in: characters,
                startingAt: index,
                pathSeparatorsAreSpecial: pathSeparatorsAreSpecial,
                globStar: globStar
               ) {
                result += group.regex
                index = characters.index(after: group.closeIndex)
                continue
            }
            switch character.value {
            case "*":
                if globStar,
                   pathSeparatorsAreSpecial,
                   characters.index(after: index) < characters.endIndex,
                   characters[characters.index(after: index)].globActive,
                   characters[characters.index(after: index)].value == "*" {
                    let afterSecondStar = characters.index(after: characters.index(after: index))
                    if afterSecondStar < characters.endIndex,
                       characters[afterSecondStar].globActive,
                       characters[afterSecondStar].value == "/" {
                        result += "(?:.*/)?"
                        index = characters.index(after: afterSecondStar)
                        continue
                    }
                    result += ".*"
                    index = afterSecondStar
                    continue
                } else {
                    result += pathSeparatorsAreSpecial ? "[^/]*" : ".*"
                }
            case "?":
                result += pathSeparatorsAreSpecial ? "[^/]" : "."
            case "[":
                if let end = characterClassEnd(in: characters, startingAt: index) {
                    let bodyStart = characters.index(after: index)
                    let body = String(characters[bodyStart..<end].map(\.value))
                    if body.hasPrefix("!") {
                        result += "[^\(body.dropFirst())]"
                    } else if body.hasPrefix("^") {
                        result += "[\\^\(body.dropFirst())]"
                    } else {
                        result += "[\(body)]"
                    }
                    index = characters.index(after: end)
                    continue
                } else {
                    result += "\\["
                }
            default:
                result += NSRegularExpression.escapedPattern(for: String(character.value))
            }
            index = characters.index(after: index)
        }
        return result
    }

    private func characterClassEnd(
        in characters: [CharacterPart],
        startingAt start: [CharacterPart].Index
    ) -> [CharacterPart].Index? {
        var index = characters.index(after: start)
        guard index < characters.endIndex else {
            return nil
        }
        if characters[index].globActive,
           (characters[index].value == "!" || characters[index].value == "^") {
            index = characters.index(after: index)
        }
        while index < characters.endIndex {
            let character = characters[index]
            if character.globActive, character.value == "]" {
                return index
            }
            if character.globActive, character.value == "/" {
                return nil
            }
            if character.globActive, character.value == "\\" {
                let next = characters.index(after: index)
                guard next < characters.endIndex else {
                    return nil
                }
                index = next
            }
            index = characters.index(after: index)
        }
        return nil
    }

    private func extendedGlobGroup(
        in characters: [CharacterPart],
        startingAt operatorIndex: [CharacterPart].Index,
        pathSeparatorsAreSpecial: Bool,
        globStar: Bool
    ) -> (regex: String, closeIndex: [CharacterPart].Index)? {
        let operatorCharacter = characters[operatorIndex]
        guard operatorCharacter.globActive,
              "@!+*?".contains(operatorCharacter.value),
              characters.index(after: operatorIndex) < characters.endIndex else {
            return nil
        }
        let openIndex = characters.index(after: operatorIndex)
        guard characters[openIndex].globActive,
              characters[openIndex].value == "(" else {
            return nil
        }

        var alternatives: [[CharacterPart]] = []
        var current: [CharacterPart] = []
        var depth = 1
        var index = characters.index(after: openIndex)
        while index < characters.endIndex {
            let character = characters[index]
            if character.globActive, character.value == "(" {
                depth += 1
                current.append(character)
            } else if character.globActive, character.value == ")" {
                depth -= 1
                if depth == 0 {
                    alternatives.append(current)
                    let body = alternatives
                        .map { MSPGlobPattern(characters: $0).regexBody(
                            pathSeparatorsAreSpecial: pathSeparatorsAreSpecial,
                            extendedGlob: true,
                            globStar: globStar
                        ) }
                        .joined(separator: "|")
                    let union = body.isEmpty ? "(?!)" : "(?:\(body))"
                    switch operatorCharacter.value {
                    case "@":
                        return (union, index)
                    case "?":
                        return ("(?:\(union))?", index)
                    case "+":
                        return ("(?:\(union))+", index)
                    case "*":
                        return ("(?:\(union))*", index)
                    case "!":
                        let fallback = pathSeparatorsAreSpecial ? "[^/]*" : ".*"
                        let boundary = pathSeparatorsAreSpecial ? "(?:/|$)" : "$"
                        return ("(?!(?:\(body))\(boundary))\(fallback)", index)
                    default:
                        return nil
                    }
                }
                current.append(character)
            } else if character.globActive, character.value == "|", depth == 1 {
                alternatives.append(current)
                current = []
            } else {
                current.append(character)
            }
            index = characters.index(after: index)
        }
        return nil
    }

    private init(characters: [CharacterPart]) {
        self.parts = characters.map {
            MSPShellExpandedField.Part(text: String($0.value), globActive: $0.globActive)
        }
    }
}

func normalizedPath(_ path: String) -> String {
    var components: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            if !components.isEmpty {
                components.removeLast()
            }
        default:
            components.append(String(component))
        }
    }
    return "/" + components.joined(separator: "/")
}

func relativePath(_ path: String, from base: String) -> String {
    let normalizedBase = normalizedPath(base)
    let normalizedTarget = normalizedPath(path)
    if normalizedBase == "/" {
        return String(normalizedTarget.dropFirst())
    }
    if normalizedTarget == normalizedBase {
        return "."
    }
    let prefix = normalizedBase + "/"
    guard normalizedTarget.hasPrefix(prefix) else {
        return normalizedTarget
    }
    return String(normalizedTarget.dropFirst(prefix.count))
}

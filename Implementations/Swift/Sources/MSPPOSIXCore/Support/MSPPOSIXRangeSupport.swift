import Foundation
import MSPCore

struct MSPPOSIXRangeSpec: Sendable, Equatable {
    struct Range: Sendable, Equatable {
        var lower: Int
        var upper: Int
    }

    var ranges: [Range]

    static func parse(_ value: String, command: String, unitName: String = "range") throws -> MSPPOSIXRangeSpec {
        let expressions = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !expressions.isEmpty else {
            throw MSPCommandFailure.usage("\(command): invalid \(unitName)\n")
        }
        let ranges = try expressions.map { expression -> Range in
            guard !expression.isEmpty else {
                throw MSPCommandFailure.usage("\(command): invalid \(unitName) \(expression)\n")
            }
            if let dashIndex = expression.firstIndex(of: "-") {
                let lowerText = String(expression[..<dashIndex])
                let upperText = String(expression[expression.index(after: dashIndex)...])
                guard !lowerText.isEmpty || !upperText.isEmpty else {
                    throw MSPCommandFailure.usage("\(command): invalid \(unitName) \(expression)\n")
                }
                let lower = lowerText.isEmpty ? 1 : Int(lowerText)
                let upper = upperText.isEmpty ? Int.max : Int(upperText)
                guard let lower,
                      let upper,
                      lower >= 1,
                      upper >= lower else {
                    throw MSPCommandFailure.usage("\(command): invalid \(unitName) \(expression)\n")
                }
                return Range(lower: lower, upper: upper)
            }
            guard let index = Int(expression), index >= 1 else {
                throw MSPCommandFailure.usage("\(command): invalid \(unitName) \(expression)\n")
            }
            return Range(lower: index, upper: index)
        }
        return MSPPOSIXRangeSpec(ranges: ranges)
    }

    func selectedOffsets(count: Int, complement: Bool = false) -> [Int] {
        guard count > 0 else { return [] }
        var selected = Array(repeating: false, count: count)
        for range in ranges {
            guard range.lower <= count else { continue }
            let upper = min(range.upper, count)
            guard range.lower <= upper else { continue }
            for oneBasedIndex in range.lower...upper {
                selected[oneBasedIndex - 1] = true
            }
        }
        return selected.indices.filter { selected[$0] != complement }
    }
}

struct MSPPOSIXScalarSetExpression: Sendable, Equatable {
    var scalars: [UnicodeScalar]
    var members: Set<UnicodeScalar>

    static func parse(_ rawValue: String) throws -> MSPPOSIXScalarSetExpression {
        var output: [UnicodeScalar] = []
        let scalars = Array(rawValue.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if consumePOSIXClass(in: scalars, index: &index, output: &output) {
                continue
            }
            if consumePOSIXEquivalence(in: scalars, index: &index, output: &output) {
                continue
            }
            let start = decodedScalar(in: scalars, index: &index)
            if index + 1 < scalars.count,
               scalars[index] == "-",
               scalars[index + 1] != "-" {
                index += 1
                let end = decodedScalar(in: scalars, index: &index)
                if start.value <= end.value {
                    for value in start.value...end.value {
                        if let scalar = UnicodeScalar(value) {
                            output.append(scalar)
                        }
                    }
                } else {
                    output.append(start)
                    output.append("-")
                    output.append(end)
                }
            } else {
                output.append(start)
            }
        }
        return MSPPOSIXScalarSetExpression(scalars: output, members: Set(output))
    }

    func contains(_ scalar: UnicodeScalar, complement: Bool = false) -> Bool {
        let contained = members.contains(scalar)
        return complement ? !contained : contained
    }

    private static func consumePOSIXClass(
        in scalars: [UnicodeScalar],
        index: inout Int,
        output: inout [UnicodeScalar]
    ) -> Bool {
        guard index + 1 < scalars.count,
              scalars[index] == "[",
              scalars[index + 1] == ":" else {
            return false
        }
        var probe = index + 2
        var name = ""
        while probe < scalars.count, scalars[probe] != ":" {
            name.unicodeScalars.append(scalars[probe])
            probe += 1
        }
        guard probe + 1 < scalars.count,
              scalars[probe] == ":",
              scalars[probe + 1] == "]",
              let classScalars = posixClassScalars(named: name) else {
            return false
        }
        output.append(contentsOf: classScalars)
        index = probe + 2
        return true
    }

    private static func consumePOSIXEquivalence(
        in scalars: [UnicodeScalar],
        index: inout Int,
        output: inout [UnicodeScalar]
    ) -> Bool {
        guard index + 3 < scalars.count,
              scalars[index] == "[",
              scalars[index + 1] == "=" else {
            return false
        }
        var probe = index + 2
        var values: [UnicodeScalar] = []
        while probe < scalars.count, scalars[probe] != "=" {
            values.append(scalars[probe])
            probe += 1
        }
        guard probe + 1 < scalars.count,
              scalars[probe] == "=",
              scalars[probe + 1] == "]",
              values.count == 1,
              let value = values.first else {
            return false
        }
        output.append(value)
        index = probe + 2
        return true
    }

    private static func decodedScalar(in scalars: [UnicodeScalar], index: inout Int) -> UnicodeScalar {
        let scalar = scalars[index]
        guard scalar == "\\", index + 1 < scalars.count else {
            index += 1
            return scalar
        }
        let next = scalars[index + 1]
        index += 2
        switch next {
        case "n":
            return "\n"
        case "t":
            return "\t"
        case "r":
            return "\r"
        case "f":
            return "\u{0C}"
        case "v":
            return "\u{0B}"
        case "0":
            return "\0"
        case "\\":
            return "\\"
        default:
            return next
        }
    }

    private static func posixClassScalars(named name: String) -> [UnicodeScalar]? {
        switch name {
        case "alnum":
            return scalarRange("0", "9") + scalarRange("A", "Z") + scalarRange("a", "z")
        case "alpha":
            return scalarRange("A", "Z") + scalarRange("a", "z")
        case "blank":
            return Array(" \t".unicodeScalars)
        case "cntrl":
            return scalarRange(0, 31) + scalarRange(127, 127)
        case "digit":
            return scalarRange("0", "9")
        case "graph":
            return scalarRange(33, 126)
        case "lower":
            return scalarRange("a", "z")
        case "print":
            return scalarRange(32, 126)
        case "punct":
            return Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
        case "space":
            return Array(" \t\n\r\u{0B}\u{0C}".unicodeScalars)
        case "upper":
            return scalarRange("A", "Z")
        case "xdigit":
            return scalarRange("0", "9") + scalarRange("A", "F") + scalarRange("a", "f")
        default:
            return nil
        }
    }

    private static func scalarRange(_ lower: Character, _ upper: Character) -> [UnicodeScalar] {
        guard let lowerValue = String(lower).unicodeScalars.first?.value,
              let upperValue = String(upper).unicodeScalars.first?.value else {
            return []
        }
        return scalarRange(lowerValue, upperValue)
    }

    private static func scalarRange(_ lower: UInt32, _ upper: UInt32) -> [UnicodeScalar] {
        guard lower <= upper else { return [] }
        return (lower...upper).compactMap(UnicodeScalar.init)
    }
}

func mspPOSIXDecodeBackslashEscapes(_ value: String) -> String {
    var output = ""
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        guard character == "\\", value.index(after: index) < value.endIndex else {
            output.append(character)
            index = value.index(after: index)
            continue
        }
        let nextIndex = value.index(after: index)
        let next = value[nextIndex]
        switch next {
        case "n":
            output.append("\n")
        case "t":
            output.append("\t")
        case "r":
            output.append("\r")
        case "0":
            output.append("\0")
        case "\\":
            output.append("\\")
        default:
            output.append(next)
        }
        index = value.index(after: nextIndex)
    }
    return output
}

func mspPOSIXDecodedDelimiterCharacters(_ rawValue: String, defaultValue: String = "\t") -> [Character] {
    let decoded = mspPOSIXDecodeBackslashEscapes(rawValue)
    let effective = decoded.isEmpty ? defaultValue : decoded
    return Array(effective)
}

func mspPOSIXJoinWithCyclingDelimiters(_ parts: [String], delimiters: [Character]) -> String {
    guard let first = parts.first else { return "" }
    let effectiveDelimiters = delimiters.isEmpty ? ["\t"] : delimiters
    var output = first
    for (offset, part) in parts.dropFirst().enumerated() {
        output.append(effectiveDelimiters[offset % effectiveDelimiters.count])
        output += part
    }
    return output
}

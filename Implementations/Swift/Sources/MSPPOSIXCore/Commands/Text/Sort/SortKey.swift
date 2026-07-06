import Foundation
import MSPCore

struct SortKey {
    enum BlankTarget {
        case start
        case end
    }

    var startFieldIndex: Int?
    var startCharacterOffset = 0
    var endFieldIndex: Int?
    var endCharacterCount = 0
    var reverse = false
    var numeric = false
    var generalNumeric = false
    var humanNumeric = false
    var month = false
    var random = false
    var version = false
    var skipsStartBlanks = false
    var skipsEndBlanks = false
    var foldCase = false
    var dictionaryOrder = false
    var ignoreNonprinting = false

    init(_ rawValue: String) throws {
        var index = rawValue.startIndex
        let start = try Self.parseKeyPosition(in: rawValue, index: &index, isStart: true)
        startFieldIndex = start.fieldIndex == 0 && start.characterCount == 0 ? nil : start.fieldIndex
        startCharacterOffset = start.characterCount
        try applyOrdering(in: rawValue, index: &index, blankTarget: .start)

        if index < rawValue.endIndex, rawValue[index] == "," {
            index = rawValue.index(after: index)
            let end = try Self.parseKeyPosition(in: rawValue, index: &index, isStart: false)
            endFieldIndex = end.fieldIndex
            endCharacterCount = end.characterCount
            try applyOrdering(in: rawValue, index: &index, blankTarget: .end)
        } else {
            endFieldIndex = nil
            endCharacterCount = 0
        }

        guard index == rawValue.endIndex else {
            throw MSPCommandFailure.usage("sort: invalid key '\(rawValue)'\n")
        }
    }

    var usesDefaultComparison: Bool {
        !(dictionaryOrder
            || foldCase
            || generalNumeric
            || humanNumeric
            || ignoreNonprinting
            || month
            || numeric
            || random
            || skipsStartBlanks
            || skipsEndBlanks
            || version)
    }

    func effectiveOrdering(options: SortOptions) -> SortEffectiveKeyOrdering {
        if usesDefaultComparison && !reverse {
            return SortEffectiveKeyOrdering(
                reverse: options.reverse,
                numeric: options.numeric,
                generalNumeric: options.generalNumeric,
                humanNumeric: options.humanNumeric,
                month: options.month,
                random: options.random,
                version: options.version,
                skipsStartBlanks: options.ignoreLeadingBlanks,
                skipsEndBlanks: options.ignoreLeadingBlanks,
                foldCase: options.foldCase,
                dictionaryOrder: options.dictionaryOrder,
                ignoreNonprinting: options.ignoreNonprinting
            )
        }
        return SortEffectiveKeyOrdering(
            reverse: reverse,
            numeric: numeric,
            generalNumeric: generalNumeric,
            humanNumeric: humanNumeric,
            month: month,
            random: random,
            version: version,
            skipsStartBlanks: skipsStartBlanks,
            skipsEndBlanks: skipsEndBlanks,
            foldCase: foldCase,
            dictionaryOrder: dictionaryOrder,
            ignoreNonprinting: ignoreNonprinting
        )
    }

    private static func parseKeyPosition(
        in rawValue: String,
        index: inout String.Index,
        isStart: Bool
    ) throws -> (fieldIndex: Int, characterCount: Int) {
        let field = try parsePositiveDecimal(in: rawValue, index: &index)
        var characterCount = 0
        if index < rawValue.endIndex, rawValue[index] == "." {
            index = rawValue.index(after: index)
            let count = try parseDecimal(in: rawValue, index: &index)
            if isStart, count == 0 {
                throw MSPCommandFailure.usage("sort: invalid key '\(rawValue)'\n")
            }
            characterCount = isStart ? count - 1 : count
        }
        return (field - 1, characterCount)
    }

    private static func parsePositiveDecimal(in rawValue: String, index: inout String.Index) throws -> Int {
        let value = try parseDecimal(in: rawValue, index: &index)
        guard value > 0 else {
            throw MSPCommandFailure.usage("sort: invalid key '\(rawValue)'\n")
        }
        return value
    }

    private static func parseDecimal(in rawValue: String, index: inout String.Index) throws -> Int {
        let start = index
        while index < rawValue.endIndex, rawValue[index].isNumber {
            index = rawValue.index(after: index)
        }
        guard start < index, let value = Int(rawValue[start..<index]) else {
            throw MSPCommandFailure.usage("sort: invalid key '\(rawValue)'\n")
        }
        return value
    }

    private mutating func applyOrdering(
        in rawValue: String,
        index: inout String.Index,
        blankTarget: BlankTarget
    ) throws {
        while index < rawValue.endIndex {
            let character = rawValue[index]
            switch character {
            case "b":
                switch blankTarget {
                case .start:
                    skipsStartBlanks = true
                case .end:
                    skipsEndBlanks = true
                }
            case "d":
                dictionaryOrder = true
            case "f":
                foldCase = true
            case "g":
                generalNumeric = true
            case "h":
                humanNumeric = true
            case "i":
                if !dictionaryOrder {
                    ignoreNonprinting = true
                }
            case "M":
                month = true
            case "n":
                numeric = true
            case "R":
                random = true
            case "r":
                reverse = true
            case "V":
                version = true
            case "," where blankTarget == .start:
                return
            default:
                throw MSPCommandFailure.usage("sort: invalid key '\(rawValue)'\n")
            }
            index = rawValue.index(after: index)
        }
    }
}

struct SortEffectiveKeyOrdering {
    var reverse: Bool
    var numeric: Bool
    var generalNumeric: Bool
    var humanNumeric: Bool
    var month: Bool
    var random: Bool
    var version: Bool
    var skipsStartBlanks: Bool
    var skipsEndBlanks: Bool
    var foldCase: Bool
    var dictionaryOrder: Bool
    var ignoreNonprinting: Bool
}

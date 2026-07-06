import Foundation

func compareSortRecords(
    _ lhs: Data,
    _ rhs: Data,
    options: SortOptions,
    useLastResortComparison: Bool
) -> ComparisonResult {
    compareSortRecords(
        String(decoding: lhs, as: UTF8.self),
        String(decoding: rhs, as: UTF8.self),
        options: options,
        useLastResortComparison: useLastResortComparison
    )
}

func compareSortRecords(
    _ lhs: String,
    _ rhs: String,
    options: SortOptions,
    useLastResortComparison: Bool
) -> ComparisonResult {
    if !options.keys.isEmpty {
        for key in options.keys {
            let comparison = compareSortField(
                lhs,
                rhs,
                key: key,
                options: options,
                useLastResortComparison: false
            )
            if comparison != .orderedSame {
                return comparison
            }
        }
        guard useLastResortComparison else {
            return .orderedSame
        }
        let comparison = bytewiseComparison(lhs, rhs)
        return options.reverse ? comparison.reversedForSort : comparison
    }

    let comparison: ComparisonResult
    let lhsKey = options.ignoreLeadingBlanks ? lhs.trimmingLeadingWhitespace() : lhs
    let rhsKey = options.ignoreLeadingBlanks ? rhs.trimmingLeadingWhitespace() : rhs
    if options.month {
        comparison = monthComparison(lhsKey, rhsKey, useFallback: useLastResortComparison)
    } else if options.random {
        comparison = randomSortComparison(lhsKey, rhsKey, seed: options.randomSeed)
    } else if options.version {
        comparison = versionComparison(lhsKey, rhsKey, useFallback: useLastResortComparison)
    } else if options.generalNumeric {
        comparison = numericComparison(
            leadingGeneralNumber(lhsKey),
            leadingGeneralNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else if options.humanNumeric {
        comparison = numericComparison(
            leadingHumanNumber(lhsKey),
            leadingHumanNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else if options.numeric {
        comparison = numericComparison(
            leadingNumber(lhsKey),
            leadingNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else {
        comparison = compareStrings(
            lhsKey,
            rhsKey,
            foldCase: options.foldCase,
            dictionaryOrder: options.dictionaryOrder,
            ignoreNonprinting: options.ignoreNonprinting
        )
    }
    return options.reverse ? comparison.reversedForSort : comparison
}

private func compareSortField(
    _ lhs: String,
    _ rhs: String,
    key: SortKey,
    options: SortOptions,
    useLastResortComparison: Bool
) -> ComparisonResult {
    let ordering = key.effectiveOrdering(options: options)
    let lhsKey = sortKeyField(in: lhs, key: key, ordering: ordering, separator: options.fieldSeparator)
    let rhsKey = sortKeyField(in: rhs, key: key, ordering: ordering, separator: options.fieldSeparator)
    let comparison: ComparisonResult
    if ordering.month {
        comparison = monthComparison(lhsKey, rhsKey, useFallback: useLastResortComparison)
    } else if ordering.random {
        comparison = randomSortComparison(lhsKey, rhsKey, seed: options.randomSeed)
    } else if ordering.version {
        comparison = versionComparison(lhsKey, rhsKey, useFallback: useLastResortComparison)
    } else if ordering.generalNumeric {
        comparison = numericComparison(
            leadingGeneralNumber(lhsKey),
            leadingGeneralNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else if ordering.humanNumeric {
        comparison = numericComparison(
            leadingHumanNumber(lhsKey),
            leadingHumanNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else if ordering.numeric {
        comparison = numericComparison(
            leadingNumber(lhsKey),
            leadingNumber(rhsKey),
            fallbackLHS: lhsKey,
            fallbackRHS: rhsKey,
            useFallback: useLastResortComparison
        )
    } else {
        comparison = compareStrings(
            lhsKey,
            rhsKey,
            foldCase: ordering.foldCase,
            dictionaryOrder: ordering.dictionaryOrder,
            ignoreNonprinting: ordering.ignoreNonprinting
        )
    }
    return ordering.reverse ? comparison.reversedForSort : comparison
}

func bytewiseComparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let lhsData = Data(lhs.utf8)
    let rhsData = Data(rhs.utf8)
    if lhsData.lexicographicallyPrecedes(rhsData) {
        return .orderedAscending
    }
    if rhsData.lexicographicallyPrecedes(lhsData) {
        return .orderedDescending
    }
    return .orderedSame
}

private func compareStrings(
    _ lhs: String,
    _ rhs: String,
    foldCase: Bool,
    dictionaryOrder: Bool,
    ignoreNonprinting: Bool
) -> ComparisonResult {
    let lhsKey = comparableString(lhs, foldCase: foldCase, dictionaryOrder: dictionaryOrder, ignoreNonprinting: ignoreNonprinting)
    let rhsKey = comparableString(rhs, foldCase: foldCase, dictionaryOrder: dictionaryOrder, ignoreNonprinting: ignoreNonprinting)
    return bytewiseComparison(lhsKey, rhsKey)
}

private func comparableString(_ value: String, foldCase: Bool, dictionaryOrder: Bool, ignoreNonprinting: Bool) -> String {
    var result = dictionaryOrder
        ? String(value.filter { $0.isLetter || $0.isNumber || $0.isWhitespace })
        : value
    if ignoreNonprinting {
        result = String(result.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
    }
    if foldCase {
        result = result.lowercased()
    }
    return result
}

private func numericComparison(
    _ lhs: Double,
    _ rhs: Double,
    fallbackLHS: String,
    fallbackRHS: String,
    useFallback: Bool
) -> ComparisonResult {
    if lhs < rhs {
        return .orderedAscending
    }
    if lhs > rhs {
        return .orderedDescending
    }
    return useFallback ? bytewiseComparison(fallbackLHS, fallbackRHS) : .orderedSame
}

private func monthComparison(_ lhs: String, _ rhs: String, useFallback: Bool) -> ComparisonResult {
    let lhsMonth = leadingMonthNumber(lhs)
    let rhsMonth = leadingMonthNumber(rhs)
    if lhsMonth < rhsMonth {
        return .orderedAscending
    }
    if lhsMonth > rhsMonth {
        return .orderedDescending
    }
    return useFallback ? bytewiseComparison(lhs, rhs) : .orderedSame
}

private func leadingMonthNumber(_ value: String) -> Int {
    let prefix = value.trimmingLeadingWhitespace().prefix(while: { $0.isLetter }).lowercased()
    guard prefix.count >= 3 else {
        return 0
    }
    switch String(prefix.prefix(3)) {
    case "jan": return 1
    case "feb": return 2
    case "mar": return 3
    case "apr": return 4
    case "may": return 5
    case "jun": return 6
    case "jul": return 7
    case "aug": return 8
    case "sep": return 9
    case "oct": return 10
    case "nov": return 11
    case "dec": return 12
    default: return 0
    }
}

private func versionComparison(_ lhs: String, _ rhs: String, useFallback: Bool) -> ComparisonResult {
    let comparison = compareVersionLikeStrings(lhs, rhs)
    return comparison == .orderedSame && useFallback ? bytewiseComparison(lhs, rhs) : comparison
}

private func compareVersionLikeStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let lhsScalars = Array(lhs.unicodeScalars)
    let rhsScalars = Array(rhs.unicodeScalars)
    var lhsIndex = 0
    var rhsIndex = 0
    while lhsIndex < lhsScalars.count || rhsIndex < rhsScalars.count {
        if lhsIndex >= lhsScalars.count {
            return .orderedAscending
        }
        if rhsIndex >= rhsScalars.count {
            return .orderedDescending
        }
        let lhsIsDigit = CharacterSet.decimalDigits.contains(lhsScalars[lhsIndex])
        let rhsIsDigit = CharacterSet.decimalDigits.contains(rhsScalars[rhsIndex])
        if lhsIsDigit, rhsIsDigit {
            let lhsStart = lhsIndex
            let rhsStart = rhsIndex
            while lhsIndex < lhsScalars.count, CharacterSet.decimalDigits.contains(lhsScalars[lhsIndex]) {
                lhsIndex += 1
            }
            while rhsIndex < rhsScalars.count, CharacterSet.decimalDigits.contains(rhsScalars[rhsIndex]) {
                rhsIndex += 1
            }
            let lhsDigits = lhsScalars[lhsStart..<lhsIndex].map(String.init).joined()
            let rhsDigits = rhsScalars[rhsStart..<rhsIndex].map(String.init).joined()
            let comparison = compareVersionNumberRuns(lhsDigits, rhsDigits)
            if comparison != .orderedSame {
                return comparison
            }
            continue
        }
        let lhsValue = lhsScalars[lhsIndex].value
        let rhsValue = rhsScalars[rhsIndex].value
        if lhsValue < rhsValue {
            return .orderedAscending
        }
        if lhsValue > rhsValue {
            return .orderedDescending
        }
        lhsIndex += 1
        rhsIndex += 1
    }
    return .orderedSame
}

private func compareVersionNumberRuns(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let lhsTrimmed = lhs.drop { $0 == "0" }
    let rhsTrimmed = rhs.drop { $0 == "0" }
    let lhsSignificant = lhsTrimmed.isEmpty ? "0" : String(lhsTrimmed)
    let rhsSignificant = rhsTrimmed.isEmpty ? "0" : String(rhsTrimmed)
    if lhsSignificant.count < rhsSignificant.count {
        return .orderedAscending
    }
    if lhsSignificant.count > rhsSignificant.count {
        return .orderedDescending
    }
    return bytewiseComparison(lhsSignificant, rhsSignificant)
}

private func leadingGeneralNumber(_ line: String) -> Double {
    let trimmed = line.trimmingLeadingWhitespace()
    var end = trimmed.startIndex
    if end < trimmed.endIndex, trimmed[end] == "-" || trimmed[end] == "+" {
        end = trimmed.index(after: end)
    }
    var sawDigit = false
    while end < trimmed.endIndex, trimmed[end].isNumber {
        sawDigit = true
        end = trimmed.index(after: end)
    }
    if end < trimmed.endIndex, trimmed[end] == "." {
        end = trimmed.index(after: end)
        while end < trimmed.endIndex, trimmed[end].isNumber {
            sawDigit = true
            end = trimmed.index(after: end)
        }
    }
    if sawDigit, end < trimmed.endIndex, trimmed[end] == "e" || trimmed[end] == "E" {
        var exponentEnd = trimmed.index(after: end)
        if exponentEnd < trimmed.endIndex, trimmed[exponentEnd] == "-" || trimmed[exponentEnd] == "+" {
            exponentEnd = trimmed.index(after: exponentEnd)
        }
        let exponentDigitsStart = exponentEnd
        while exponentEnd < trimmed.endIndex, trimmed[exponentEnd].isNumber {
            exponentEnd = trimmed.index(after: exponentEnd)
        }
        if exponentEnd > exponentDigitsStart {
            end = exponentEnd
        }
    }
    guard sawDigit else {
        return -Double.infinity
    }
    return Double(trimmed[..<end]) ?? -Double.infinity
}

private func leadingNumber(_ line: String) -> Double {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var end = trimmed.startIndex
    var hasDigit = false
    var hasDecimalPoint = false
    if end < trimmed.endIndex, trimmed[end] == "-" || trimmed[end] == "+" {
        end = trimmed.index(after: end)
    }
    while end < trimmed.endIndex {
        let character = trimmed[end]
        if character.isNumber {
            hasDigit = true
            end = trimmed.index(after: end)
        } else if character == ".", !hasDecimalPoint {
            hasDecimalPoint = true
            end = trimmed.index(after: end)
        } else {
            break
        }
    }
    guard hasDigit else {
        return 0
    }
    return Double(trimmed[..<end]) ?? 0
}

private func leadingHumanNumber(_ line: String) -> Double {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var end = trimmed.startIndex
    var hasDigit = false
    var hasDecimalPoint = false
    if end < trimmed.endIndex, trimmed[end] == "-" || trimmed[end] == "+" {
        end = trimmed.index(after: end)
    }
    while end < trimmed.endIndex {
        let character = trimmed[end]
        if character.isNumber {
            hasDigit = true
            end = trimmed.index(after: end)
        } else if character == ".", !hasDecimalPoint {
            hasDecimalPoint = true
            end = trimmed.index(after: end)
        } else {
            break
        }
    }
    guard hasDigit else {
        return 0
    }
    let number = Double(trimmed[..<end]) ?? 0
    var suffixEnd = end
    while suffixEnd < trimmed.endIndex, trimmed[suffixEnd].isLetter {
        suffixEnd = trimmed.index(after: suffixEnd)
    }
    switch String(trimmed[end..<suffixEnd]).lowercased() {
    case "k", "kb", "ki", "kib":
        return number * 1024
    case "m", "mb", "mi", "mib":
        return number * 1024 * 1024
    case "g", "gb", "gi", "gib":
        return number * 1024 * 1024 * 1024
    case "t", "tb", "ti", "tib":
        return number * 1024 * 1024 * 1024 * 1024
    case "p", "pb", "pi", "pib":
        return number * 1024 * 1024 * 1024 * 1024 * 1024
    default:
        return number
    }
}

private extension ComparisonResult {
    var reversedForSort: ComparisonResult {
        switch self {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        var index = startIndex
        while index < endIndex, self[index].isWhitespace {
            index = self.index(after: index)
        }
        return String(self[index...])
    }
}

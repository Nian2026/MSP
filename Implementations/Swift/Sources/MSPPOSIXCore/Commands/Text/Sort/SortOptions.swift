import Foundation
import MSPCore

struct SortOptions {
    var reverse: Bool
    var numeric: Bool
    var generalNumeric: Bool
    var humanNumeric: Bool
    var month: Bool
    var merge: Bool
    var random: Bool
    var version: Bool
    var unique: Bool
    var zeroTerminated: Bool
    var checkOnly: Bool
    var quietCheck: Bool
    var stable: Bool
    var ignoreLeadingBlanks: Bool
    var foldCase: Bool
    var dictionaryOrder: Bool
    var ignoreNonprinting: Bool
    var outputPath: String?
    var files0From: String?
    var fieldSeparator: String?
    var keys: [SortKey]
    var debug: Bool
    var randomSourcePath: String?
    var randomSeed = Data()

    init(_ parsed: MSPPOSIXParsedArguments) throws {
        reverse = parsed.options.contains { $0.matches(short: "r") || $0.matches(long: "reverse") }
        var ordering = SortOrdering()
        for option in parsed.options {
            switch option.name {
            case .short("g"), .long("general-numeric-sort"):
                ordering.generalNumeric = true
            case .short("h"), .long("human-numeric-sort"):
                ordering.humanNumeric = true
            case .short("M"), .long("month-sort"):
                ordering.month = true
            case .short("n"), .long("numeric-sort"):
                ordering.numeric = true
            case .short("R"), .long("random-sort"):
                ordering.random = true
            case .short("V"), .long("version-sort"):
                ordering.version = true
            case .long("sort"):
                try ordering.applySortWord(option.value ?? "")
            default:
                break
            }
        }
        numeric = ordering.numeric
        generalNumeric = ordering.generalNumeric
        humanNumeric = ordering.humanNumeric
        month = ordering.month
        merge = parsed.options.contains { $0.matches(short: "m") || $0.matches(long: "merge") }
        random = ordering.random
        version = ordering.version
        unique = parsed.options.contains { $0.matches(short: "u") || $0.matches(long: "unique") }
        zeroTerminated = parsed.options.contains { $0.matches(short: "z") || $0.matches(long: "zero-terminated") }
        checkOnly = false
        quietCheck = false
        for option in parsed.options {
            if option.matches(short: "c") {
                checkOnly = true
            } else if option.matches(short: "C") {
                checkOnly = true
                quietCheck = true
            } else if option.matches(long: "check") {
                checkOnly = true
                switch option.value {
                case nil, "diagnose-first":
                    break
                case "quiet", "silent":
                    quietCheck = true
                default:
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: """
                        sort: invalid argument \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? "")) for \(MSPPOSIXCommandSupport.gnuQuote("--check"))
                        Valid arguments are:
                          - \(MSPPOSIXCommandSupport.gnuQuote("quiet")), \(MSPPOSIXCommandSupport.gnuQuote("silent"))
                          - \(MSPPOSIXCommandSupport.gnuQuote("diagnose-first"))
                        Try 'sort --help' for more information.

                        """
                    ))
                }
            }
        }
        stable = parsed.options.contains { $0.matches(short: "s") || $0.matches(long: "stable") }
        ignoreLeadingBlanks = parsed.options.contains { $0.matches(short: "b") || $0.matches(long: "ignore-leading-blanks") }
        foldCase = parsed.options.contains { $0.matches(short: "f") || $0.matches(long: "ignore-case") }
        dictionaryOrder = parsed.options.contains { $0.matches(short: "d") || $0.matches(long: "dictionary-order") }
        ignoreNonprinting = parsed.options.contains { $0.matches(short: "i") || $0.matches(long: "ignore-nonprinting") }
        outputPath = parsed.options.lastValue(short: "o", long: "output")
        files0From = parsed.options.reversed().first { $0.matches(long: "files0-from") }?.value
        fieldSeparator = try Self.parseFieldSeparator(parsed.options.lastValue(short: "t", long: "field-separator"))
        keys = try parsed.options.values(short: "k", long: "key").map(SortKey.init)
        debug = parsed.options.contains { $0.matches(long: "debug") }
        randomSourcePath = try Self.randomSourcePath(parsed.options)
        if debug, checkOnly {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: options '-c --debug' are incompatible\n"
            ))
        }
        if debug, outputPath != nil {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: options '-o --debug' are incompatible\n"
            ))
        }
        try validateOrderingCompatibility()
        try validatePerformanceKnobs(parsed.options)
    }

    private static func parseFieldSeparator(_ rawValue: String?) throws -> String? {
        guard let rawValue else {
            return nil
        }
        if rawValue.isEmpty {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: empty tab\n"
            ))
        }
        if rawValue == "\\0" {
            return "\0"
        }
        guard rawValue.count == 1 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: multi-character tab \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
            ))
        }
        return rawValue
    }

    private func validatePerformanceKnobs(_ options: [MSPPOSIXOption]) throws {
        for option in options {
            if option.matches(short: "S") || option.matches(long: "buffer-size") {
                try validateSortSize(
                    option.value ?? "",
                    optionName: option.matches(short: "S") ? "-S" : "--buffer-size"
                )
                continue
            }
            if option.matches(short: "T") || option.matches(long: "temporary-directory") {
                guard let value = option.value, !value.isEmpty else {
                    throw MSPCommandFailure.usage("sort: invalid --temporary-directory argument ''\n")
                }
                continue
            }
            if option.matches(long: "batch-size") {
                try validatePositiveIntegerOption(option, optionName: "--batch-size")
                continue
            }
            if option.matches(long: "parallel") {
                try validatePositiveIntegerOption(option, optionName: "--parallel")
            }
        }
    }

    private func validatePositiveIntegerOption(_ option: MSPPOSIXOption, optionName: String) throws {
        guard let value = option.value,
              let parsed = Int(value),
              parsed > 0 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "sort: invalid \(optionName) argument \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? ""))\n"
            ))
        }
    }

    private func validateSortSize(_ value: String, optionName: String) throws {
        guard !value.isEmpty else {
            throw MSPCommandFailure.usage("sort: invalid \(optionName) argument ''\n")
        }
        var digitsEnd = value.startIndex
        while digitsEnd < value.endIndex, value[digitsEnd].isNumber {
            digitsEnd = value.index(after: digitsEnd)
        }
        guard digitsEnd > value.startIndex else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: invalid number in \(optionName) argument '\(value)'\n"
            ))
        }
        let suffix = String(value[digitsEnd...])
        guard suffix.isEmpty
            || suffix == "b"
            || suffix == "%"
            || suffix.count == 1 && "EgGkKmMPtTYZ".contains(suffix) else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: invalid suffix in \(optionName) argument '\(value)'\n"
            ))
        }
    }

    private func validateOrderingCompatibility() throws {
        try validateOrderingCompatibility(
            numeric: numeric,
            generalNumeric: generalNumeric,
            humanNumeric: humanNumeric,
            month: month,
            version: version,
            random: random,
            dictionaryOrder: dictionaryOrder,
            ignoreNonprinting: ignoreNonprinting,
            label: sortOrderingCompatibilityLabel(
                numeric: numeric,
                generalNumeric: generalNumeric,
                humanNumeric: humanNumeric,
                month: month,
                version: version,
                random: random,
                dictionaryOrder: dictionaryOrder,
                ignoreNonprinting: ignoreNonprinting
            )
        )
        for key in keys {
            try validateOrderingCompatibility(
                numeric: key.numeric,
                generalNumeric: key.generalNumeric,
                humanNumeric: key.humanNumeric,
                month: key.month,
                version: key.version,
                random: key.random,
                dictionaryOrder: key.dictionaryOrder,
                ignoreNonprinting: key.ignoreNonprinting,
                label: sortOrderingCompatibilityLabel(
                    numeric: key.numeric,
                    generalNumeric: key.generalNumeric,
                    humanNumeric: key.humanNumeric,
                    month: key.month,
                    version: key.version,
                    random: key.random,
                    dictionaryOrder: key.dictionaryOrder,
                    ignoreNonprinting: key.ignoreNonprinting
                )
            )
        }
    }

    private func validateOrderingCompatibility(
        numeric: Bool,
        generalNumeric: Bool,
        humanNumeric: Bool,
        month: Bool,
        version: Bool,
        random: Bool,
        dictionaryOrder: Bool,
        ignoreNonprinting: Bool,
        label: String
    ) throws {
        let ignoreClass = dictionaryOrder || ignoreNonprinting
        let count = [numeric, generalNumeric, humanNumeric, month, version || random, ignoreClass].filter { $0 }.count
        guard count <= 1 else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: options '-\(label)' are incompatible\n"
            ))
        }
    }

    private static func randomSourcePath(_ options: [MSPPOSIXOption]) throws -> String? {
        let values = options.compactMap { $0.matches(long: "random-source") ? $0.value : nil }
        guard let first = values.first else {
            return nil
        }
        if values.contains(where: { $0 != first }) {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: multiple random sources specified\n"
            ))
        }
        return first
    }
}

private struct SortOrdering {
    var numeric = false
    var generalNumeric = false
    var humanNumeric = false
    var month = false
    var random = false
    var version = false

    mutating func applySortWord(_ word: String) throws {
        switch word {
        case "general-numeric":
            generalNumeric = true
        case "human-numeric":
            humanNumeric = true
        case "month":
            month = true
        case "numeric":
            numeric = true
        case "random":
            random = true
        case "version":
            version = true
        default:
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "sort: invalid argument \(MSPPOSIXCommandSupport.gnuQuote(word)) for \(MSPPOSIXCommandSupport.gnuQuote("--sort"))\n"
            ))
        }
    }
}

private func sortOrderingCompatibilityLabel(
    numeric: Bool,
    generalNumeric: Bool,
    humanNumeric: Bool,
    month: Bool,
    version: Bool,
    random: Bool,
    dictionaryOrder: Bool,
    ignoreNonprinting: Bool
) -> String {
    var label = ""
    if dictionaryOrder {
        label.append("d")
    } else if ignoreNonprinting {
        label.append("i")
    }
    if generalNumeric {
        label.append("g")
    }
    if humanNumeric {
        label.append("h")
    }
    if month {
        label.append("M")
    }
    if numeric {
        label.append("n")
    }
    if random {
        label.append("R")
    }
    if version {
        label.append("V")
    }
    return label
}

private extension Array where Element == MSPPOSIXOption {
    func lastValue(short: Character, long: String) -> String? {
        reversed().first { $0.matches(short: short) || $0.matches(long: long) }?.value
    }

    func values(short: Character, long: String) -> [String] {
        compactMap { option in
            option.matches(short: short) || option.matches(long: long) ? option.value : nil
        }
    }
}

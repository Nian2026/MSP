import Foundation
import MSPCore

extension MSPHeadTailCommand {
    func parse(_ arguments: [String]) throws -> HeadTailSelection {
        var selection = HeadTailSelection(
            unit: .lines,
            direction: command == "head" ? .head : .tail,
            count: 10,
            headerMode: .automatic,
            separator: 0x0A,
            operands: []
        )

        var parsingOptions = true
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if !parsingOptions {
                selection.operands.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                parsingOptions = false
                index += 1
                continue
            }

            if command == "tail",
               argument.hasPrefix("+"),
               let obsolete = try parseTailObsolete(argument) {
                applyObsolete(obsolete, to: &selection)
                index += 1
                continue
            }

            if argument.hasPrefix("--"), argument.count > 2 {
                let parsedLong = splitLongOption(argument)
                switch parsedLong.name {
                case "quiet", "silent":
                    selection.headerMode = .never
                case "verbose":
                    selection.headerMode = .always
                case "zero-terminated":
                    selection.separator = 0
                case "follow":
                    try rejectTailFollowPolicy(option: "--follow")
                case "retry":
                    try rejectTailFollowPolicy(option: "--retry")
                case "pid":
                    try rejectTailFollowPolicy(option: "--pid")
                case "sleep-interval":
                    try rejectTailFollowPolicy(option: "--sleep-interval")
                case "max-unchanged-stats":
                    try rejectTailFollowPolicy(option: "--max-unchanged-stats")
                case "lines", "bytes":
                    let value = try parsedLong.value ?? requireNextValue(
                        arguments,
                        index: &index,
                        option: parsedLong.name
                    )
                    try applyCount(
                        value,
                        unit: parsedLong.name == "bytes" ? .bytes : .lines,
                        to: &selection
                    )
                default:
                    throw MSPCommandFailure.usage("\(command): unsupported option -- \(parsedLong.name)\n")
                }
                index += 1
                continue
            }

            if argument.hasPrefix("-"), argument != "-" {
                if command == "head", let obsolete = try parseHeadObsolete(argument) {
                    applyObsolete(obsolete, to: &selection)
                    index += 1
                    continue
                }
                if command == "tail", let obsolete = try parseTailObsolete(argument) {
                    applyObsolete(obsolete, to: &selection)
                    index += 1
                    continue
                }

                var cursor = argument.index(after: argument.startIndex)
                while cursor < argument.endIndex {
                    let option = argument[cursor]
                    switch option {
                    case "q":
                        selection.headerMode = .never
                    case "v":
                        selection.headerMode = .always
                    case "z":
                        selection.separator = 0
                    case "f":
                        try rejectTailFollowPolicy(option: "-f")
                    case "F":
                        try rejectTailFollowPolicy(option: "-F")
                    case "s":
                        try rejectTailFollowPolicy(option: "-s")
                    case "n", "c":
                        let valueStart = argument.index(after: cursor)
                        let value: String
                        if valueStart < argument.endIndex {
                            value = String(argument[valueStart...])
                            cursor = argument.endIndex
                        } else {
                            value = try requireNextValue(arguments, index: &index, option: String(option))
                        }
                        try applyCount(value, unit: option == "c" ? .bytes : .lines, to: &selection)
                    case "0"..."9":
                        if command == "tail" {
                            throw MSPCommandFailure.usage("tail: option used in invalid context -- \(option)\n")
                        }
                        throw MSPCommandFailure.usage("head: invalid trailing option -- \(option)\n")
                    default:
                        throw MSPCommandFailure.usage("\(command): unsupported option -- \(option)\n")
                    }
                    if cursor < argument.endIndex {
                        cursor = argument.index(after: cursor)
                    }
                }
                index += 1
                continue
            }

            selection.operands.append(argument)
            index += 1
        }
        return selection
    }

    private func splitLongOption(_ argument: String) -> (name: String, value: String?) {
        let body = String(argument.dropFirst(2))
        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count == 2 ? String(parts[1]) : nil)
    }

    private func requireNextValue(
        _ arguments: [String],
        index: inout Int,
        option: String
    ) throws -> String {
        let next = index + 1
        guard next < arguments.count else {
            throw MSPCommandFailure.usage("\(command): option requires an argument -- \(option)\n")
        }
        index = next
        return arguments[next]
    }

    private func parseHeadObsolete(_ argument: String) throws -> HeadTailSelection? {
        guard argument.hasPrefix("-") else { return nil }
        let body = String(argument.dropFirst())
        guard let first = body.first, first.isNumber else { return nil }
        let numberText = String(body.prefix(while: \.isNumber))
        let trailing = String(body.dropFirst(numberText.count))
        var unit: Unit = .lines
        var headerMode: HeaderMode?
        var separator: UInt8?
        var multiplierSuffix = ""
        for option in trailing {
            switch option {
            case "c":
                unit = .bytes
                multiplierSuffix = ""
            case "b", "k", "m":
                unit = .bytes
                multiplierSuffix = String(option)
            case "l":
                unit = .lines
                multiplierSuffix = ""
            case "q":
                headerMode = .never
            case "v":
                headerMode = .always
            case "z":
                separator = 0
            default:
                throw MSPCommandFailure.usage("\(command): invalid trailing option -- \(option)\n")
            }
        }
        guard let count = parseCountWithOptionalSuffix(numberText + multiplierSuffix) else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "\(command): invalid number of \(unit == .bytes ? "bytes" : "lines"): \u{2018}\(numberText)\u{2019}\n"
            ))
        }
        return HeadTailSelection(
            unit: unit,
            direction: .head,
            count: count,
            headerMode: headerMode ?? .automatic,
            separator: separator ?? 0x0A,
            operands: []
        )
    }

    private func parseTailObsolete(_ argument: String) throws -> HeadTailSelection? {
        guard argument.hasPrefix("-") || argument.hasPrefix("+") else { return nil }
        var body = String(argument.dropFirst())
        let fromStart = argument.hasPrefix("+")
        let numberText = String(body.prefix(while: \.isNumber))
        body.removeFirst(numberText.count)
        guard !numberText.isEmpty || body == "b" else { return nil }

        var unit: Unit = .lines
        var multiplier = 1
        if let first = body.first {
            switch first {
            case "b":
                unit = .bytes
                multiplier = 512
                body.removeFirst()
            case "c":
                unit = .bytes
                body.removeFirst()
            case "l":
                unit = .lines
                body.removeFirst()
            default:
                break
            }
        }
        if body == "f" {
            try rejectTailFollowPolicy(option: argument.hasPrefix("+") ? "+f" : "-f")
        }
        guard body.isEmpty else {
            return nil
        }
        let baseCount: Int
        if numberText.isEmpty {
            baseCount = unit == .bytes && multiplier == 512 ? 5120 : 10
        } else {
            guard let parsed = Int(numberText), parsed >= 0 else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "tail: invalid number: \u{2018}\(argument)\u{2019}\n"
                ))
            }
            baseCount = parsed
        }
        let multiplied = baseCount.multipliedReportingOverflow(by: multiplier)
        guard !multiplied.overflow else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "tail: invalid number: \u{2018}\(argument)\u{2019}\n"
            ))
        }
        return HeadTailSelection(
            unit: unit,
            direction: fromStart ? .tailFromStart : .tail,
            count: multiplied.partialValue,
            headerMode: .automatic,
            separator: 0x0A,
            operands: []
        )
    }

    private func rejectTailFollowPolicy(option: String) throws -> Never {
        guard command == "tail" else {
            let display = option.drop(while: { $0 == "-" || $0 == "+" })
            throw MSPCommandFailure.usage("\(command): unsupported option -- \(display)\n")
        }
        throw MSPCommandFailure.usage(
            "tail: \(option) is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
    }

    private func applyObsolete(_ obsolete: HeadTailSelection, to selection: inout HeadTailSelection) {
        selection.unit = obsolete.unit
        selection.direction = obsolete.direction
        selection.count = obsolete.count
        if obsolete.headerMode != .automatic {
            selection.headerMode = obsolete.headerMode
        }
        if obsolete.separator != 0x0A || selection.separator == 0x0A {
            selection.separator = obsolete.separator
        }
    }

    private func applyCount(
        _ rawValue: String,
        unit: Unit,
        to selection: inout HeadTailSelection
    ) throws {
        var value = rawValue
        let sign: Character?
        if value.hasPrefix("+") || value.hasPrefix("-") {
            sign = value.removeFirst()
        } else {
            sign = nil
        }
        guard let count = parseCountWithOptionalSuffix(value), count >= 0 else {
            let unitName = unit == .bytes ? "bytes" : "lines"
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "\(command): invalid number of \(unitName): \u{2018}\(rawValue)\u{2019}\n"
            ))
        }
        selection.unit = unit
        selection.count = count
        if command == "head" {
            selection.direction = sign == "-" ? .headAllButLast : .head
        } else {
            selection.direction = sign == "+" ? .tailFromStart : .tail
        }
    }

    private func parseCountWithOptionalSuffix(_ value: String) -> Int? {
        guard !value.isEmpty else {
            return nil
        }
        let suffixes: [(String, Int)] = [
            ("QB", 1_000_000_000_000_000_000),
            ("Q", 1_152_921_504_606_846_976),
            ("RB", 1_000_000_000_000_000_000),
            ("R", 1_152_921_504_606_846_976),
            ("YB", 1_000_000_000_000_000_000),
            ("Y", 1_152_921_504_606_846_976),
            ("ZB", 1_000_000_000_000_000_000),
            ("Z", 1_152_921_504_606_846_976),
            ("EB", 1_000_000_000_000_000_000),
            ("E", 1_152_921_504_606_846_976),
            ("PB", 1_000_000_000_000_000),
            ("P", 1_125_899_906_842_624),
            ("TB", 1_000_000_000_000),
            ("T", 1_099_511_627_776),
            ("GB", 1_000_000_000),
            ("G", 1_073_741_824),
            ("MB", 1_000_000),
            ("M", 1_048_576),
            ("KB", 1_000),
            ("K", 1_024),
            ("kB", 1_000),
            ("k", 1_024),
            ("b", 512)
        ]
        for (suffix, multiplier) in suffixes {
            guard value.hasSuffix(suffix) else {
                continue
            }
            let number = String(value.dropLast(suffix.count))
            guard let base = Int(number), base >= 0 else {
                return nil
            }
            return base.multipliedReportingOverflow(by: multiplier).overflow ? nil : base * multiplier
        }
        return Int(value)
    }
}

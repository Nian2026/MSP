import Foundation
import MSPCore

public struct MSPDateCommand: MSPCommand {
    public var name: String { "date" }
    public var summary: String? { "Print the current date and time." }

    private let spec = MSPPOSIXCommandSpec(
        name: "date",
        allowedShortOptions: ["u"],
        allowedLongOptions: ["utc", "help", "version"],
        shortOptionsRequiringValue: ["d"],
        longOptionsRequiringValue: ["date", "rfc-3339"],
        shortOptionsWithOptionalValue: ["I"],
        longOptionsWithOptionalValue: ["iso-8601"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspDateUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "date (GNU coreutils) 9.1\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        guard parsed.operands.count <= 1 else {
            throw MSPCommandFailure.usage("date: extra operand \(parsed.operands[1])\n")
        }

        var timeZone = TimeZone.current
        var iso8601Precision: MSPDatePrecision?
        var rfc3339Precision: MSPDatePrecision?
        var dateDescription: String?

        for option in parsed.options {
            switch option.name {
            case .short("u"), .long("utc"):
                timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "GMT")!
            case .short("d"), .long("date"):
                dateDescription = option.value
            case .short("I"), .long("iso-8601"):
                iso8601Precision = try MSPDatePrecision(
                    iso8601: option.value,
                    optionName: MSPPOSIXOptionParser.optionDisplayName(option)
                )
            case .long("rfc-3339"):
                rfc3339Precision = try MSPDatePrecision(
                    rfc3339: option.value,
                    optionName: MSPPOSIXOptionParser.optionDisplayName(option)
                )
            default:
                continue
            }
        }

        let selectedDate = try dateDescription.map {
            try mspPOSIXDateFromDescription($0, timeZone: timeZone)
        } ?? Date()

        if let operand = parsed.operands.first {
            guard operand.hasPrefix("+") else {
                return .failure(
                    exitCode: 1,
                    stderr: "date: invalid date \(mspPOSIXGNUQuoted(operand))\n"
                )
            }
            return .success(stdout: mspPOSIXFormattedDate(
                selectedDate,
                shellFormat: String(operand.dropFirst()),
                timeZone: timeZone
            ) + "\n")
        }
        if let precision = rfc3339Precision {
            return .success(stdout: mspPOSIXRFC3339Date(selectedDate, precision: precision, timeZone: timeZone) + "\n")
        }
        if let precision = iso8601Precision {
            return .success(stdout: mspPOSIXISO8601Date(selectedDate, precision: precision, timeZone: timeZone) + "\n")
        }
        return .success(stdout: mspPOSIXDateComponent(
            selectedDate,
            format: "EEE MMM d HH:mm:ss z yyyy",
            timeZone: timeZone
        ) + "\n")
    }
}

private let mspDateUsage = """
Usage: date [OPTION]... [+FORMAT]
Display date and time in the given FORMAT.

"""

private enum MSPDatePrecision {
    case date
    case hours
    case minutes
    case seconds
    case nanoseconds

    init(iso8601 rawValue: String?, optionName: String) throws {
        switch rawValue ?? "" {
        case "", "date":
            self = .date
        case "hours":
            self = .hours
        case "minutes":
            self = .minutes
        case "seconds", "sec":
            self = .seconds
        case "ns":
            self = .nanoseconds
        default:
            throw MSPCommandFailure.usage("date: invalid argument '\(rawValue ?? "")' for '\(optionName)'\n")
        }
    }

    init(rfc3339 rawValue: String?, optionName: String) throws {
        switch rawValue ?? "" {
        case "date":
            self = .date
        case "seconds", "sec":
            self = .seconds
        case "ns":
            self = .nanoseconds
        default:
            throw MSPCommandFailure.usage("date: invalid argument '\(rawValue ?? "")' for '\(optionName)'\n")
        }
    }
}

private func mspPOSIXDateFromDescription(_ rawValue: String, timeZone: TimeZone) throws -> Date {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "date: invalid date \(mspPOSIXGNUQuoted(rawValue))\n"
        ))
    }
    if value.hasPrefix("@") {
        let secondsText = String(value.dropFirst())
        guard let seconds = Double(secondsText) else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "date: invalid date \(mspPOSIXGNUQuoted(rawValue))\n"
            ))
        }
        return Date(timeIntervalSince1970: seconds)
    }

    let explicitUTC: Bool
    let parseValue: String
    if value.uppercased().hasSuffix(" UTC") {
        explicitUTC = true
        parseValue = String(value.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else if value.uppercased().hasSuffix(" Z") {
        explicitUTC = true
        parseValue = String(value.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        explicitUTC = false
        parseValue = value
    }

    let parseTimeZone = explicitUTC
        ? (TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "GMT")!)
        : timeZone
    for format in [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd"
    ] {
        if let date = mspPOSIXParseDate(parseValue, format: format, timeZone: parseTimeZone) {
            return date
        }
    }

    throw MSPCommandFailure(result: .failure(
        exitCode: 1,
        stderr: "date: invalid date \(mspPOSIXGNUQuoted(rawValue))\n"
    ))
}

private func mspPOSIXParseDate(_ value: String, format: String, timeZone: TimeZone) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    formatter.isLenient = false
    return formatter.date(from: value)
}

private func mspPOSIXISO8601Date(_ date: Date, precision: MSPDatePrecision, timeZone: TimeZone) -> String {
    switch precision {
    case .date:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd", timeZone: timeZone)
    case .hours:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd'T'HH", timeZone: timeZone)
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    case .minutes:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd'T'HH:mm", timeZone: timeZone)
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    case .seconds:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    case .nanoseconds:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
            + ",000000000"
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    }
}

private func mspPOSIXRFC3339Date(_ date: Date, precision: MSPDatePrecision, timeZone: TimeZone) -> String {
    switch precision {
    case .date:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd", timeZone: timeZone)
    case .seconds:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    case .nanoseconds:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
            + ".000000000"
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    case .hours, .minutes:
        return mspPOSIXDateComponent(date, format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
            + mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: true)
    }
}

private func mspPOSIXFormattedDate(_ date: Date, shellFormat: String, timeZone: TimeZone) -> String {
    var output = ""
    var index = shellFormat.startIndex
    while index < shellFormat.endIndex {
        let character = shellFormat[index]
        guard character == "%" else {
            output.append(character)
            index = shellFormat.index(after: index)
            continue
        }
        let tokenIndex = shellFormat.index(after: index)
        guard tokenIndex < shellFormat.endIndex else {
            output.append("%")
            index = tokenIndex
            continue
        }
        let token = shellFormat[tokenIndex]
        if token == ":" {
            var zoneIndex = tokenIndex
            var colonCount = 0
            while zoneIndex < shellFormat.endIndex, shellFormat[zoneIndex] == ":" {
                colonCount += 1
                zoneIndex = shellFormat.index(after: zoneIndex)
            }
            if zoneIndex < shellFormat.endIndex, shellFormat[zoneIndex] == "z" {
                output += mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colonCount: colonCount)
                index = shellFormat.index(after: zoneIndex)
                continue
            }
        }
        switch token {
        case "%":
            output.append("%")
        case "Y":
            output += mspPOSIXDateComponent(date, format: "yyyy", timeZone: timeZone)
        case "y":
            output += mspPOSIXDateComponent(date, format: "yy", timeZone: timeZone)
        case "m":
            output += mspPOSIXDateComponent(date, format: "MM", timeZone: timeZone)
        case "d":
            output += mspPOSIXDateComponent(date, format: "dd", timeZone: timeZone)
        case "e":
            output += String(format: "%2d", mspPOSIXCalendar(timeZone).component(.day, from: date))
        case "H":
            output += mspPOSIXDateComponent(date, format: "HH", timeZone: timeZone)
        case "M":
            output += mspPOSIXDateComponent(date, format: "mm", timeZone: timeZone)
        case "S":
            output += mspPOSIXDateComponent(date, format: "ss", timeZone: timeZone)
        case "F":
            output += mspPOSIXDateComponent(date, format: "yyyy-MM-dd", timeZone: timeZone)
        case "D":
            output += mspPOSIXDateComponent(date, format: "MM/dd/yy", timeZone: timeZone)
        case "T":
            output += mspPOSIXDateComponent(date, format: "HH:mm:ss", timeZone: timeZone)
        case "R":
            output += mspPOSIXDateComponent(date, format: "HH:mm", timeZone: timeZone)
        case "z":
            output += mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: false)
        case "Z":
            output += mspPOSIXTimeZoneName(date, timeZone: timeZone)
        case "s":
            output += String(Int(date.timeIntervalSince1970))
        case "N":
            output += "000000000"
        case "j":
            let day = mspPOSIXCalendar(timeZone).ordinality(of: .day, in: .year, for: date) ?? 1
            output += String(format: "%03d", day)
        case "u":
            let weekday = mspPOSIXCalendar(timeZone).component(.weekday, from: date)
            output += String(((weekday + 5) % 7) + 1)
        case "w":
            let weekday = mspPOSIXCalendar(timeZone).component(.weekday, from: date)
            output += String(weekday - 1)
        case "c":
            output += mspPOSIXCLocaleDateTime(date, timeZone: timeZone)
        case "n":
            output += "\n"
        case "t":
            output += "\t"
        case "a":
            output += mspPOSIXDateComponent(date, format: "EEE", timeZone: timeZone)
        case "A":
            output += mspPOSIXDateComponent(date, format: "EEEE", timeZone: timeZone)
        case "b", "h":
            output += mspPOSIXDateComponent(date, format: "MMM", timeZone: timeZone)
        case "B":
            output += mspPOSIXDateComponent(date, format: "MMMM", timeZone: timeZone)
        default:
            output.append("%")
            output.append(token)
        }
        index = shellFormat.index(after: tokenIndex)
    }
    return output
}

private func mspPOSIXDateComponent(_ date: Date, format: String, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
}

private func mspPOSIXCLocaleDateTime(_ date: Date, timeZone: TimeZone) -> String {
    let calendar = mspPOSIXCalendar(timeZone)
    let day = calendar.component(.day, from: date)
    return [
        mspPOSIXDateComponent(date, format: "EEE", timeZone: timeZone),
        mspPOSIXDateComponent(date, format: "MMM", timeZone: timeZone),
        String(format: "%2d", day),
        mspPOSIXDateComponent(date, format: "HH:mm:ss", timeZone: timeZone),
        mspPOSIXDateComponent(date, format: "yyyy", timeZone: timeZone)
    ].joined(separator: " ")
}

private func mspPOSIXCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = timeZone
    return calendar
}

private func mspPOSIXTimeZoneOffset(_ date: Date, timeZone: TimeZone, colon: Bool) -> String {
    mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colonCount: colon ? 1 : 0)
}

private func mspPOSIXTimeZoneOffset(_ date: Date, timeZone: TimeZone, colonCount: Int) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "-" : "+"
    let absoluteSeconds = abs(seconds)
    let hours = absoluteSeconds / 3600
    let minutes = (absoluteSeconds % 3600) / 60
    let remainingSeconds = absoluteSeconds % 60
    switch colonCount {
    case 0:
        return String(format: "%@%02d%02d", sign, hours, minutes)
    case 1:
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    case 2:
        return String(format: "%@%02d:%02d:%02d", sign, hours, minutes, remainingSeconds)
    default:
        if minutes == 0, remainingSeconds == 0 {
            return String(format: "%@%02d", sign, hours)
        }
        if remainingSeconds == 0 {
            return String(format: "%@%02d:%02d", sign, hours, minutes)
        }
        return String(format: "%@%02d:%02d:%02d", sign, hours, minutes, remainingSeconds)
    }
}

private func mspPOSIXTimeZoneName(_ date: Date, timeZone: TimeZone) -> String {
    if timeZone.secondsFromGMT(for: date) == 0 {
        return "UTC"
    }
    return timeZone.abbreviation(for: date) ?? mspPOSIXTimeZoneOffset(date, timeZone: timeZone, colon: false)
}

private func mspPOSIXGNUQuoted(_ value: String) -> String {
    "\u{2018}\(value)\u{2019}"
}

import Foundation
import MSPCore

func formatFindPrintf(_ format: String, item: FindItem) -> String {
    var output = ""
    var context = FindPrintfRenderContext(item: item)
    var index = format.startIndex
    while index < format.endIndex {
        let character = format[index]
        if character == "\\" {
            let next = format.index(after: index)
            guard next < format.endIndex else {
                output.append(character)
                index = next
                continue
            }
            output += escapedFindPrintfCharacter(format[next])
            index = format.index(after: next)
            continue
        }
        if character == "%" {
            let formatted = formatFindPrintfSpecifier(format, percentIndex: index, context: &context)
            output += formatted.output
            index = formatted.nextIndex
            continue
        }
        output.append(character)
        index = format.index(after: index)
    }
    return output
}

private func escapedFindPrintfCharacter(_ character: Character) -> String {
    switch character {
    case "a":
        return "\u{7}"
    case "b":
        return "\u{8}"
    case "f":
        return "\u{c}"
    case "n":
        return "\n"
    case "r":
        return "\r"
    case "t":
        return "\t"
    case "v":
        return "\u{b}"
    case "\\":
        return "\\"
    case "0":
        return "\0"
    default:
        return String(character)
    }
}

private func formatFindPrintfSpecifier(
    _ format: String,
    percentIndex: String.Index,
    context: inout FindPrintfRenderContext
) -> (output: String, nextIndex: String.Index) {
    let next = format.index(after: percentIndex)
    guard next < format.endIndex else {
        return ("%", next)
    }
    if format[next] == "%" {
        return ("%", format.index(after: next))
    }

    let specifier = parseFindPrintfSpecifier(in: format, afterPercent: next)
    guard isSupportedFindPrintfConversion(specifier.conversion) else {
        return (String(format[percentIndex..<specifier.nextIndex]), specifier.nextIndex)
    }

    let output: String
    var precision = specifier.precision
    var nextIndex = specifier.nextIndex
    switch specifier.conversion {
    case "A", "C", "T":
        guard nextIndex < format.endIndex else {
            return (String(format[percentIndex..<nextIndex]), nextIndex)
        }
        output = formatFindTimestamp(
            format[nextIndex],
            date: context.item.info.modificationDate ?? Date(timeIntervalSince1970: 0),
            precision: precision,
            context: &context
        )
        precision = nil
        nextIndex = format.index(after: nextIndex)
    case "p":
        output = context.item.displayPath
    case "P":
        output = relativePath(context.item.info.virtualPath, basePath: context.item.basePath)
    case "H":
        output = context.item.displayBasePath
    case "f":
        output = displayName(context.item.displayPath)
    case "h":
        output = parentDisplayPath(context.item.displayPath)
    case "s":
        output = String(MSPPOSIXCommandSupport.byteSize(context.item.info))
    case "b":
        output = String((MSPPOSIXCommandSupport.byteSize(context.item.info) + 511) / 512)
    case "k":
        output = String((MSPPOSIXCommandSupport.byteSize(context.item.info) + 1023) / 1024)
    case "m":
        output = MSPPOSIXCommandSupport.modeOctalString(for: context.item.info)
    case "M":
        output = MSPPOSIXCommandSupport.modeString(for: context.item.info)
    case "y", "Y":
        output = typeLetter(for: context.item.info)
    case "d":
        output = String(context.item.depth)
    case "n":
        output = "1"
    case "u", "g":
        output = "msp"
    case "U", "G", "D":
        output = "0"
    case "F":
        output = "msp"
    case "l":
        output = context.item.info.symbolicLinkTarget ?? ""
    case "a", "c", "t":
        output = formatFindCtime(
            context.item.info.modificationDate ?? Date(timeIntervalSince1970: 0),
            context: &context
        )
    case "i":
        output = String(stableIdentifier(for: context.item.displayPath))
    default:
        return (String(format[percentIndex..<nextIndex]), nextIndex)
    }
    return (
        applyFindPrintfFieldFormatting(
            output,
            flags: specifier.flags,
            width: specifier.width,
            precision: precision
        ),
        nextIndex
    )
}

private struct FindPrintfSpecifier {
    var flags: Set<Character>
    var width: Int?
    var precision: Int?
    var conversion: Character
    var nextIndex: String.Index
}

private func parseFindPrintfSpecifier(
    in format: String,
    afterPercent startIndex: String.Index
) -> FindPrintfSpecifier {
    var index = startIndex
    var flags: Set<Character> = []
    while index < format.endIndex, "-+ #0".contains(format[index]) {
        flags.insert(format[index])
        index = format.index(after: index)
    }

    var widthDigits = ""
    while index < format.endIndex, format[index].isNumber {
        widthDigits.append(format[index])
        index = format.index(after: index)
    }

    var precision: Int?
    if index < format.endIndex, format[index] == "." {
        index = format.index(after: index)
        var precisionDigits = ""
        while index < format.endIndex, format[index].isNumber {
            precisionDigits.append(format[index])
            index = format.index(after: index)
        }
        precision = Int(precisionDigits) ?? 0
    }

    guard index < format.endIndex else {
        return FindPrintfSpecifier(
            flags: flags,
            width: Int(widthDigits),
            precision: precision,
            conversion: "%",
            nextIndex: index
        )
    }

    return FindPrintfSpecifier(
        flags: flags,
        width: Int(widthDigits),
        precision: precision,
        conversion: format[index],
        nextIndex: format.index(after: index)
    )
}

private func isSupportedFindPrintfConversion(_ conversion: Character) -> Bool {
    switch conversion {
    case "A", "C", "T", "p", "P", "H", "M", "m", "f", "b", "k", "h", "i", "D", "F", "l", "n", "u", "U", "g", "G", "y", "Y", "s", "d", "a", "c", "t":
        return true
    default:
        return false
    }
}

private func applyFindPrintfFieldFormatting(
    _ value: String,
    flags: Set<Character>,
    width: Int?,
    precision: Int?
) -> String {
    let truncated: String
    if let precision, value.count > precision {
        truncated = String(value.prefix(precision))
    } else {
        truncated = value
    }

    guard let width, truncated.count < width else {
        return truncated
    }
    let paddingCharacter = flags.contains("0") && !flags.contains("-") ? "0" : " "
    let padding = String(repeating: paddingCharacter, count: width - truncated.count)
    return flags.contains("-") ? truncated + padding : padding + truncated
}

private func formatFindTimestamp(
    _ directive: Character,
    date: Date,
    precision: Int? = nil,
    context: inout FindPrintfRenderContext
) -> String {
    let components = context.timestampComponents(for: date)
    switch directive {
    case "@":
        return String(
            format: "%.\(precision ?? 9)f",
            locale: Locale(identifier: "en_US_POSIX"),
            date.timeIntervalSince1970
        )
    case "+":
        return formatFindDate(date, pattern: "yyyy-MM-dd+HH:mm:ss.SSSSSSSSSZ")
    case "Y":
        return pad(components.year, width: 4)
    case "y":
        return pad(abs(components.year) % 100, width: 2)
    case "m":
        return pad(components.month, width: 2)
    case "d":
        return pad(components.day, width: 2)
    case "H":
        return pad(components.hour24, width: 2)
    case "I":
        return pad(components.hour12, width: 2)
    case "k":
        return String(components.hour24)
    case "l":
        return String(components.hour12)
    case "M":
        return pad(components.minute, width: 2)
    case "S":
        if let precision {
            let seconds = Double(components.second)
            var fraction = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
            if fraction < 0 {
                fraction += 1
            }
            let width = precision > 0 ? precision + 3 : 2
            return String(
                format: "%0\(width).\(precision)f",
                locale: Locale(identifier: "en_US_POSIX"),
                seconds + fraction
            )
        }
        return pad(components.second, width: 2)
    case "T":
        return "\(pad(components.hour24, width: 2)):\(pad(components.minute, width: 2)):\(pad(components.second, width: 2))"
    case "R":
        return "\(pad(components.hour24, width: 2)):\(pad(components.minute, width: 2))"
    case "D":
        return "\(pad(components.month, width: 2))/\(pad(components.day, width: 2))/\(pad(abs(components.year) % 100, width: 2))"
    case "F":
        return "\(pad(components.year, width: 4))-\(pad(components.month, width: 2))-\(pad(components.day, width: 2))"
    case "a":
        return formatFindDate(date, pattern: "EEE")
    case "A":
        return formatFindDate(date, pattern: "EEEE")
    case "b", "h":
        return formatFindDate(date, pattern: "MMM")
    case "B":
        return formatFindDate(date, pattern: "MMMM")
    case "p":
        return formatFindDate(date, pattern: "a")
    case "Z":
        return formatFindDate(date, pattern: "zzz")
    default:
        return "%T\(directive)"
    }
}

private func formatFindDate(_ date: Date, pattern: String) -> String {
    findDateFormatterCache.string(from: date, pattern: pattern)
}

private func formatFindCtime(_ date: Date, context: inout FindPrintfRenderContext) -> String {
    formatFindDate(date, pattern: "EEE MMM d HH:mm:ss yyyy")
}

private struct FindPrintfRenderContext {
    var item: FindItem
    private var cachedTimestamp: (date: Date, components: FindTimestampComponents)?

    init(item: FindItem) {
        self.item = item
    }

    mutating func timestampComponents(for date: Date) -> FindTimestampComponents {
        if let cachedTimestamp, cachedTimestamp.date == date {
            return cachedTimestamp.components
        }
        let components = FindTimestampComponents(date: date)
        cachedTimestamp = (date, components)
        return components
    }
}

private struct FindTimestampComponents {
    var year: Int
    var month: Int
    var day: Int
    var hour24: Int
    var hour12: Int
    var minute: Int
    var second: Int

    init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
        hour24 = components.hour ?? 0
        let normalizedHour = hour24 % 12
        hour12 = normalizedHour == 0 ? 12 : normalizedHour
        minute = components.minute ?? 0
        second = components.second ?? 0
    }
}

private func pad(_ value: Int, width: Int) -> String {
    let text = String(value)
    guard text.count < width else {
        return text
    }
    return String(repeating: "0", count: width - text.count) + text
}

private struct FindDateFormatterKey: Hashable {
    var pattern: String
    var timeZoneIdentifier: String
}

private final class FindDateFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [FindDateFormatterKey: DateFormatter] = [:]

    func string(from date: Date, pattern: String) -> String {
        let timeZone = TimeZone.current
        let key = FindDateFormatterKey(
            pattern: pattern,
            timeZoneIdentifier: timeZone.identifier
        )
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let existing = formatters[key] {
            formatter = existing
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.timeZone = timeZone
            created.dateFormat = pattern
            formatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}

private let findDateFormatterCache = FindDateFormatterCache()

private func typeLetter(for info: MSPFileInfo) -> String {
    switch info.type {
    case .directory:
        return "d"
    case .symbolicLink:
        return "l"
    case .regularFile:
        return "f"
    case .other:
        return "?"
    }
}

private func displayName(_ path: String) -> String {
    if path == "/" {
        return "/"
    }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? trimmed
}

private func parentDisplayPath(_ path: String) -> String {
    if path == "/" {
        return "/"
    }
    var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty else {
        return "."
    }
    components.removeLast()
    if path.hasPrefix("/") {
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
    return components.isEmpty ? "." : components.joined(separator: "/")
}

private func relativePath(_ path: String, basePath: String) -> String {
    let baseComponents = MSPWorkspacePathResolver.components(in: basePath)
    let pathComponents = MSPWorkspacePathResolver.components(in: path)
    return pathComponents.dropFirst(baseComponents.count).joined(separator: "/")
}

private func stableIdentifier(for path: String) -> UInt64 {
    path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
}

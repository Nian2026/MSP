import Foundation

enum MSPPOSIXSedAddressParser {
    static func splitAddressRange(_ address: String) throws -> [String] {
        try splitDelimitedText(address, separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parseAddressPrefix(
        _ command: String,
        extendedRegex: Bool
    ) throws -> (start: MSPPOSIXSedAddress?, end: MSPPOSIXSedAddress?, rest: String) {
        var rest = command.trimmingCharacters(in: .whitespaces)
        guard let first = rest.first, isAddressStart(first) else {
            return (nil, nil, rest)
        }
        let firstAddress = try readAddressPrefix(from: rest, extendedRegex: extendedRegex)
        rest = firstAddress.rest.trimmingCharacters(in: .whitespaces)
        if rest.first == "," {
            rest.removeFirst()
            rest = rest.trimmingCharacters(in: .whitespaces)
            let secondAddress = try readAddressPrefix(from: rest, extendedRegex: extendedRegex)
            return (firstAddress.address, secondAddress.address, secondAddress.rest)
        }
        return (firstAddress.address, nil, rest)
    }

    static func parseAddress(
        _ rawValue: String,
        extendedRegex: Bool
    ) throws -> MSPPOSIXSedAddress {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if trimmed == "$" {
            return .last
        }
        if trimmed.hasPrefix("/"), trimmed.hasSuffix("/"), trimmed.count >= 2 {
            return .regex(pattern: String(trimmed.dropFirst().dropLast()), extendedRegex: extendedRegex)
        }
        if let range = trimmed.range(of: #"^[0-9]+~[1-9][0-9]*$"#, options: .regularExpression) {
            let matched = String(trimmed[range])
            let parts = matched.split(separator: "~", maxSplits: 1).compactMap { Int($0) }
            if parts.count == 2 {
                return .step(first: parts[0], stride: parts[1])
            }
        }
        guard let value = Int(trimmed), value >= 1 else {
            throw MSPPOSIXSedError.usage("sed: unsupported address \(rawValue)")
        }
        return .line(value)
    }

    private static func readAddressPrefix(
        from command: String,
        extendedRegex: Bool
    ) throws -> (address: MSPPOSIXSedAddress, rest: String) {
        guard let first = command.first else {
            throw MSPPOSIXSedError.usage("sed: missing address")
        }
        if first == "/" {
            var index = command.index(after: command.startIndex)
            var pattern = ""
            var escaped = false
            while index < command.endIndex {
                let character = command[index]
                if escaped {
                    pattern.append(character)
                    escaped = false
                    index = command.index(after: index)
                    continue
                }
                if character == "\\" {
                    pattern.append(character)
                    escaped = true
                    index = command.index(after: index)
                    continue
                }
                if character == "/" {
                    let rest = String(command[command.index(after: index)...])
                    return (.regex(pattern: pattern, extendedRegex: extendedRegex), rest)
                }
                pattern.append(character)
                index = command.index(after: index)
            }
            throw MSPPOSIXSedError.usage("sed: unterminated address regex")
        }
        if first == "$" {
            return (.last, String(command.dropFirst()))
        }
        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            guard character.isNumber || character == "~" else { break }
            index = command.index(after: index)
        }
        let rawAddress = String(command[..<index])
        guard !rawAddress.isEmpty else {
            throw MSPPOSIXSedError.usage("sed: missing address")
        }
        return (try parseAddress(rawAddress, extendedRegex: extendedRegex), String(command[index...]))
    }

    private static func isAddressStart(_ character: Character) -> Bool {
        character == "/" || character == "$" || character.isNumber
    }

    private static func splitDelimitedText(_ text: String, separator: Character) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var index = text.startIndex
        var inRegex = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                current.append(character)
                escaped = false
                index = text.index(after: index)
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                index = text.index(after: index)
                continue
            }
            if character == "/" {
                inRegex.toggle()
                current.append(character)
                index = text.index(after: index)
                continue
            }
            if character == separator, !inRegex {
                parts.append(current)
                current = ""
                index = text.index(after: index)
                continue
            }
            current.append(character)
            index = text.index(after: index)
        }
        guard !inRegex else {
            throw MSPPOSIXSedError.usage("sed: unterminated address regex")
        }
        parts.append(current)
        return parts
    }
}

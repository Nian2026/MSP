import Foundation

public enum MSPShellProcessSubstitutionMode: Character, Sendable {
    case input = "I"
    case output = "O"

    public var operatorText: String {
        switch self {
        case .input:
            return "<"
        case .output:
            return ">"
        }
    }
}

package enum MSPShellProcessSubstitutionToken {
    package static let prefix = "__MSP_PROCESS_SUBST_"

    package static func encoded(command: String, mode: MSPShellProcessSubstitutionMode) -> String {
        let raw = command.data(using: .utf8)?.base64EncodedString() ?? ""
        let encoded = raw
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ".")
        return "\(prefix)\(mode.rawValue)\(encoded.count)_\(encoded)"
    }

    package static func decodedMarker(
        in text: String,
        startingAt startIndex: String.Index
    ) throws -> (mode: MSPShellProcessSubstitutionMode, command: String, nextIndex: String.Index)? {
        guard text[startIndex...].hasPrefix(prefix) else { return nil }
        var cursor = text.index(startIndex, offsetBy: prefix.count)
        var mode = MSPShellProcessSubstitutionMode.input
        if cursor < text.endIndex, let parsedMode = MSPShellProcessSubstitutionMode(rawValue: text[cursor]) {
            mode = parsedMode
            cursor = text.index(after: cursor)
        }
        var lengthText = ""
        while cursor < text.endIndex, text[cursor].isNumber {
            lengthText.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "_", let length = Int(lengthText) else {
            throw invalidMarker(mode: mode)
        }
        cursor = text.index(after: cursor)
        guard let encodedEnd = text.index(cursor, offsetBy: length, limitedBy: text.endIndex) else {
            throw invalidMarker(mode: mode)
        }
        let command = try decodedCommand(encodedText: String(text[cursor..<encodedEnd]), mode: mode)
        return (mode, command, encodedEnd)
    }

    private static func decodedCommand(
        encodedText: String,
        mode: MSPShellProcessSubstitutionMode
    ) throws -> String {
        var encoded = encodedText
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded),
              let command = String(data: data, encoding: .utf8) else {
            throw ShellExit.usage("\(mode.operatorText)(: invalid process substitution command")
        }
        return command
    }

    private static func invalidMarker(mode: MSPShellProcessSubstitutionMode) -> ShellExit {
        ShellExit.usage("\(mode.operatorText)(: invalid process substitution marker")
    }
}

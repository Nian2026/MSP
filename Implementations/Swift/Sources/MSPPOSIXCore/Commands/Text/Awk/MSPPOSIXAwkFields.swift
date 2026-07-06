import Foundation

enum MSPPOSIXAwkFields {
    static func records(in text: String, separator: String) -> [String] {
        guard !separator.isEmpty else {
            return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        var records = text.components(separatedBy: separator)
        if text.hasSuffix(separator) {
            records.removeLast()
        }
        return records
    }

    static func split(line: String, fieldSeparator: String?) -> [String] {
        guard let activeSeparator = fieldSeparator else {
            return line.split { $0.isWhitespace }.map(String.init)
        }
        if activeSeparator == " " {
            return line.split { $0.isWhitespace }.map(String.init)
        }
        if activeSeparator.isEmpty {
            return line.map(String.init)
        }
        return line.components(separatedBy: activeSeparator)
    }

    static func setField(
        _ number: Int,
        value: String,
        currentFields: inout [String],
        currentLine: inout String
    ) {
        guard number >= 1 else { return }
        while currentFields.count < number {
            currentFields.append("")
        }
        currentFields[number - 1] = value
        currentLine = currentFields.joined(separator: " ")
    }

    static func field(_ number: Int, currentFields: [String]) -> String {
        guard number >= 1, number <= currentFields.count else { return "" }
        return currentFields[number - 1]
    }
}

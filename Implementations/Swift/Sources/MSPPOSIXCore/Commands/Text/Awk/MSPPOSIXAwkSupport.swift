import Foundation
import MSPCore

enum MSPPOSIXAwkError {
    static func failure(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(
            result: .failure(
                stderr: message.hasSuffix("\n") ? message : message + "\n"
            )
        )
    }

    static func usage(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(
            result: .failure(
                exitCode: 2,
                stderr: message.hasSuffix("\n") ? message : message + "\n"
            )
        )
    }
}

func mspPOSIXAwkDecodeBackslashEscapes(_ value: String) -> String {
    var output = ""
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        guard character == "\\" else {
            output.append(character)
            index = value.index(after: index)
            continue
        }
        let next = value.index(after: index)
        guard next < value.endIndex else {
            output.append(character)
            index = next
            continue
        }
        switch value[next] {
        case "n":
            output.append("\n")
        case "t":
            output.append("\t")
        case "r":
            output.append("\r")
        case "\\":
            output.append("\\")
        case "0":
            output.append("\0")
        default:
            output.append(value[next])
        }
        index = value.index(after: next)
    }
    return output
}

func mspPOSIXAwkAssignment(_ word: String) -> (name: String, value: String)? {
    guard let equalIndex = word.firstIndex(of: "="),
          equalIndex != word.startIndex else {
        return nil
    }
    let name = String(word[..<equalIndex])
    guard mspPOSIXAwkVariableName(name) else {
        return nil
    }
    let valueStart = word.index(after: equalIndex)
    return (name, String(word[valueStart...]))
}

private func mspPOSIXAwkVariableName(_ value: String) -> Bool {
    guard let first = value.first,
          first == "_" || first.isLetter else {
        return false
    }
    return value.dropFirst().allSatisfy { character in
        character == "_" || character.isLetter || character.isNumber
    }
}

import Foundation

enum MSPPOSIXAwkPrintf {
    private static let conversionCharacters = Set("disfFgGeE")

    static func format(format: String, values: [String]) -> String {
        var output = ""
        var index = format.startIndex
        var argumentIndex = 0
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                output.append(character)
                index = format.index(after: index)
                continue
            }
            let next = format.index(after: index)
            guard next < format.endIndex else {
                output.append(character)
                index = next
                continue
            }
            if format[next] == "%" {
                output.append("%")
                index = format.index(after: next)
                continue
            }
            var conversionIndex = next
            while conversionIndex < format.endIndex,
                  !conversionCharacters.contains(format[conversionIndex]) {
                conversionIndex = format.index(after: conversionIndex)
            }
            guard conversionIndex < format.endIndex else {
                output += String(format[index...])
                break
            }
            let specifier = String(format[index...conversionIndex])
            let conversion = format[conversionIndex]
            let value = argumentIndex < values.count ? values[argumentIndex] : ""
            argumentIndex += 1
            switch conversion {
            case "d", "i":
                output += String(format: specifier, Int(Double(value) ?? 0))
            case "s":
                output += value
            case "f", "F", "g", "G", "e", "E":
                output += String(format: specifier, Double(value) ?? 0)
            default:
                output += value
            }
            index = format.index(after: conversionIndex)
        }
        return output
    }
}

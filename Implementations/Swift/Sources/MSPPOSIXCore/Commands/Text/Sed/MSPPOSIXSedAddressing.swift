import Foundation

enum MSPPOSIXSedAddressing {
    static func address(
        _ address: MSPPOSIXSedAddress,
        matches line: String,
        lineNumber: Int,
        lineCount: Int
    ) throws -> Bool {
        switch address {
        case .line(let value):
            return lineNumber == value
        case .step(let first, let stride):
            if first == 0 {
                return lineNumber % stride == 0
            }
            return lineNumber >= first && (lineNumber - first) % stride == 0
        case .last:
            return lineNumber == lineCount
        case .regex(let pattern, let extendedRegex):
            do {
                let regex = try NSRegularExpression(pattern: MSPPOSIXSedRegex.pattern(for: pattern, extended: extendedRegex))
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return regex.firstMatch(in: line, options: [], range: range) != nil
            } catch {
                throw MSPPOSIXSedError.usage("sed: invalid address regex: \(error.localizedDescription)")
            }
        }
    }
}

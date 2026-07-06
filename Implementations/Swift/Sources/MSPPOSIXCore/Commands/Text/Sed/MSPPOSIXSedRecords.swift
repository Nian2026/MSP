import Foundation

extension MSPPOSIXSedRunner {
    struct SedTextRecord {
        var text: String
        var terminated: Bool
    }

    struct SedOutputRecord {
        var text: String
        var terminated: Bool
    }

    static func sedTextRecords(_ text: String) -> [SedTextRecord] {
        var records: [SedTextRecord] = []
        var current = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                records.append(SedTextRecord(text: current, terminated: true))
                current.removeAll(keepingCapacity: true)
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        let endsWithLineFeed = text.unicodeScalars.last?.value == 0x0A
        if !current.isEmpty || (!text.isEmpty && !endsWithLineFeed) {
            records.append(SedTextRecord(text: current, terminated: false))
        }
        return records
    }

    static func joinedSedOutput(_ records: [SedOutputRecord]) -> String {
        var output = ""
        for record in records {
            output += record.text
            if record.terminated {
                output.append("\n")
            }
        }
        return output
    }

    static func listEscapedLine(_ line: String) -> String {
        var escaped = ""
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 9:
                escaped += "\\t"
            case 32...126:
                escaped += String(scalar)
            default:
                escaped += String(format: "\\%03o", scalar.value)
            }
        }
        return escaped + "$"
    }
}

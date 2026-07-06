import Foundation

enum MSPPOSIXAwkTypeCoercion {
    static func number(_ value: String) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func string(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    static func isTruthy(_ value: String) -> Bool {
        if let number = exactNumber(value) {
            return number != 0
        }
        return !value.isEmpty
    }

    static func looksNumeric(_ value: String) -> Bool {
        exactNumber(value) != nil
    }

    static func exactNumber(_ value: String) -> Double? {
        Double(value)
    }
}

import Foundation

extension MSPResponsesStreamingModelClient {
    static func value(at path: [String], in json: [String: Any]) -> Any? {
        var current: Any = json
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    static func stringValue(at path: [String], in json: [String: Any]) -> String? {
        value(at: path, in: json) as? String
    }

    static func intValue(at path: [String], in json: [String: Any]) -> Int? {
        let current = value(at: path, in: json)
        if let int = current as? Int {
            return int
        }
        if let number = current as? NSNumber {
            return number.intValue
        }
        if let string = current as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

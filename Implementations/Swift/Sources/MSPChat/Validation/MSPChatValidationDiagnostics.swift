import Foundation

extension MSPChatValidationRun {
    mutating func requireStringField(_ field: String, in object: [String: Any], code: String, path: String, line: Int) {
        if string(object[field]) == nil {
            error(code, "Projection record requires \(field).", path: path, line: line)
        }
    }

    mutating func requireDictionaryField(_ field: String, in object: [String: Any], code: String, path: String, line: Int) {
        if dictionary(object[field]) == nil {
            error(code, "Projection record requires \(field).", path: path, line: line)
        }
    }

    mutating func checkProductPrivateKeys(in object: [String: Any], path: String, line: Int?) {
        for key in object.keys {
            let lower = key.lowercased()
            if lower.contains("codex") || lower.contains("readex") {
                warning("product-private-key", "Standard package data should avoid product-private key \"\(key)\".", path: path, line: line)
            }
            if let nested = object[key] as? [String: Any] {
                checkProductPrivateKeys(in: nested, path: path, line: line)
            } else if let nestedArray = object[key] as? [[String: Any]] {
                for nested in nestedArray {
                    checkProductPrivateKeys(in: nested, path: path, line: line)
                }
            }
        }
    }

    mutating func error(_ code: String, _ message: String, path: String, line: Int? = nil, eventID: String? = nil) {
        diagnostics.append(MSPChatDiagnostic(severity: .error, code: code, message: message, path: path, line: line, eventID: eventID))
    }

    mutating func warning(_ code: String, _ message: String, path: String, line: Int? = nil, eventID: String? = nil) {
        diagnostics.append(MSPChatDiagnostic(severity: .warning, code: code, message: message, path: path, line: line, eventID: eventID))
    }

    func relativePath(_ url: URL) -> String {
        let packagePath = packageURL.path
        let path = url.path
        if path == packagePath {
            return packageURL.lastPathComponent
        }
        if path.hasPrefix(packagePath + "/") {
            return String(path.dropFirst(packagePath.count + 1))
        }
        return path
    }

    func messageAssociationKey(_ event: MSPChatTimelineValidationEvent) -> String? {
        string(event.envelope["correlation_id"])
            ?? string(event.payload["message_id"])
            ?? string(event.payload["target_message_id"])
    }

    func commandID(_ event: MSPChatTimelineValidationEvent) -> String? {
        string(event.payload["command_id"])
            ?? string(event.envelope["call_id"])
            ?? string(event.envelope["correlation_id"])
    }

    func callID(_ event: MSPChatTimelineValidationEvent) -> String? {
        string(event.envelope["call_id"])
            ?? string(event.payload["call_id"])
            ?? string(event.envelope["correlation_id"])
    }

    func string(_ value: Any?) -> String? {
        value as? String
    }

    func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    func stringArray(_ value: Any?) -> [String]? {
        value as? [String]
    }

    func intArray(_ value: Any?) -> [Int]? {
        if let values = value as? [Int] {
            return values
        }
        if let values = value as? [NSNumber] {
            return values.map { $0.intValue }
        }
        if let values = value as? [Any] {
            var result: [Int] = []
            for value in values {
                guard let intValue = int(value) else {
                    return nil
                }
                result.append(intValue)
            }
            return result
        }
        return nil
    }

    func arrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }
}

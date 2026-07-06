import Foundation

enum ExampleChatRuntimeJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ExampleChatRuntimeJSONValue])
    case array([ExampleChatRuntimeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ExampleChatRuntimeJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ExampleChatRuntimeJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(ExampleChatRuntimeJSONValue.self, from: data)
    }

    init(jsonObject value: Any) throws {
        if value is NSNull {
            self = .null
        } else if let value = value as? String {
            self = .string(value)
        } else if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        } else if let value = value as? [String: Any] {
            var object: [String: ExampleChatRuntimeJSONValue] = [:]
            for (key, item) in value {
                object[key] = try ExampleChatRuntimeJSONValue(jsonObject: item)
            }
            self = .object(object)
        } else if let value = value as? [Any] {
            self = .array(try value.map { try ExampleChatRuntimeJSONValue(jsonObject: $0) })
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unsupported JSON object value: \(type(of: value))"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: ExampleChatRuntimeJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [ExampleChatRuntimeJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}

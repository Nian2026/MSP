import CoreFoundation
import Foundation

public enum MSPChatJSONValue: Equatable, Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: MSPChatJSONValue])
    case array([MSPChatJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MSPChatJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MSPChatJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var intValue: Int? {
        if case let .int(value) = self {
            return value
        }
        if case let .double(value) = self, value.rounded(.towardZero) == value {
            return Int(value)
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [MSPChatJSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    public var objectValue: [String: MSPChatJSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    public static func fromAny(_ value: Any) throws -> MSPChatJSONValue {
        if value is NSNull {
            return .null
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let type = String(cString: value.objCType)
            if ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) {
                return .int(value.intValue)
            }
            return .double(value.doubleValue)
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? Int {
            return .int(value)
        }
        if let value = value as? Double {
            return .double(value)
        }
        if let value = value as? [Any] {
            return .array(try value.map { try MSPChatJSONValue.fromAny($0) })
        }
        if let value = value as? [String: Any] {
            return .object(try value.mapValues { try MSPChatJSONValue.fromAny($0) })
        }
        throw MSPChatError.invalidJSON("Unsupported JSON value \(type(of: value)).")
    }

    public func toAny() -> Any {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues { $0.toAny() }
        case let .array(value):
            return value.map { $0.toAny() }
        case .null:
            return NSNull()
        }
    }
}

extension MSPChatJSONValue {
    public var stringArrayValue: [String]? {
        guard let arrayValue else {
            return nil
        }
        let values = arrayValue.compactMap(\.stringValue)
        return values.count == arrayValue.count ? values : nil
    }
}

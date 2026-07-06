import MSPAgentBridge
import MSPChat

extension MSPAgentJSONValue {
    func chatJSONValue() throws -> MSPChatJSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .number(let value):
            guard value.isFinite else {
                throw MSPAgentChatStoreError.nonFiniteNumber(value)
            }
            if value.rounded(.towardZero) == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return .int(Int(value))
            }
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .object(let value):
            return .object(try value.mapValues { try $0.chatJSONValue() })
        case .array(let value):
            return .array(try value.map { try $0.chatJSONValue() })
        case .null:
            return .null
        }
    }
}

extension MSPChatJSONValue {
    func agentJSONValue() throws -> MSPAgentJSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .number(Double(value))
        case .double(let value):
            guard value.isFinite else {
                throw MSPAgentChatStoreError.nonFiniteNumber(value)
            }
            return .number(value)
        case .bool(let value):
            return .bool(value)
        case .object(let value):
            return .object(try value.mapValues { try $0.agentJSONValue() })
        case .array(let value):
            return .array(try value.map { try $0.agentJSONValue() })
        case .null:
            return .null
        }
    }
}

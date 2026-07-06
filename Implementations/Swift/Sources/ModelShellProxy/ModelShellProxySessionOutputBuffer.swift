import Foundation

struct ModelShellProxySessionOutputBuffer: Sendable {
    static let defaultMaximumRetainedBytes = 1024 * 1024

    private let maximumRetainedBytes: Int
    private let headBudget: Int
    private let tailBudget: Int
    private var head = Data()
    private var tail = Data()

    init(maximumRetainedBytes: Int = Self.configuredMaximumRetainedBytes()) {
        let maximumRetainedBytes = max(0, maximumRetainedBytes)
        self.maximumRetainedBytes = maximumRetainedBytes
        self.headBudget = maximumRetainedBytes / 2
        self.tailBudget = maximumRetainedBytes - (maximumRetainedBytes / 2)
    }

    var retainedByteCount: Int {
        head.count + tail.count
    }

    var isEmpty: Bool {
        head.isEmpty && tail.isEmpty
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty, maximumRetainedBytes > 0 else {
            return
        }

        var remaining = data
        if head.count < headBudget {
            let availableHeadBytes = headBudget - head.count
            if remaining.count <= availableHeadBytes {
                head.append(remaining)
                return
            }
            head.append(remaining.prefix(availableHeadBytes))
            remaining.removeFirst(availableHeadBytes)
        }

        appendToTail(remaining)
    }

    mutating func drain() -> Data {
        var output = Data()
        output.reserveCapacity(retainedByteCount)
        output.append(head)
        output.append(tail)
        head = Data()
        tail = Data()
        return output
    }

    private mutating func appendToTail(_ data: Data) {
        guard !data.isEmpty, tailBudget > 0 else {
            return
        }
        if data.count >= tailBudget {
            tail = Data(data.suffix(tailBudget))
            return
        }
        tail.append(data)
        if tail.count > tailBudget {
            tail.removeFirst(tail.count - tailBudget)
        }
    }

    private static func configuredMaximumRetainedBytes() -> Int {
        let environment = ProcessInfo.processInfo.environment
        guard let rawValue = environment["MSP_EXEC_SESSION_OUTPUT_MAX_BYTES"],
              let parsed = Int(rawValue),
              parsed >= 0 else {
            return defaultMaximumRetainedBytes
        }
        return parsed
    }
}

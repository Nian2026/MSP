actor MSPAgentChatSessionWriteQueue {
    func run<T: Sendable>(_ operation: @Sendable () throws -> T) rethrows -> T {
        try operation()
    }
}

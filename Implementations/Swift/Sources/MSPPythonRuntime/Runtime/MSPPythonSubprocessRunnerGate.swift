import Foundation
import MSPCore

final class MSPPythonSubprocessRunnerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(
        _ body: @Sendable () async -> MSPCommandResult
    ) async -> MSPCommandResult {
        await acquire()
        defer {
            release()
        }
        return await body()
    }

    private func acquire() async {
        if lock.withLock({
            if isAvailable {
                isAvailable = false
                return true
            }
            return false
        }) {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isAvailable {
                    isAvailable = false
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func release() {
        let next = lock.withLock {
            if waiters.isEmpty {
                isAvailable = true
                return nil as CheckedContinuation<Void, Never>?
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

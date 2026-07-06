import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


struct StaticCompactionHookRuntime: MSPCompactionLifecycleHookRuntime {
    var preOutcome: MSPCompactionHookOutcome
    var postOutcome: MSPCompactionHookOutcome

    init(
        preOutcome: MSPCompactionHookOutcome = .continue,
        postOutcome: MSPCompactionHookOutcome = .continue
    ) {
        self.preOutcome = preOutcome
        self.postOutcome = postOutcome
    }

    func preCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        preOutcome
    }

    func postCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        postOutcome
    }
}

actor RecordingCompactionHookRuntime: MSPCompactionLifecycleHookRuntime {
    private var preCompactCount = 0
    private var postCompactCount = 0
    private let preOutcome: MSPCompactionHookOutcome
    private let postOutcome: MSPCompactionHookOutcome

    init(
        preOutcome: MSPCompactionHookOutcome = .continue,
        postOutcome: MSPCompactionHookOutcome = .continue
    ) {
        self.preOutcome = preOutcome
        self.postOutcome = postOutcome
    }

    func preCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        preCompactCount += 1
        return preOutcome
    }

    func postCompact(operation: MSPCompactionOperation) async -> MSPCompactionHookOutcome {
        postCompactCount += 1
        return postOutcome
    }

    func counts() -> (preCompact: Int, postCompact: Int) {
        (preCompactCount, postCompactCount)
    }
}

actor RecordingCompactionPersistenceAdapter: MSPCompactionPersistenceAdapter {
    private var installedCheckpoints: [MSPCompactionCheckpoint] = []

    func install(checkpoint: MSPCompactionCheckpoint) async throws {
        installedCheckpoints.append(checkpoint)
    }

    func checkpoints() -> [MSPCompactionCheckpoint] {
        installedCheckpoints
    }
}

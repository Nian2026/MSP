import Foundation

struct MSPCompactionSourceRange: Codable, Hashable, Sendable {
    var startID: String?
    var endID: String?
    var sourceHash: String?

    init(
        startID: String? = nil,
        endID: String? = nil,
        sourceHash: String? = nil
    ) {
        self.startID = startID
        self.endID = endID
        self.sourceHash = sourceHash
    }
}

struct MSPCompactionWindowLineage: Codable, Hashable, Sendable {
    var windowNumber: Int
    var firstWindowID: String?
    var previousWindowID: String?
    var currentWindowID: String?

    enum CodingKeys: String, CodingKey {
        case windowNumber
        case firstWindowID
        case previousWindowID
        case currentWindowID
        case snakeWindowNumber = "window_number"
        case snakeFirstWindowID = "first_window_id"
        case snakePreviousWindowID = "previous_window_id"
        case snakeWindowID = "window_id"
    }

    init(
        windowNumber: Int,
        firstWindowID: String?,
        previousWindowID: String?,
        currentWindowID: String?
    ) {
        self.windowNumber = max(0, windowNumber)
        self.firstWindowID = firstWindowID
        self.previousWindowID = previousWindowID
        self.currentWindowID = currentWindowID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currentWindowID = try container.decodeIfPresent(String.self, forKey: .currentWindowID)
            ?? (try? container.decodeIfPresent(String.self, forKey: .snakeWindowID)) ?? nil
        let legacyWindowNumber = try? container.decodeIfPresent(Int.self, forKey: .snakeWindowID)
        let windowNumber = try container.decodeIfPresent(Int.self, forKey: .windowNumber)
            ?? container.decodeIfPresent(Int.self, forKey: .snakeWindowNumber)
            ?? legacyWindowNumber
            ?? 0
        self.init(
            windowNumber: windowNumber,
            firstWindowID: try container.decodeIfPresent(String.self, forKey: .firstWindowID)
                ?? container.decodeIfPresent(String.self, forKey: .snakeFirstWindowID),
            previousWindowID: try container.decodeIfPresent(String.self, forKey: .previousWindowID)
                ?? container.decodeIfPresent(String.self, forKey: .snakePreviousWindowID),
            currentWindowID: currentWindowID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowNumber, forKey: .windowNumber)
        try container.encodeIfPresent(firstWindowID, forKey: .firstWindowID)
        try container.encodeIfPresent(previousWindowID, forKey: .previousWindowID)
        try container.encodeIfPresent(currentWindowID, forKey: .currentWindowID)
    }
}

struct MSPContextWindowLineageState: Codable, Hashable, Sendable {
    private(set) var windowNumber: Int
    private(set) var firstWindowID: String
    private(set) var previousWindowID: String?
    private(set) var currentWindowID: String

    init(
        windowNumber: Int = 0,
        firstWindowID: String = UUID().uuidString,
        previousWindowID: String? = nil,
        currentWindowID: String? = nil
    ) {
        self.windowNumber = max(0, windowNumber)
        self.firstWindowID = firstWindowID
        self.previousWindowID = previousWindowID
        self.currentWindowID = currentWindowID ?? firstWindowID
    }

    var lineage: MSPCompactionWindowLineage {
        MSPCompactionWindowLineage(
            windowNumber: windowNumber,
            firstWindowID: firstWindowID,
            previousWindowID: previousWindowID,
            currentWindowID: currentWindowID
        )
    }

    mutating func advance(nextWindowID: String = UUID().uuidString) -> MSPCompactionWindowLineage {
        windowNumber += 1
        previousWindowID = currentWindowID
        currentWindowID = nextWindowID
        return lineage
    }
}

enum MSPCompactionReplayMode: String, Codable, Hashable, Sendable {
    case exact
    case rebuildLegacy = "rebuild_legacy"
    case resumeDegraded = "resume_degraded"
}

struct MSPCompactionCheckpoint: Codable, Hashable, Sendable {
    var checkpointID: String
    var sourceRange: MSPCompactionSourceRange
    var replacementHistory: [MSPAgentJSONValue]?
    var replacementHistoryRef: String?
    var replacementHistoryHash: String?
    var sourceTransportRef: String?
    var summaryText: String?
    var summaryRef: String?
    var lineage: MSPCompactionWindowLineage
    var replayMode: MSPCompactionReplayMode

    init(
        checkpointID: String = UUID().uuidString,
        sourceRange: MSPCompactionSourceRange,
        replacementHistory: [MSPAgentJSONValue]? = nil,
        replacementHistoryRef: String? = nil,
        replacementHistoryHash: String? = nil,
        sourceTransportRef: String? = nil,
        summaryText: String? = nil,
        summaryRef: String? = nil,
        lineage: MSPCompactionWindowLineage,
        replayMode: MSPCompactionReplayMode = .exact
    ) {
        self.checkpointID = checkpointID
        self.sourceRange = sourceRange
        self.replacementHistory = replacementHistory
        self.replacementHistoryRef = replacementHistoryRef
        self.replacementHistoryHash = replacementHistoryHash
        self.sourceTransportRef = sourceTransportRef
        self.summaryText = summaryText
        self.summaryRef = summaryRef
        self.lineage = lineage
        self.replayMode = replayMode
    }
}

struct MSPCompactionReplayResult: Hashable, Sendable {
    var checkpointID: String?
    var modelVisibleHistory: [MSPAgentJSONValue]
    var lineage: MSPCompactionWindowLineage?
    var replayMode: MSPCompactionReplayMode

    init(
        checkpointID: String?,
        modelVisibleHistory: [MSPAgentJSONValue],
        lineage: MSPCompactionWindowLineage?,
        replayMode: MSPCompactionReplayMode
    ) {
        self.checkpointID = checkpointID
        self.modelVisibleHistory = modelVisibleHistory
        self.lineage = lineage
        self.replayMode = replayMode
    }
}

enum MSPCompactionWorldStateReplayKind: String, Codable, Hashable, Sendable {
    case compaction
    case fullSnapshot = "full"
    case patch
}

struct MSPCompactionWorldStateReplayItem: Codable, Hashable, Sendable {
    var kind: MSPCompactionWorldStateReplayKind
    var state: MSPAgentJSONValue?

    static func compactionBoundary() -> Self {
        Self(kind: .compaction, state: nil)
    }

    static func fullSnapshot(_ state: MSPAgentJSONValue) -> Self {
        Self(kind: .fullSnapshot, state: state)
    }

    static func patch(_ state: MSPAgentJSONValue) -> Self {
        Self(kind: .patch, state: state)
    }
}

enum MSPCompactionWorldStateReplayDegradedReason: String, Codable, Hashable, Sendable {
    case invalidFullSnapshot = "invalid_full_snapshot"
    case patchWithoutBaseline = "patch_without_baseline"
    case patchApplicationFailed = "patch_application_failed"
}

struct MSPCompactionWorldStateReplayDegradation: Codable, Hashable, Sendable {
    var index: Int
    var reason: MSPCompactionWorldStateReplayDegradedReason
}

struct MSPCompactionWorldStateReplayResult: Hashable, Sendable {
    var baseline: MSPAgentJSONValue?
    var degradations: [MSPCompactionWorldStateReplayDegradation]

    var isDegraded: Bool {
        !degradations.isEmpty
    }
}

struct MSPCompactionTurnContextSnapshot: Codable, Hashable, Sendable {
    var turnID: String?
    var cwd: String?
    var workspaceRoots: [String]?
    var currentDate: String?
    var timezone: String?
    var approvalPolicy: String?
    var sandboxPolicy: String?
    var permissionProfile: MSPAgentJSONValue?
    var network: MSPAgentJSONValue?
    var fileSystemSandboxPolicy: MSPAgentJSONValue?
    var model: String
    var compHash: String?
    var realtimeActive: Bool?
    var payload: MSPAgentJSONValue?

    init(
        turnID: String? = nil,
        cwd: String? = nil,
        workspaceRoots: [String]? = nil,
        currentDate: String? = nil,
        timezone: String? = nil,
        approvalPolicy: String? = nil,
        sandboxPolicy: String? = nil,
        permissionProfile: MSPAgentJSONValue? = nil,
        network: MSPAgentJSONValue? = nil,
        fileSystemSandboxPolicy: MSPAgentJSONValue? = nil,
        model: String,
        compHash: String? = nil,
        realtimeActive: Bool? = nil,
        payload: MSPAgentJSONValue? = nil
    ) {
        self.turnID = turnID
        self.cwd = cwd
        self.workspaceRoots = workspaceRoots
        self.currentDate = currentDate
        self.timezone = timezone
        self.approvalPolicy = approvalPolicy
        self.sandboxPolicy = sandboxPolicy
        self.permissionProfile = permissionProfile
        self.network = network
        self.fileSystemSandboxPolicy = fileSystemSandboxPolicy
        self.model = model
        self.compHash = compHash
        self.realtimeActive = realtimeActive
        self.payload = payload
    }
}

struct MSPCompactionPreviousTurnSettings: Codable, Hashable, Sendable {
    var model: String
    var compHash: String?
    var realtimeActive: Bool?
}

enum MSPCompactionReferenceContextReplayState: Hashable, Sendable {
    case neverSet
    case cleared
    case latest(MSPCompactionTurnContextSnapshot)
}

enum MSPCompactionReferenceContextReplayItem: Hashable, Sendable {
    case turnStarted(id: String)
    case turnComplete(id: String)
    case turnAborted(id: String?)
    case userMessage
    case responseItemUserTurnBoundary
    case interAgentCommunication
    case turnContext(MSPCompactionTurnContextSnapshot)
    case compaction
    case rollback(userTurns: Int)
    case ignored
}

struct MSPCompactionReferenceContextReplayResult: Hashable, Sendable {
    var previousTurnSettings: MSPCompactionPreviousTurnSettings?
    var referenceContextState: MSPCompactionReferenceContextReplayState

    var referenceContextItem: MSPCompactionTurnContextSnapshot? {
        if case let .latest(snapshot) = referenceContextState {
            return snapshot
        }
        return nil
    }
}

enum MSPCompactionReplayError: Error, Equatable, Sendable {
    case missingReplacementHistory(checkpointID: String)
    case replacementHistoryHashMismatch(checkpointID: String)
    case unsupportedReplayMode(checkpointID: String, mode: MSPCompactionReplayMode)
}

enum MSPCompactionCheckpointReplay {
    static func rebuildExactModelVisibleHistory(
        from checkpoint: MSPCompactionCheckpoint,
        suffixItems: [MSPAgentJSONValue] = []
    ) throws -> MSPCompactionReplayResult {
        guard checkpoint.replayMode == .exact else {
            throw MSPCompactionReplayError.unsupportedReplayMode(
                checkpointID: checkpoint.checkpointID,
                mode: checkpoint.replayMode
            )
        }
        guard let replacementHistory = checkpoint.replacementHistory else {
            throw MSPCompactionReplayError.missingReplacementHistory(
                checkpointID: checkpoint.checkpointID
            )
        }
        if let expectedHash = checkpoint.replacementHistoryHash {
            let actualHash = try MSPCompactionCheckpointBuilder.fingerprint(
                replacementHistory
            )
            guard actualHash == expectedHash else {
                throw MSPCompactionReplayError.replacementHistoryHashMismatch(
                    checkpointID: checkpoint.checkpointID
                )
            }
        }
        return MSPCompactionReplayResult(
            checkpointID: checkpoint.checkpointID,
            modelVisibleHistory: replacementHistory + suffixItems,
            lineage: checkpoint.lineage,
            replayMode: .exact
        )
    }

    static func rebuildLegacyModelVisibleHistory(
        from checkpoint: MSPCompactionCheckpoint,
        priorHistory: [MSPAgentJSONValue],
        suffixItems: [MSPAgentJSONValue] = []
    ) throws -> MSPCompactionReplayResult {
        guard checkpoint.replayMode == .rebuildLegacy else {
            throw MSPCompactionReplayError.unsupportedReplayMode(
                checkpointID: checkpoint.checkpointID,
                mode: checkpoint.replayMode
            )
        }
        let rebuilt = MSPCompactionHistoryRewriter.legacyCompactedHistory(
            from: priorHistory,
            summaryText: checkpoint.summaryText ?? ""
        )
        return MSPCompactionReplayResult(
            checkpointID: checkpoint.checkpointID,
            modelVisibleHistory: rebuilt + suffixItems,
            lineage: checkpoint.lineage,
            replayMode: .rebuildLegacy
        )
    }

    static func replayWorldStateChronologically(
        _ items: [MSPCompactionWorldStateReplayItem]
    ) -> MSPCompactionWorldStateReplayResult {
        var baseline: MSPAgentJSONValue?
        var degradations: [MSPCompactionWorldStateReplayDegradation] = []

        for (index, item) in items.enumerated() {
            switch item.kind {
            case .compaction:
                baseline = nil

            case .fullSnapshot:
                guard let state = item.state, state.objectValue != nil else {
                    baseline = nil
                    degradations.append(MSPCompactionWorldStateReplayDegradation(
                        index: index,
                        reason: .invalidFullSnapshot
                    ))
                    continue
                }
                baseline = state

            case .patch:
                guard var current = baseline else {
                    degradations.append(MSPCompactionWorldStateReplayDegradation(
                        index: index,
                        reason: .patchWithoutBaseline
                    ))
                    continue
                }
                guard let patch = item.state else {
                    baseline = nil
                    degradations.append(MSPCompactionWorldStateReplayDegradation(
                        index: index,
                        reason: .patchApplicationFailed
                    ))
                    continue
                }
                Self.applyMergePatch(patch, to: &current)
                guard current.objectValue != nil else {
                    baseline = nil
                    degradations.append(MSPCompactionWorldStateReplayDegradation(
                        index: index,
                        reason: .patchApplicationFailed
                    ))
                    continue
                }
                baseline = current
            }
        }

        return MSPCompactionWorldStateReplayResult(
            baseline: baseline,
            degradations: degradations
        )
    }

    static func replayReferenceContext(
        fromChronologicalItems items: [MSPCompactionReferenceContextReplayItem]
    ) -> MSPCompactionReferenceContextReplayResult {
        var base = ReferenceReplayAccumulator()
        var activeSegment: ReferenceReplaySegment?

        for item in items.enumerated().reversed().map(\.element) {
            switch item {
            case .compaction:
                var segment = activeSegment ?? ReferenceReplaySegment()
                if segment.referenceContextState == .neverSet {
                    segment.referenceContextState = .cleared
                }
                activeSegment = segment

            case .rollback(let userTurns):
                base.pendingRollbackUserTurns += max(0, userTurns)

            case .turnComplete(let id):
                var segment = activeSegment ?? ReferenceReplaySegment()
                if segment.turnID == nil {
                    segment.turnID = id
                }
                activeSegment = segment

            case .turnAborted(let id):
                var segment = activeSegment ?? ReferenceReplaySegment()
                if segment.turnID == nil, let id {
                    segment.turnID = id
                }
                activeSegment = segment

            case .userMessage, .responseItemUserTurnBoundary, .interAgentCommunication:
                var segment = activeSegment ?? ReferenceReplaySegment()
                segment.countsAsUserTurn = true
                activeSegment = segment

            case .turnContext(let snapshot):
                var segment = activeSegment ?? ReferenceReplaySegment()
                if segment.turnID == nil {
                    segment.turnID = snapshot.turnID
                }
                if turnIDsAreCompatible(segment.turnID, snapshot.turnID) {
                    segment.previousTurnSettings = MSPCompactionPreviousTurnSettings(
                        model: snapshot.model,
                        compHash: snapshot.compHash,
                        realtimeActive: snapshot.realtimeActive
                    )
                    if segment.referenceContextState == .neverSet {
                        segment.referenceContextState = .latest(snapshot)
                    }
                }
                activeSegment = segment

            case .turnStarted(let id):
                guard var segment = activeSegment else {
                    break
                }
                if turnIDsAreCompatible(segment.turnID, id) {
                    segment.turnID = segment.turnID ?? id
                    base.finalize(segment)
                    activeSegment = nil
                }

            case .ignored:
                break
            }

            if base.hasHydratedReferenceContextAndSettings {
                break
            }
        }

        if let activeSegment {
            base.finalize(activeSegment)
        }

        return MSPCompactionReferenceContextReplayResult(
            previousTurnSettings: base.previousTurnSettings,
            referenceContextState: base.referenceContextState
        )
    }

    private static func applyMergePatch(
        _ patch: MSPAgentJSONValue,
        to target: inout MSPAgentJSONValue
    ) {
        guard let patchObject = patch.objectValue else {
            target = patch
            return
        }

        var targetObject = target.objectValue ?? [:]
        for (key, value) in patchObject {
            if value == .null {
                targetObject.removeValue(forKey: key)
            } else {
                var child = targetObject[key] ?? .null
                applyMergePatch(value, to: &child)
                targetObject[key] = child
            }
        }
        target = .object(targetObject)
    }

    private static func turnIDsAreCompatible(_ activeTurnID: String?, _ itemTurnID: String?) -> Bool {
        guard let activeTurnID else {
            return true
        }
        guard let itemTurnID else {
            return true
        }
        return activeTurnID == itemTurnID
    }
}

private struct ReferenceReplaySegment: Sendable {
    var turnID: String?
    var countsAsUserTurn = false
    var previousTurnSettings: MSPCompactionPreviousTurnSettings?
    var referenceContextState: MSPCompactionReferenceContextReplayState = .neverSet
}

private struct ReferenceReplayAccumulator: Sendable {
    var pendingRollbackUserTurns = 0
    var previousTurnSettings: MSPCompactionPreviousTurnSettings?
    var referenceContextState: MSPCompactionReferenceContextReplayState = .neverSet

    var hasHydratedReferenceContextAndSettings: Bool {
        previousTurnSettings != nil && referenceContextState != .neverSet
    }

    mutating func finalize(_ segment: ReferenceReplaySegment) {
        if pendingRollbackUserTurns > 0 {
            if segment.countsAsUserTurn {
                pendingRollbackUserTurns -= 1
            }
            return
        }

        if previousTurnSettings == nil, segment.countsAsUserTurn {
            previousTurnSettings = segment.previousTurnSettings
        }

        if referenceContextState == .neverSet,
           segment.countsAsUserTurn || segment.referenceContextState == .cleared {
            referenceContextState = segment.referenceContextState
        }
    }
}

protocol MSPCompactionPersistenceAdapter: Sendable {
    func install(checkpoint: MSPCompactionCheckpoint) async throws
}

struct MSPNoopCompactionPersistenceAdapter: MSPCompactionPersistenceAdapter {
    func install(checkpoint: MSPCompactionCheckpoint) async throws {}
}

enum MSPCompactionCheckpointBuilder {
    static func checkpoint(
        checkpointID: String,
        sourceItems: [MSPAgentJSONValue],
        replacementHistory: [MSPAgentJSONValue],
        summaryRef: String?,
        lineage: MSPCompactionWindowLineage
    ) throws -> MSPCompactionCheckpoint {
        MSPCompactionCheckpoint(
            checkpointID: checkpointID,
            sourceRange: MSPCompactionSourceRange(
                sourceHash: try fingerprint(sourceItems)
            ),
            replacementHistory: replacementHistory,
            replacementHistoryRef: nil,
            replacementHistoryHash: try fingerprint(replacementHistory),
            sourceTransportRef: nil,
            summaryRef: summaryRef,
            lineage: lineage,
            replayMode: .exact
        )
    }

    static func fingerprint(_ values: [MSPAgentJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        return "fnv1a64:\(fnv1a64Hex(data))"
    }

    private static func fnv1a64Hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

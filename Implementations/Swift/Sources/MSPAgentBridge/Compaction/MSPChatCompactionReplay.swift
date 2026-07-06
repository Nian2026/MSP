import Foundation

struct MSPChatCompactionPackageSnapshot: Hashable, Sendable {
    var timeline: [MSPChatCompactionTimelineEvent]
    var journal: [MSPChatCompactionJournalEntry]
    var blobs: [String: [MSPAgentJSONValue]]
    var modelContextProjection: [MSPAgentJSONValue]?

    init(
        timeline: [MSPChatCompactionTimelineEvent],
        journal: [MSPChatCompactionJournalEntry] = [],
        blobs: [String: [MSPAgentJSONValue]] = [:],
        modelContextProjection: [MSPAgentJSONValue]? = nil
    ) {
        self.timeline = timeline
        self.journal = journal
        self.blobs = blobs
        self.modelContextProjection = modelContextProjection
    }

    func forkedPrefix(throughTimelineIndex index: Int) -> Self {
        let end = min(max(index + 1, 0), timeline.count)
        return Self(
            timeline: Array(timeline.prefix(end)),
            journal: journal,
            blobs: blobs,
            modelContextProjection: nil
        )
    }
}

enum MSPChatCompactionTimelineEvent: Hashable, Sendable {
    case durableCompactionCheckpoint(MSPCompactionCheckpoint)
    case modelVisibleSuffixItem(MSPAgentJSONValue)
    case worldState(MSPCompactionWorldStateReplayItem)
    case referenceContext(MSPCompactionReferenceContextReplayItem)
    case rollback(userTurns: Int)
    case ignored
}

struct MSPChatCompactionJournalEntry: Hashable, Sendable {
    var ref: String
    var sourceTransport: MSPAgentJSONValue?
    var replacementHistory: [MSPAgentJSONValue]?

    init(
        ref: String,
        sourceTransport: MSPAgentJSONValue? = nil,
        replacementHistory: [MSPAgentJSONValue]? = nil
    ) {
        self.ref = ref
        self.sourceTransport = sourceTransport
        self.replacementHistory = replacementHistory
    }
}

struct MSPChatCompactionReplayResult: Hashable, Sendable {
    var checkpointID: String
    var modelVisibleHistory: [MSPAgentJSONValue]
    var lineage: MSPCompactionWindowLineage
    var replayMode: MSPCompactionReplayMode
    var worldState: MSPCompactionWorldStateReplayResult
    var referenceContext: MSPCompactionReferenceContextReplayResult
    var usedModelContextProjection: Bool
}

enum MSPChatCompactionReplayError: Error, Equatable, Sendable {
    case missingCheckpoint
    case missingReplacementHistory(checkpointID: String, ref: String?)
    case replacementHistoryHashMismatch(checkpointID: String)
    case unsupportedReplayMode(checkpointID: String, mode: MSPCompactionReplayMode)
}

enum MSPChatCompactionReplay {
    static func rebuildModelContext(
        from package: MSPChatCompactionPackageSnapshot
    ) throws -> MSPChatCompactionReplayResult {
        let analysis = try replayAnalysis(for: package.timeline)
        let checkpointIndex = analysis.selectedCheckpointIndex

        guard case var .durableCompactionCheckpoint(checkpoint) = package.timeline[checkpointIndex] else {
            preconditionFailure("checkpoint index must point at a checkpoint")
        }

        let suffixItems = package.timeline.enumerated().compactMap { index, event in
            if index > checkpointIndex,
               analysis.survivingEventIndexes.contains(index),
               case let .modelVisibleSuffixItem(item) = event {
                return item
            }
            return nil
        }

        let replay: MSPCompactionReplayResult
        do {
            switch checkpoint.replayMode {
            case .exact:
                checkpoint.replacementHistory = try replacementHistory(
                    for: checkpoint,
                    package: package
                )
                replay = try MSPCompactionCheckpointReplay.rebuildExactModelVisibleHistory(
                    from: checkpoint,
                    suffixItems: suffixItems
                )
            case .rebuildLegacy:
                replay = try MSPCompactionCheckpointReplay.rebuildLegacyModelVisibleHistory(
                    from: checkpoint,
                    priorHistory: priorModelVisibleItems(
                        before: checkpointIndex,
                        in: package.timeline,
                        survivingEventIndexes: analysis.survivingEventIndexes
                    ),
                    suffixItems: suffixItems
                )
            case .resumeDegraded:
                throw MSPCompactionReplayError.unsupportedReplayMode(
                    checkpointID: checkpoint.checkpointID,
                    mode: checkpoint.replayMode
                )
            }
        } catch let error as MSPCompactionReplayError {
            throw chatReplayError(from: error)
        }

        var referenceContext = MSPCompactionCheckpointReplay.replayReferenceContext(
            fromChronologicalItems: referenceContextReplayItems(from: analysis.survivingTimeline)
        )
        if checkpoint.replayMode == .rebuildLegacy {
            referenceContext.referenceContextState = .cleared
        }

        return MSPChatCompactionReplayResult(
            checkpointID: checkpoint.checkpointID,
            modelVisibleHistory: replay.modelVisibleHistory,
            lineage: checkpoint.lineage,
            replayMode: replay.replayMode,
            worldState: MSPCompactionCheckpointReplay.replayWorldStateChronologically(
                worldStateReplayItems(from: analysis.survivingTimeline)
            ),
            referenceContext: referenceContext,
            usedModelContextProjection: false
        )
    }

    private static func replayAnalysis(
        for timeline: [MSPChatCompactionTimelineEvent]
    ) throws -> TimelineReplayAnalysis {
        var accumulator = TimelineReplayAccumulator()
        var activeSegment: TimelineReplaySegment?

        func updateActiveSegment(_ update: (inout TimelineReplaySegment) -> Void) {
            var segment = activeSegment ?? TimelineReplaySegment()
            update(&segment)
            activeSegment = segment
        }

        for (index, event) in timeline.enumerated().reversed() {
            switch event {
            case .durableCompactionCheckpoint:
                updateActiveSegment { segment in
                    segment.eventIndexes.append(index)
                    if segment.checkpointIndex == nil {
                        segment.checkpointIndex = index
                    }
                }

            case let .modelVisibleSuffixItem(item):
                updateActiveSegment { segment in
                    segment.eventIndexes.append(index)
                    segment.countsAsUserTurn = segment.countsAsUserTurn
                        || isModelVisibleUserTurnBoundary(item)
                }

            case .worldState:
                updateActiveSegment { segment in
                    segment.eventIndexes.append(index)
                }

            case let .referenceContext(item):
                switch item {
                case .rollback(let userTurns):
                    accumulator.pendingRollbackUserTurns += max(0, userTurns)

                case .turnStarted(let id):
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                        if turnIDsAreCompatible(segment.turnID, id) {
                            segment.turnID = segment.turnID ?? id
                        }
                    }
                    if let segment = activeSegment,
                       turnIDsAreCompatible(segment.turnID, id) {
                        accumulator.finalize(segment)
                        activeSegment = nil
                    }

                case .turnComplete(let id):
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                        if segment.turnID == nil {
                            segment.turnID = id
                        }
                    }

                case .turnAborted(let id):
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                        if segment.turnID == nil, let id {
                            segment.turnID = id
                        }
                    }

                case .userMessage, .responseItemUserTurnBoundary, .interAgentCommunication:
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                        segment.countsAsUserTurn = true
                    }

                case .turnContext(let snapshot):
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                        if segment.turnID == nil {
                            segment.turnID = snapshot.turnID
                        }
                    }

                case .compaction:
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                    }

                case .ignored:
                    updateActiveSegment { segment in
                        segment.eventIndexes.append(index)
                    }
                }

            case .rollback(let userTurns):
                accumulator.pendingRollbackUserTurns += max(0, userTurns)

            case .ignored:
                break
            }
        }

        if let activeSegment {
            accumulator.finalize(activeSegment)
        }

        guard let selectedCheckpointIndex = accumulator.selectedCheckpointIndex else {
            throw MSPChatCompactionReplayError.missingCheckpoint
        }

        let survivingTimeline = timeline.enumerated().compactMap { index, event in
            accumulator.survivingEventIndexes.contains(index) ? event : nil
        }
        return TimelineReplayAnalysis(
            selectedCheckpointIndex: selectedCheckpointIndex,
            survivingEventIndexes: accumulator.survivingEventIndexes,
            survivingTimeline: survivingTimeline
        )
    }

    private static func replacementHistory(
        for checkpoint: MSPCompactionCheckpoint,
        package: MSPChatCompactionPackageSnapshot
    ) throws -> [MSPAgentJSONValue] {
        if let replacementHistory = checkpoint.replacementHistory {
            return replacementHistory
        }

        if let ref = checkpoint.replacementHistoryRef {
            if let journalHistory = package.journal.first(where: { $0.ref == ref })?.replacementHistory {
                return journalHistory
            }
            if let blobHistory = package.blobs[ref] {
                return blobHistory
            }
            throw MSPChatCompactionReplayError.missingReplacementHistory(
                checkpointID: checkpoint.checkpointID,
                ref: ref
            )
        }

        if let ref = checkpoint.sourceTransportRef,
           let journalHistory = package.journal.first(where: { $0.ref == ref })?.replacementHistory {
            return journalHistory
        }

        throw MSPChatCompactionReplayError.missingReplacementHistory(
            checkpointID: checkpoint.checkpointID,
            ref: checkpoint.replacementHistoryRef ?? checkpoint.sourceTransportRef
        )
    }

    private static func priorModelVisibleItems(
        before checkpointIndex: Int,
        in timeline: [MSPChatCompactionTimelineEvent],
        survivingEventIndexes: Set<Int>
    ) -> [MSPAgentJSONValue] {
        timeline.enumerated().compactMap { index, event in
            if index < checkpointIndex,
               survivingEventIndexes.contains(index),
               case let .modelVisibleSuffixItem(item) = event {
                return item
            }
            return nil
        }
    }

    private static func worldStateReplayItems(
        from timeline: [MSPChatCompactionTimelineEvent]
    ) -> [MSPCompactionWorldStateReplayItem] {
        timeline.compactMap { event in
            switch event {
            case .durableCompactionCheckpoint:
                return .compactionBoundary()
            case let .worldState(item):
                return item
            case .modelVisibleSuffixItem, .referenceContext, .rollback, .ignored:
                return nil
            }
        }
    }

    private static func referenceContextReplayItems(
        from timeline: [MSPChatCompactionTimelineEvent]
    ) -> [MSPCompactionReferenceContextReplayItem] {
        timeline.compactMap { event in
            switch event {
            case .durableCompactionCheckpoint:
                return .compaction
            case let .referenceContext(item):
                return item
            case .rollback(let userTurns):
                return .rollback(userTurns: userTurns)
            case .modelVisibleSuffixItem, .worldState, .ignored:
                return nil
            }
        }
    }

    private static func isModelVisibleUserTurnBoundary(_ item: MSPAgentJSONValue) -> Bool {
        guard let object = item.objectValue else {
            return false
        }
        if object["type"]?.stringValue == "agent_message" {
            return true
        }
        guard object["type"]?.stringValue == "message" else {
            return false
        }
        let role = object["role"]?.stringValue
        if role == "user" {
            return !isContextualUserMessage(item)
        }
        if role == "assistant" {
            return isInterAgentAssistantInstruction(item)
        }
        return false
    }

    private static func isContextualUserMessage(_ item: MSPAgentJSONValue) -> Bool {
        let text = messageText(from: item).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("<environment_context>")
            || text.hasPrefix("<user_instructions>")
            || text.hasPrefix("# AGENTS.md")
    }

    private static func isInterAgentAssistantInstruction(_ item: MSPAgentJSONValue) -> Bool {
        let text = messageText(from: item)
        return text.contains("\"trigger_turn\":true")
            || text.contains("\"trigger_turn\": true")
    }

    private static func messageText(from item: MSPAgentJSONValue) -> String {
        guard let content = item.objectValue?["content"]?.arrayValue else {
            return ""
        }
        return content.compactMap { contentItem in
            contentItem.objectValue?["text"]?.stringValue
        }.joined(separator: "\n")
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

    private static func chatReplayError(
        from error: MSPCompactionReplayError
    ) -> MSPChatCompactionReplayError {
        switch error {
        case .missingReplacementHistory(let checkpointID):
            return .missingReplacementHistory(checkpointID: checkpointID, ref: nil)
        case .replacementHistoryHashMismatch(let checkpointID):
            return .replacementHistoryHashMismatch(checkpointID: checkpointID)
        case .unsupportedReplayMode(let checkpointID, let mode):
            return .unsupportedReplayMode(checkpointID: checkpointID, mode: mode)
        }
    }
}

private struct TimelineReplayAnalysis {
    var selectedCheckpointIndex: Int
    var survivingEventIndexes: Set<Int>
    var survivingTimeline: [MSPChatCompactionTimelineEvent]
}

private struct TimelineReplaySegment {
    var turnID: String?
    var countsAsUserTurn = false
    var eventIndexes: [Int] = []
    var checkpointIndex: Int?
}

private struct TimelineReplayAccumulator {
    var pendingRollbackUserTurns = 0
    var selectedCheckpointIndex: Int?
    var survivingEventIndexes: Set<Int> = []

    mutating func finalize(_ segment: TimelineReplaySegment) {
        if pendingRollbackUserTurns > 0 {
            if segment.countsAsUserTurn {
                pendingRollbackUserTurns -= 1
            }
            return
        }

        survivingEventIndexes.formUnion(segment.eventIndexes)
        if selectedCheckpointIndex == nil, let checkpointIndex = segment.checkpointIndex {
            selectedCheckpointIndex = checkpointIndex
        }
    }
}

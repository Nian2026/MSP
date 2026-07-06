import Foundation

actor MSPAgentTurnTranscriptRecorder {
    typealias SnapshotUpdatedHandler = @Sendable ([MSPAgentJSONValue]) async -> Void
    private static let streamedSnapshotDelayNanoseconds: UInt64 = 500_000_000

    private var transcriptAppendItems: [MSPAgentJSONValue]
    private var streamedMessageOrder: [String] = []
    private var streamedMessages: [String: MSPAgentJSONValue] = [:]
    private var hasPendingStreamedSnapshot = false
    private var pendingStreamedSnapshotTask: Task<Void, Never>?
    private var didBuildInterruptedSnapshot = false
    private let onSnapshotUpdated: SnapshotUpdatedHandler?

    init(
        initialItems: [MSPAgentJSONValue],
        onSnapshotUpdated: SnapshotUpdatedHandler? = nil
    ) {
        self.transcriptAppendItems = initialItems
        self.onSnapshotUpdated = onSnapshotUpdated
    }

    func append(_ items: [MSPAgentJSONValue]) async {
        guard !items.isEmpty else {
            return
        }
        discardPendingStreamedSnapshot()
        streamedMessageOrder.removeAll(keepingCapacity: true)
        streamedMessages.removeAll(keepingCapacity: true)
        transcriptAppendItems.append(contentsOf: items)
        await emitSnapshotUpdated()
    }

    func replaceTranscriptAppendItems(_ items: [MSPAgentJSONValue]) async {
        discardPendingStreamedSnapshot()
        streamedMessageOrder.removeAll(keepingCapacity: true)
        streamedMessages.removeAll(keepingCapacity: true)
        transcriptAppendItems = items
        await emitSnapshotUpdated()
    }

    func transcriptAppendItemsSnapshot() -> [MSPAgentJSONValue] {
        transcriptAppendItems + streamedMessageOrder.compactMap { streamedMessages[$0] }
    }

    func updateStreamedMessage(text: String, phase: String) async {
        let trimmedPhase = phase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhase.isEmpty else {
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let removed = streamedMessages.removeValue(forKey: trimmedPhase) != nil
            streamedMessageOrder.removeAll { $0 == trimmedPhase }
            if removed {
                scheduleStreamedSnapshotUpdated()
            }
            return
        }
        if streamedMessages[trimmedPhase] == nil {
            streamedMessageOrder.append(trimmedPhase)
        }
        streamedMessages[trimmedPhase] = .object([
            "type": .string("message"),
            "role": .string("assistant"),
            "phase": .string(trimmedPhase),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text)
                ])
            ])
        ])
        scheduleStreamedSnapshotUpdated()
    }

    func interruptedTranscriptAppendItems(
        additionalItemsBeforeMarker: [MSPAgentJSONValue] = []
    ) async -> [MSPAgentJSONValue] {
        discardPendingStreamedSnapshot()
        guard !didBuildInterruptedSnapshot else {
            return []
        }
        didBuildInterruptedSnapshot = true
        let streamedItems = streamedMessageOrder.compactMap { streamedMessages[$0] }
        return transcriptAppendItems + streamedItems + additionalItemsBeforeMarker + [
            MSPTurnInterruptChatMapping.interruptedMarkerInputItem()
        ]
    }

    func flushPendingStreamedSnapshot() async {
        guard hasPendingStreamedSnapshot else {
            cancelPendingStreamedSnapshot()
            return
        }
        cancelPendingStreamedSnapshot()
        hasPendingStreamedSnapshot = false
        await emitSnapshotUpdated()
    }

    func emitSnapshotUpdated() async {
        guard let onSnapshotUpdated else {
            return
        }
        await onSnapshotUpdated(transcriptAppendItemsSnapshot())
    }

    private func scheduleStreamedSnapshotUpdated() {
        guard onSnapshotUpdated != nil else {
            return
        }
        hasPendingStreamedSnapshot = true
        guard pendingStreamedSnapshotTask == nil else {
            return
        }
        pendingStreamedSnapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.streamedSnapshotDelayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushPendingStreamedSnapshot()
        }
    }

    private func cancelPendingStreamedSnapshot() {
        pendingStreamedSnapshotTask?.cancel()
        pendingStreamedSnapshotTask = nil
    }

    private func discardPendingStreamedSnapshot() {
        cancelPendingStreamedSnapshot()
        hasPendingStreamedSnapshot = false
    }
}

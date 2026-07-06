actor MSPAgentStreamedTextBuffer {
    private var text = ""

    func append(_ delta: String) {
        text += delta
    }

    func value() -> String {
        text
    }
}

actor MSPAgentStreamStartState {
    private var didStart = false

    func markStartedIfNeeded() -> Bool {
        guard !didStart else {
            return false
        }
        didStart = true
        return true
    }
}

actor MSPAgentStructuredActivationSuppressionGate {
    private enum Mode {
        case undecided
        case holdingStructuredJSON
        case passThrough
    }

    private var mode: Mode = .undecided
    private var bufferedText = ""

    func visibleDeltas(after delta: String) -> [String] {
        switch mode {
        case .passThrough:
            return [delta]

        case .holdingStructuredJSON:
            bufferedText += delta
            return []

        case .undecided:
            bufferedText += delta
            let trimmed = bufferedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else {
                return []
            }
            if first == "{" {
                mode = .holdingStructuredJSON
                return []
            }
            mode = .passThrough
            let visible = bufferedText
            bufferedText = ""
            return [visible]
        }
    }
}

actor MSPAgentAssistantProgressEmissionState {
    private var emittedProgressTexts = Set<String>()

    func markEmittedIfNeeded(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }
        return emittedProgressTexts.insert(normalized).inserted
    }
}

actor MSPAgentPlanModeStreamState {
    private var latestProposalContent: String?
    private var latestStreamPhase = MSPAgentModelStreamDelta.Phase.finalAnswer

    func setProposalContent(_ content: String) {
        latestProposalContent = content
    }

    func proposalContent() -> String? {
        latestProposalContent
    }

    func setLastStreamPhase(_ phase: MSPAgentModelStreamDelta.Phase) {
        latestStreamPhase = phase
    }

    func lastStreamPhase() -> MSPAgentModelStreamDelta.Phase {
        latestStreamPhase
    }
}

enum MSPAgentVisibleStreamOwnership {
    static func streamedText(_ streamedText: String, ownsCompletedText completedText: String) -> Bool {
        let streamed = normalizedText(streamedText)
        let completed = normalizedText(completedText)
        guard !streamed.isEmpty, !completed.isEmpty else {
            return false
        }
        return streamed == completed || streamed.contains(completed)
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

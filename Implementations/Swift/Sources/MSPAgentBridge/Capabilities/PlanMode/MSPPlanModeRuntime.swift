import Foundation

public struct MSPPlanModeRuntimeOutput: Hashable, Sendable {
    public var visibleText: String
    public var proposedPlanContent: String?

    public init(visibleText: String, proposedPlanContent: String?) {
        self.visibleText = visibleText
        self.proposedPlanContent = proposedPlanContent
    }
}

public enum MSPPlanModeRuntime {
    public static func parseCompletedText(_ text: String) -> MSPPlanModeRuntimeOutput {
        var parser = MSPPlanModeProposedPlanParser()
        let parsed = parser.push(text) + parser.finish()
        return MSPPlanModeRuntimeOutput(
            visibleText: parsed.visibleText,
            proposedPlanContent: parsed.proposedPlanContent
        )
    }

    public static func sanitizedNativeOutputItems(
        _ items: [MSPAgentJSONValue]
    ) -> [MSPAgentJSONValue] {
        items.compactMap { item in
            guard var object = item.objectValue,
                  object["type"]?.stringValue == "message",
                  object["role"]?.stringValue == "assistant",
                  let content = object["content"]?.arrayValue else {
                return item
            }
            var sanitizedContent: [MSPAgentJSONValue] = []
            for contentItem in content {
                guard var contentObject = contentItem.objectValue,
                      let text = contentObject["text"]?.stringValue else {
                    sanitizedContent.append(contentItem)
                    continue
                }
                let visible = parseCompletedText(text).visibleText
                guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                contentObject["text"] = .string(visible)
                sanitizedContent.append(.object(contentObject))
            }
            guard !sanitizedContent.isEmpty else {
                return nil
            }
            object["content"] = .array(sanitizedContent)
            return .object(object)
        }
    }

    public static func firstProposedPlan(
        in output: MSPAgentModelTurnOutput
    ) -> String? {
        for text in [output.assistantMessage, output.finalAnswer].compactMap({ $0 }) {
            let parsed = parseCompletedText(text)
            if let proposed = parsed.proposedPlanContent,
               !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return proposed
            }
        }
        for item in output.nativeOutputItems {
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "message",
                  object["role"]?.stringValue == "assistant",
                  let content = object["content"]?.arrayValue else {
                continue
            }
            let text = content.compactMap {
                $0.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
            let parsed = parseCompletedText(text)
            if let proposed = parsed.proposedPlanContent,
               !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return proposed
            }
        }
        return nil
    }
}

public actor MSPPlanModeRuntimeSession {
    let threadID: String
    let planningTurnID: String
    let itemID: String
    private var parser = MSPPlanModeProposedPlanParser()
    private var latestProposedPlanContent: String?

    init(threadID: String, planningTurnID: String) {
        self.threadID = threadID
        self.planningTurnID = planningTurnID
        self.itemID = "\(planningTurnID)-plan"
    }

    func consumeDelta(_ delta: String) -> MSPPlanModeStreamChunk {
        let chunk = parser.push(delta)
        if let proposedPlanContent = chunk.proposedPlanContent {
            latestProposedPlanContent = proposedPlanContent
        }
        return chunk
    }

    func finish() -> MSPPlanModeStreamChunk {
        let chunk = parser.finish()
        if let proposedPlanContent = chunk.proposedPlanContent {
            latestProposedPlanContent = proposedPlanContent
        }
        return chunk
    }

    func proposedPlanContent() -> String? {
        latestProposedPlanContent
    }

    func deltaEvent(_ delta: String) -> MSPAgentEvent {
        .planModeProposalDelta(MSPPlanModeProposalDeltaEvent(
            threadID: threadID,
            planningTurnID: planningTurnID,
            itemID: itemID,
            delta: delta
        ))
    }
}

struct MSPPlanModeStreamChunk: Hashable, Sendable {
    var visibleText: String = ""
    var proposedPlanDeltas: [String] = []
    var proposedPlanContent: String?

    static func + (lhs: MSPPlanModeStreamChunk, rhs: MSPPlanModeStreamChunk) -> MSPPlanModeStreamChunk {
        MSPPlanModeStreamChunk(
            visibleText: lhs.visibleText + rhs.visibleText,
            proposedPlanDeltas: lhs.proposedPlanDeltas + rhs.proposedPlanDeltas,
            proposedPlanContent: rhs.proposedPlanContent ?? lhs.proposedPlanContent
        )
    }

    mutating func appendVisibleText(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        visibleText.append(text)
    }

    mutating func appendProposedPlanDelta(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        if proposedPlanDeltas.isEmpty {
            proposedPlanDeltas.append(text)
        } else {
            proposedPlanDeltas[proposedPlanDeltas.count - 1].append(text)
        }
    }
}

struct MSPPlanModeProposedPlanParser {
    private static let openTag = "<proposed_plan>"
    private static let closeTag = "</proposed_plan>"

    private var lineBuffer = ""
    private var detectTag = true
    private var isInsidePlan = false
    private var planText = ""

    mutating func push(_ text: String) -> MSPPlanModeStreamChunk {
        var chunk = MSPPlanModeStreamChunk()
        var run = ""

        for character in text {
            if detectTag {
                if !run.isEmpty {
                    pushText(run, into: &chunk)
                    run.removeAll(keepingCapacity: true)
                }
                lineBuffer.append(character)
                if character == "\n" {
                    finishLine(into: &chunk)
                    continue
                }

                let slug = lineBuffer.trimmingLeadingWhitespace()
                if slug.isEmpty || Self.isTagPrefix(slug) {
                    continue
                }

                let buffered = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                detectTag = false
                pushText(buffered, into: &chunk)
                continue
            }

            run.append(character)
            if character == "\n" {
                pushText(run, into: &chunk)
                run.removeAll(keepingCapacity: true)
                detectTag = true
            }
        }

        if !run.isEmpty {
            pushText(run, into: &chunk)
        }
        return chunk
    }

    mutating func finish() -> MSPPlanModeStreamChunk {
        var chunk = MSPPlanModeStreamChunk()
        if !lineBuffer.isEmpty {
            let buffered = lineBuffer
            lineBuffer.removeAll(keepingCapacity: true)
            let withoutNewline = buffered.removingSingleTrailingNewline()
            let slug = withoutNewline
                .trimmingLeadingWhitespace()
                .trimmingTrailingWhitespace()

            if slug == Self.openTag, !isInsidePlan {
                startPlan()
            } else if slug == Self.closeTag, isInsidePlan {
                endPlan(into: &chunk)
            } else {
                pushText(buffered, into: &chunk)
            }
        }
        if isInsidePlan {
            endPlan(into: &chunk)
        }
        detectTag = true
        return chunk
    }

    private mutating func finishLine(into chunk: inout MSPPlanModeStreamChunk) {
        let line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        let withoutNewline = line.removingSingleTrailingNewline()
        let slug = withoutNewline
            .trimmingLeadingWhitespace()
            .trimmingTrailingWhitespace()

        if slug == Self.openTag, !isInsidePlan {
            startPlan()
            detectTag = true
            return
        }

        if slug == Self.closeTag, isInsidePlan {
            endPlan(into: &chunk)
            detectTag = true
            return
        }

        detectTag = true
        pushText(line, into: &chunk)
    }

    private mutating func pushText(
        _ text: String,
        into chunk: inout MSPPlanModeStreamChunk
    ) {
        if isInsidePlan {
            chunk.appendProposedPlanDelta(text)
            planText.append(text)
        } else {
            chunk.appendVisibleText(text)
        }
    }

    private mutating func startPlan() {
        isInsidePlan = true
        planText.removeAll(keepingCapacity: true)
    }

    private mutating func endPlan(into chunk: inout MSPPlanModeStreamChunk) {
        isInsidePlan = false
        chunk.proposedPlanContent = planText
    }

    private static func isTagPrefix(_ value: String) -> Bool {
        let slug = value.trimmingTrailingWhitespace()
        return openTag.hasPrefix(slug) || closeTag.hasPrefix(slug)
    }
}

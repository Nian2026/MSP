import Foundation

struct MSPAgentTimelineImage: Identifiable, Equatable, Sendable {
    var id = UUID()
    var base64: String
    var mimeType: String?

    var cacheKey: String {
        "msp-timeline-image-\(id.uuidString)"
    }
}

struct PhotoSorterTextSelectionSnapshot: Identifiable, Equatable, Sendable {
    var id: UUID
    var selectedText: String
    var sourceKind: String
    var sourceDisplayName: String
    var sourceMessageID: String?
    var sourceMessageRole: String?
    var selectedTextOccurrenceIndexInMessage: Int?
    var renderedTextSegments: [String]

    init(
        id: UUID = UUID(),
        selectedText: String,
        sourceKind: String = "conversation",
        sourceDisplayName: String = "对话摘录",
        sourceMessageID: String? = nil,
        sourceMessageRole: String? = nil,
        selectedTextOccurrenceIndexInMessage: Int? = nil,
        renderedTextSegments: [String] = []
    ) {
        self.id = id
        self.selectedText = selectedText
        self.sourceKind = sourceKind
        self.sourceDisplayName = sourceDisplayName
        self.sourceMessageID = sourceMessageID
        self.sourceMessageRole = sourceMessageRole
        self.selectedTextOccurrenceIndexInMessage = selectedTextOccurrenceIndexInMessage
        self.renderedTextSegments = renderedTextSegments
    }

    var normalized: PhotoSorterTextSelectionSnapshot? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        var copy = self
        copy.selectedText = trimmed
        copy.sourceKind = sourceKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "conversation"
            : sourceKind.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sourceDisplayName = sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "对话摘录"
            : sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

enum PhotoSorterSelectedTextPromptFormatter {
    static func prompt(
        userPrompt: String,
        textSelections: [PhotoSorterTextSelectionSnapshot]
    ) -> String {
        let selectedTexts = textSelections.compactMap { selection -> String? in
            let text = selection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !selectedTexts.isEmpty else { return userPrompt }

        var context = "\n# Selected text:\n"
        for (index, text) in selectedTexts.enumerated() {
            context += "\n## Selection \(index + 1)\n\(text)\n"
        }
        return "\(context)\n## My request for Codex:\n\(userPrompt)\n"
    }
}

struct MSPAgentTimelineItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case system
        case user
        case assistantProgress
        case toolCall
        case toolResult
        case assistantFinal
        case stoppedMarker
        case error
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var detail: String?
    var callID: String?
    var batchID: UUID?
    var toolName: String?
    var command: String?
    var cwd: String?
    var stdout: String?
    var stderr: String?
    var exitCode: Int?
    var execSessionID: Int?
    var parentCallID: String?
    var status: String?
    var startedAtMilliseconds: Int?
    var completedAtMilliseconds: Int?
    var durationMilliseconds: Int?
    var turnStartedAtMilliseconds: Int?
    var turnDurationMilliseconds: Int?
    var images: [MSPAgentTimelineImage]
    var sourceTextSelections: [PhotoSorterTextSelectionSnapshot]

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        body: String,
        detail: String? = nil,
        callID: String? = nil,
        batchID: UUID? = nil,
        toolName: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        stdout: String? = nil,
        stderr: String? = nil,
        exitCode: Int? = nil,
        execSessionID: Int? = nil,
        parentCallID: String? = nil,
        status: String? = nil,
        startedAtMilliseconds: Int? = nil,
        completedAtMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil,
        turnStartedAtMilliseconds: Int? = nil,
        turnDurationMilliseconds: Int? = nil,
        images: [MSPAgentTimelineImage] = [],
        sourceTextSelections: [PhotoSorterTextSelectionSnapshot] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.detail = detail
        self.callID = callID
        self.batchID = batchID
        self.toolName = toolName
        self.command = command
        self.cwd = cwd
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.execSessionID = execSessionID
        self.parentCallID = parentCallID
        self.status = status
        self.startedAtMilliseconds = startedAtMilliseconds
        self.completedAtMilliseconds = completedAtMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.turnStartedAtMilliseconds = turnStartedAtMilliseconds
        self.turnDurationMilliseconds = turnDurationMilliseconds
        self.images = images
        self.sourceTextSelections = sourceTextSelections
    }
}

struct PhotoSorterShellOutputEnvelope: Equatable, Sendable {
    var output: String
    var exitCode: Int?
    var wallTimeSeconds: Double?
    var isRunning: Bool

    var durationMilliseconds: Int? {
        wallTimeSeconds.map { max(0, Int(($0 * 1000).rounded())) }
    }

    static func parse(_ text: String) -> PhotoSorterShellOutputEnvelope? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return nil
        }

        var wallTimeSeconds: Double?
        var exitCode: Int?
        var isRunning = false
        var outputLineIndex: Int?
        var inlineOutput = ""

        for (index, line) in lines.prefix(8).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Self.wallTimeSeconds(from: trimmed) {
                wallTimeSeconds = value
                continue
            }
            if let value = Self.exitCode(from: trimmed) {
                exitCode = value
                continue
            }
            if trimmed.hasPrefix("Process running with session ID ") {
                isRunning = true
                continue
            }
            if trimmed.hasPrefix("Output:") {
                outputLineIndex = index
                inlineOutput = String(trimmed.dropFirst("Output:".count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard let outputLineIndex,
              wallTimeSeconds != nil || exitCode != nil || isRunning else {
            return nil
        }

        let rest = outputLineIndex + 1 < lines.count
            ? lines[(outputLineIndex + 1)...].joined(separator: "\n")
            : ""
        var output: String
        if inlineOutput.isEmpty {
            output = rest
        } else if rest.isEmpty {
            output = inlineOutput
        } else {
            output = inlineOutput + "\n" + rest
        }
        if normalized.hasSuffix("\n"), !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
        return PhotoSorterShellOutputEnvelope(
            output: output,
            exitCode: exitCode,
            wallTimeSeconds: wallTimeSeconds,
            isRunning: isRunning
        )
    }

    private static func wallTimeSeconds(from line: String) -> Double? {
        let prefix = "Wall time:"
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let remainder = line.dropFirst(prefix.count)
            .replacingOccurrences(of: "seconds", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(remainder)
    }

    private static func exitCode(from line: String) -> Int? {
        let prefix = "Process exited with code "
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let remainder = line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(remainder)
    }
}

enum MSPAgentTimelineStopSupport {
    static func stoppingRunningTurnItems(
        _ items: [MSPAgentTimelineItem],
        turnStartedAtMilliseconds: Int,
        stoppedAtMilliseconds: Int
    ) -> [MSPAgentTimelineItem] {
        let turnDuration = max(0, stoppedAtMilliseconds - turnStartedAtMilliseconds)
        var nextItems: [MSPAgentTimelineItem] = []
        var hasStoppedMarker = false

        for item in items {
            guard item.turnStartedAtMilliseconds == turnStartedAtMilliseconds else {
                nextItems.append(item)
                continue
            }
            if item.kind == .stoppedMarker {
                hasStoppedMarker = true
                nextItems.append(item)
                continue
            }
            if item.kind == .assistantFinal,
               item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            var stoppedItem = item
            stoppedItem.turnDurationMilliseconds = turnDuration
            if stoppedItem.kind == .toolCall || stoppedItem.kind == .toolResult {
                stoppedItem = stoppingToolItem(
                    stoppedItem,
                    stoppedAtMilliseconds: stoppedAtMilliseconds
                )
            } else if stoppedItem.kind == .assistantProgress {
                stoppedItem.completedAtMilliseconds = stoppedItem.completedAtMilliseconds
                    ?? stoppedAtMilliseconds
                if let startedAt = stoppedItem.startedAtMilliseconds {
                    stoppedItem.durationMilliseconds = stoppedItem.durationMilliseconds
                        ?? max(0, stoppedAtMilliseconds - startedAt)
                }
            }
            nextItems.append(stoppedItem)
        }

        if !hasStoppedMarker {
            nextItems.append(stoppedMarkerItem(
                turnStartedAtMilliseconds: turnStartedAtMilliseconds,
                stoppedAtMilliseconds: stoppedAtMilliseconds,
                turnDurationMilliseconds: turnDuration
            ))
        }
        return nextItems
    }

    private static func stoppingToolItem(
        _ item: MSPAgentTimelineItem,
        stoppedAtMilliseconds: Int
    ) -> MSPAgentTimelineItem {
        guard statusIsRunning(item.status) else {
            return item
        }
        var stoppedItem = item
        stoppedItem.status = "stopped"
        stoppedItem.completedAtMilliseconds = stoppedItem.completedAtMilliseconds
            ?? stoppedAtMilliseconds
        if let startedAt = stoppedItem.startedAtMilliseconds {
            stoppedItem.durationMilliseconds = stoppedItem.durationMilliseconds
                ?? max(0, stoppedAtMilliseconds - startedAt)
        }
        return stoppedItem
    }

    private static func stoppedMarkerItem(
        turnStartedAtMilliseconds: Int,
        stoppedAtMilliseconds: Int,
        turnDurationMilliseconds: Int
    ) -> MSPAgentTimelineItem {
        MSPAgentTimelineItem(
            kind: .stoppedMarker,
            title: "",
            body: "已停止",
            status: "stopped",
            startedAtMilliseconds: stoppedAtMilliseconds,
            completedAtMilliseconds: stoppedAtMilliseconds,
            durationMilliseconds: turnDurationMilliseconds,
            turnStartedAtMilliseconds: turnStartedAtMilliseconds,
            turnDurationMilliseconds: turnDurationMilliseconds
        )
    }

    private static func statusIsRunning(_ status: String?) -> Bool {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "inprogress", "running", "processing", "streaming", "pending":
            return true
        case "stopped", "cancelled", "canceled", "interrupted",
             "completed", "complete", "success", "succeeded",
             "failed", "failure", "error":
            return false
        default:
            return false
        }
    }
}

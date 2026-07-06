import Foundation

struct MSPAgentTimelineItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case system
        case user
        case assistantProgress
        case toolCall
        case toolResult
        case assistantFinal
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
    var status: String?
    var previewItems: [AssistantSupportPreviewItem]
    var startedAtMilliseconds: Int?
    var completedAtMilliseconds: Int?
    var durationMilliseconds: Int?
    var turnStartedAtMilliseconds: Int?
    var turnDurationMilliseconds: Int?

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
        status: String? = nil,
        previewItems: [AssistantSupportPreviewItem] = [],
        startedAtMilliseconds: Int? = nil,
        completedAtMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil,
        turnStartedAtMilliseconds: Int? = nil,
        turnDurationMilliseconds: Int? = nil
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
        self.status = status
        self.previewItems = previewItems
        self.startedAtMilliseconds = startedAtMilliseconds
        self.completedAtMilliseconds = completedAtMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.turnStartedAtMilliseconds = turnStartedAtMilliseconds
        self.turnDurationMilliseconds = turnDurationMilliseconds
    }
}

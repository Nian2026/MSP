import Foundation

typealias ExampleChatJSONValue = ExampleChatRuntimeJSONValue

extension ExampleChatRuntimeJSONValue {
    var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}

enum AttachmentKind: String, Codable, Hashable, CaseIterable, Sendable {
    case extractedPDF
    case importedFile
    case importedImage
}

struct SearchReferenceRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var content: String
    var url: String
    var searchProviderKind: String?

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        url: String,
        searchProviderKind: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.url = url
        self.searchProviderKind = searchProviderKind
    }
}

struct AssistantWebSearchAction: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var type: String
    var query: String?
    var queries: [String]
    var url: String?
    var pattern: String?
    var status: String?
    var completed: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case query
        case queries
        case url
        case pattern
        case status
        case completed
    }

    init(
        id: UUID = UUID(),
        type: String,
        query: String? = nil,
        queries: [String] = [],
        url: String? = nil,
        pattern: String? = nil,
        status: String? = nil,
        completed: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.query = query
        self.queries = queries
        self.url = url
        self.pattern = pattern
        self.status = status
        self.completed = completed
    }
}

struct AssistantImageRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var url: String?
    var base64: String?
    var mimeType: String?
    var filePath: String?
    var cacheKey: String?

    init(
        id: UUID = UUID(),
        url: String? = nil,
        base64: String? = nil,
        mimeType: String? = nil,
        filePath: String? = nil,
        cacheKey: String? = nil
    ) {
        self.id = id
        self.url = url
        self.base64 = base64
        self.mimeType = mimeType
        self.filePath = filePath
        self.cacheKey = cacheKey
    }
}

struct AssistantSupportPreviewItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case markdown
        case file
        case videoFrame = "video_frame"
        case libraryTree = "library_tree"
        case videoDownloadProgress = "video_download_progress"
    }

    var id: UUID
    var kind: Kind
    var title: String
    var subtitle: String?
    var documentName: String?
    var markdown: String?
    var filePath: String?
    var fileName: String?
    var mimeType: String?
    var attachmentKind: AttachmentKind?
    var payload: ExampleChatJSONValue?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        documentName: String? = nil,
        markdown: String? = nil,
        filePath: String? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        attachmentKind: AttachmentKind? = nil,
        payload: ExampleChatJSONValue? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.documentName = documentName
        self.markdown = markdown
        self.filePath = filePath
        self.fileName = fileName
        self.mimeType = mimeType
        self.attachmentKind = attachmentKind
        self.payload = payload
    }
}

struct AssistantSupportShellExecution: Codable, Hashable, Sendable {
    var command: String
    var cwd: String?
    var kind: String
    var target: String?
    var query: String?
    var exitCode: Int?
    var wallTimeSeconds: Double?
    var output: String?
    var rawOutput: String?

    init(
        command: String,
        cwd: String? = nil,
        kind: String = "unknown",
        target: String? = nil,
        query: String? = nil,
        exitCode: Int? = nil,
        wallTimeSeconds: Double? = nil,
        output: String? = nil,
        rawOutput: String? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.kind = kind
        self.target = target
        self.query = query
        self.exitCode = exitCode
        self.wallTimeSeconds = wallTimeSeconds
        self.output = output
        self.rawOutput = rawOutput
    }
}

struct AssistantSupportCommandAction: Codable, Hashable, Sendable {
    var type: String
    var command: String
    var name: String?
    var path: String?
    var query: String?

    init(
        type: String,
        command: String,
        name: String? = nil,
        path: String? = nil,
        query: String? = nil
    ) {
        self.type = type
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }
}

struct AssistantSupportCommandExecution: Codable, Hashable, Sendable {
    var id: String
    var callID: String?
    var cwd: String?
    var command: String
    var commandActions: [AssistantSupportCommandAction]
    var aggregatedOutput: String?
    var exitCode: Int?
    var status: String
    var wallTimeSeconds: Double?

    init(
        id: String,
        callID: String? = nil,
        cwd: String? = nil,
        command: String,
        commandActions: [AssistantSupportCommandAction] = [],
        aggregatedOutput: String? = nil,
        exitCode: Int? = nil,
        status: String,
        wallTimeSeconds: Double? = nil
    ) {
        self.id = id
        self.callID = callID
        self.cwd = cwd
        self.command = command
        self.commandActions = commandActions
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.status = status
        self.wallTimeSeconds = wallTimeSeconds
    }
}

struct AssistantSupportActivityItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var sourceBlockID: String?
    var type: String
    var server: String?
    var tool: String?
    var arguments: ExampleChatJSONValue?
    var result: ExampleChatJSONValue?
    var error: String?
    var text: String?
    var query: String?
    var subtitleText: String?
    var detailText: String?
    var status: String?
    var completed: Bool?
    var durationMilliseconds: Int?
    var startedAtMilliseconds: Int?
    var completedAtMilliseconds: Int?
    var summaryParts: [String]
    var searchQueries: [String]
    var searchReferences: [SearchReferenceRecord]
    var webSearchActions: [AssistantWebSearchAction]
    var webSearchAction: AssistantWebSearchAction?
    var webSearchReference: SearchReferenceRecord?
    var reference: SearchReferenceRecord?
    var previewItems: [AssistantSupportPreviewItem]
    var chatToolName: String?
    var chatToolBatchID: UUID?
    var progress: Double?
    var progressUpdatedAtMilliseconds: Int?
    var progressRatePerSecond: Double?
    var phase: String?
    var phaseTitle: String?
    var batchCurrentItemIndex: Int?
    var batchCompletedItemCount: Int?
    var batchTotalItemCount: Int?
    var batchProgress: Double?
    var childItems: [AssistantSupportActivityItem]
    var shellExecution: AssistantSupportShellExecution?
    var commandExecution: AssistantSupportCommandExecution?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceBlockID = "sourceBlockId"
        case type
        case server
        case tool
        case arguments
        case result
        case error
        case text
        case query
        case subtitleText
        case detailText
        case status
        case completed
        case durationMilliseconds
        case startedAtMilliseconds
        case completedAtMilliseconds
        case summaryParts
        case searchQueries
        case searchReferences
        case webSearchActions
        case webSearchAction
        case webSearchReference
        case reference
        case previewItems
        case chatToolName
        case chatToolBatchID
        case progress
        case progressUpdatedAtMilliseconds
        case progressRatePerSecond
        case phase
        case phaseTitle
        case batchCurrentItemIndex
        case batchCompletedItemCount
        case batchTotalItemCount
        case batchProgress
        case childItems
        case shellExecution
        case commandExecution
    }

    init(
        id: String = UUID().uuidString,
        sourceBlockID: String? = nil,
        type: String,
        server: String? = nil,
        tool: String? = nil,
        arguments: ExampleChatJSONValue? = nil,
        result: ExampleChatJSONValue? = nil,
        error: String? = nil,
        text: String? = nil,
        query: String? = nil,
        subtitleText: String? = nil,
        detailText: String? = nil,
        status: String? = nil,
        completed: Bool? = nil,
        durationMilliseconds: Int? = nil,
        startedAtMilliseconds: Int? = nil,
        completedAtMilliseconds: Int? = nil,
        summaryParts: [String] = [],
        searchQueries: [String] = [],
        searchReferences: [SearchReferenceRecord] = [],
        webSearchActions: [AssistantWebSearchAction] = [],
        webSearchAction: AssistantWebSearchAction? = nil,
        webSearchReference: SearchReferenceRecord? = nil,
        reference: SearchReferenceRecord? = nil,
        previewItems: [AssistantSupportPreviewItem] = [],
        chatToolName: String? = nil,
        chatToolBatchID: UUID? = nil,
        progress: Double? = nil,
        progressUpdatedAtMilliseconds: Int? = nil,
        progressRatePerSecond: Double? = nil,
        phase: String? = nil,
        phaseTitle: String? = nil,
        batchCurrentItemIndex: Int? = nil,
        batchCompletedItemCount: Int? = nil,
        batchTotalItemCount: Int? = nil,
        batchProgress: Double? = nil,
        childItems: [AssistantSupportActivityItem] = [],
        shellExecution: AssistantSupportShellExecution? = nil,
        commandExecution: AssistantSupportCommandExecution? = nil
    ) {
        self.id = id
        self.sourceBlockID = sourceBlockID
        self.type = type
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.error = error
        self.text = text
        self.query = query
        self.subtitleText = subtitleText
        self.detailText = detailText
        self.status = status
        self.completed = completed
        self.durationMilliseconds = durationMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
        self.completedAtMilliseconds = completedAtMilliseconds
        self.summaryParts = summaryParts
        self.searchQueries = searchQueries
        self.searchReferences = searchReferences
        self.webSearchActions = webSearchActions
        self.webSearchAction = webSearchAction
        self.webSearchReference = webSearchReference
        self.reference = reference
        self.previewItems = previewItems
        self.chatToolName = chatToolName
        self.chatToolBatchID = chatToolBatchID
        self.progress = progress
        self.progressUpdatedAtMilliseconds = progressUpdatedAtMilliseconds
        self.progressRatePerSecond = progressRatePerSecond
        self.phase = phase
        self.phaseTitle = phaseTitle
        self.batchCurrentItemIndex = batchCurrentItemIndex
        self.batchCompletedItemCount = batchCompletedItemCount
        self.batchTotalItemCount = batchTotalItemCount
        self.batchProgress = batchProgress
        self.childItems = childItems
        self.shellExecution = shellExecution
        self.commandExecution = commandExecution
    }
}

struct AssistantSupportWorkedForItem: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case working
        case worked
    }

    var type: String
    var status: Status
    var startedAtMs: Int
    var completedAtMs: Int?

    init(
        status: Status,
        startedAtMilliseconds: Int,
        completedAtMilliseconds: Int? = nil
    ) {
        type = "worked-for"
        self.status = status
        startedAtMs = startedAtMilliseconds
        completedAtMs = completedAtMilliseconds
    }
}

struct AssistantSupportBlock: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case thinking
        case reasoningSummary = "reasoning_summary"
        case searchResults = "search_results"
        case textSegment = "text_segment"
        case chatProcessing = "chat_processing"
        case chatProgress = "chat_progress"
        case chatVideoProgress = "chat_video_progress"
        case chatToolCall = "chat_tool_call"
        case chatStoppedMarker = "chat_stopped_marker"
        case proposedPlan = "proposed_plan"
        case image

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "readex_processing":
                self = .chatProcessing
            case "readex_progress":
                self = .chatProgress
            case "readex_video_progress":
                self = .chatVideoProgress
            case "readex_tool_call":
                self = .chatToolCall
            case "readex_stopped_marker":
                self = .chatStoppedMarker
            default:
                guard let kind = Self(rawValue: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown example chat support block kind: \(value)"
                    )
                }
                self = kind
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    enum ImageStatus: String, Codable, Hashable, Sendable {
        case processing
        case completed
        case failed
    }

    var id: UUID
    var kind: Kind
    var text: String?
    var detailText: String?
    var durationMilliseconds: Int?
    var startedAtMilliseconds: Int?
    var chatTurnStartedAtMilliseconds: Int?
    var chatTurnDurationMilliseconds: Int?
    var summaryParts: [String]
    var summaryDurationsMilliseconds: [Int]
    var searchQueries: [String]
    var searchReferences: [SearchReferenceRecord]
    var webSearchActions: [AssistantWebSearchAction]
    var imageStatus: ImageStatus?
    var images: [AssistantImageRecord]
    var previewItems: [AssistantSupportPreviewItem]
    var activityItems: [AssistantSupportActivityItem]
    var chatToolName: String?
    var chatToolBatchID: UUID?
    var chatProgressSegmentID: UUID?
    var status: String?
    var progress: Double?
    var progressUpdatedAtMilliseconds: Int?
    var progressRatePerSecond: Double?
    var phase: String?
    var phaseTitle: String?
    var subtitleText: String?
    var chatTransferTaskID: UUID?
    var batchCurrentItemIndex: Int?
    var batchCompletedItemCount: Int?
    var batchTotalItemCount: Int?
    var batchProgress: Double?
    var workedForItem: AssistantSupportWorkedForItem?
    var chatProcessingGroupID: String?
    var chatProcessingChromeRole: String?
    var chatProcessingFoldGroupID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case detailText
        case durationMilliseconds
        case startedAtMilliseconds
        case chatTurnStartedAtMilliseconds
        case chatTurnDurationMilliseconds
        case summaryParts
        case summaryDurationsMilliseconds
        case searchQueries
        case searchReferences
        case webSearchActions
        case imageStatus
        case images
        case previewItems
        case activityItems = "items"
        case chatToolName
        case chatToolBatchID
        case chatProgressSegmentID
        case status
        case progress
        case progressUpdatedAtMilliseconds
        case progressRatePerSecond
        case phase
        case phaseTitle
        case subtitleText
        case chatTransferTaskID
        case batchCurrentItemIndex
        case batchCompletedItemCount
        case batchTotalItemCount
        case batchProgress
        case workedForItem
        case chatProcessingGroupID = "chatProcessingGroupId"
        case chatProcessingChromeRole
        case chatProcessingFoldGroupID = "chatProcessingFoldGroupId"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case readexTurnStartedAtMilliseconds
        case readexTurnDurationMilliseconds
        case readexToolName
        case readexToolBatchID
        case readexProgressSegmentID
        case readexTransferTaskID
        case readexProcessingGroupId
        case readexProcessingGroupID
        case readexProcessingChromeRole
        case readexProcessingFoldGroupId
        case readexProcessingFoldGroupID
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String? = nil,
        detailText: String? = nil,
        durationMilliseconds: Int? = nil,
        startedAtMilliseconds: Int? = nil,
        chatTurnStartedAtMilliseconds: Int? = nil,
        chatTurnDurationMilliseconds: Int? = nil,
        summaryParts: [String] = [],
        summaryDurationsMilliseconds: [Int] = [],
        searchQueries: [String] = [],
        searchReferences: [SearchReferenceRecord] = [],
        webSearchActions: [AssistantWebSearchAction] = [],
        imageStatus: ImageStatus? = nil,
        images: [AssistantImageRecord] = [],
        previewItems: [AssistantSupportPreviewItem] = [],
        activityItems: [AssistantSupportActivityItem] = [],
        chatToolName: String? = nil,
        chatToolBatchID: UUID? = nil,
        chatProgressSegmentID: UUID? = nil,
        status: String? = nil,
        progress: Double? = nil,
        progressUpdatedAtMilliseconds: Int? = nil,
        progressRatePerSecond: Double? = nil,
        phase: String? = nil,
        phaseTitle: String? = nil,
        subtitleText: String? = nil,
        chatTransferTaskID: UUID? = nil,
        batchCurrentItemIndex: Int? = nil,
        batchCompletedItemCount: Int? = nil,
        batchTotalItemCount: Int? = nil,
        batchProgress: Double? = nil,
        workedForItem: AssistantSupportWorkedForItem? = nil,
        chatProcessingGroupID: String? = nil,
        chatProcessingChromeRole: String? = nil,
        chatProcessingFoldGroupID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detailText = detailText
        self.durationMilliseconds = durationMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
        self.chatTurnStartedAtMilliseconds = chatTurnStartedAtMilliseconds
        self.chatTurnDurationMilliseconds = chatTurnDurationMilliseconds
        self.summaryParts = summaryParts
        self.summaryDurationsMilliseconds = summaryDurationsMilliseconds
        self.searchQueries = searchQueries
        self.searchReferences = searchReferences
        self.webSearchActions = webSearchActions
        self.imageStatus = imageStatus
        self.images = images
        self.previewItems = previewItems
        self.activityItems = activityItems
        self.chatToolName = chatToolName
        self.chatToolBatchID = chatToolBatchID
        self.chatProgressSegmentID = chatProgressSegmentID
        self.status = status
        self.progress = progress
        self.progressUpdatedAtMilliseconds = progressUpdatedAtMilliseconds
        self.progressRatePerSecond = progressRatePerSecond
        self.phase = phase
        self.phaseTitle = phaseTitle
        self.subtitleText = subtitleText
        self.chatTransferTaskID = chatTransferTaskID
        self.batchCurrentItemIndex = batchCurrentItemIndex
        self.batchCompletedItemCount = batchCompletedItemCount
        self.batchTotalItemCount = batchTotalItemCount
        self.batchProgress = batchProgress
        self.workedForItem = workedForItem
        self.chatProcessingGroupID = chatProcessingGroupID
        self.chatProcessingChromeRole = chatProcessingChromeRole
        self.chatProcessingFoldGroupID = chatProcessingFoldGroupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.detailText = try container.decodeIfPresent(String.self, forKey: .detailText)
        self.durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        self.startedAtMilliseconds = try container.decodeIfPresent(Int.self, forKey: .startedAtMilliseconds)
        self.chatTurnStartedAtMilliseconds =
            try container.decodeIfPresent(Int.self, forKey: .chatTurnStartedAtMilliseconds)
            ?? legacyContainer.decodeIfPresent(Int.self, forKey: .readexTurnStartedAtMilliseconds)
        self.chatTurnDurationMilliseconds =
            try container.decodeIfPresent(Int.self, forKey: .chatTurnDurationMilliseconds)
            ?? legacyContainer.decodeIfPresent(Int.self, forKey: .readexTurnDurationMilliseconds)
        self.summaryParts = try container.decodeIfPresent([String].self, forKey: .summaryParts) ?? []
        self.summaryDurationsMilliseconds =
            try container.decodeIfPresent([Int].self, forKey: .summaryDurationsMilliseconds) ?? []
        self.searchQueries = try container.decodeIfPresent([String].self, forKey: .searchQueries) ?? []
        self.searchReferences =
            try container.decodeIfPresent([SearchReferenceRecord].self, forKey: .searchReferences) ?? []
        self.webSearchActions =
            try container.decodeIfPresent([AssistantWebSearchAction].self, forKey: .webSearchActions) ?? []
        self.imageStatus = try container.decodeIfPresent(ImageStatus.self, forKey: .imageStatus)
        self.images = try container.decodeIfPresent([AssistantImageRecord].self, forKey: .images) ?? []
        self.previewItems =
            try container.decodeIfPresent([AssistantSupportPreviewItem].self, forKey: .previewItems) ?? []
        self.activityItems =
            try container.decodeIfPresent([AssistantSupportActivityItem].self, forKey: .activityItems) ?? []
        self.chatToolName =
            try container.decodeIfPresent(String.self, forKey: .chatToolName)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexToolName)
        self.chatToolBatchID =
            try container.decodeIfPresent(UUID.self, forKey: .chatToolBatchID)
            ?? legacyContainer.decodeIfPresent(UUID.self, forKey: .readexToolBatchID)
        self.chatProgressSegmentID =
            try container.decodeIfPresent(UUID.self, forKey: .chatProgressSegmentID)
            ?? legacyContainer.decodeIfPresent(UUID.self, forKey: .readexProgressSegmentID)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        self.progressUpdatedAtMilliseconds =
            try container.decodeIfPresent(Int.self, forKey: .progressUpdatedAtMilliseconds)
        self.progressRatePerSecond = try container.decodeIfPresent(Double.self, forKey: .progressRatePerSecond)
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
        self.phaseTitle = try container.decodeIfPresent(String.self, forKey: .phaseTitle)
        self.subtitleText = try container.decodeIfPresent(String.self, forKey: .subtitleText)
        self.chatTransferTaskID =
            try container.decodeIfPresent(UUID.self, forKey: .chatTransferTaskID)
            ?? legacyContainer.decodeIfPresent(UUID.self, forKey: .readexTransferTaskID)
        self.batchCurrentItemIndex = try container.decodeIfPresent(Int.self, forKey: .batchCurrentItemIndex)
        self.batchCompletedItemCount = try container.decodeIfPresent(Int.self, forKey: .batchCompletedItemCount)
        self.batchTotalItemCount = try container.decodeIfPresent(Int.self, forKey: .batchTotalItemCount)
        self.batchProgress = try container.decodeIfPresent(Double.self, forKey: .batchProgress)
        self.workedForItem = try container.decodeIfPresent(AssistantSupportWorkedForItem.self, forKey: .workedForItem)
        self.chatProcessingGroupID =
            try container.decodeIfPresent(String.self, forKey: .chatProcessingGroupID)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexProcessingGroupId)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexProcessingGroupID)
        self.chatProcessingChromeRole =
            try container.decodeIfPresent(String.self, forKey: .chatProcessingChromeRole)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexProcessingChromeRole)
        self.chatProcessingFoldGroupID =
            try container.decodeIfPresent(String.self, forKey: .chatProcessingFoldGroupID)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexProcessingFoldGroupId)
            ?? legacyContainer.decodeIfPresent(String.self, forKey: .readexProcessingFoldGroupID)
    }
}

enum ExampleChatToolName: String, Codable, CaseIterable, Hashable, Sendable {
    case shell = "workspace.shell"
    case applyPatch = "apply_patch"

    var apiName: String {
        rawValue.replacingOccurrences(of: ".", with: "_")
    }

    init?(apiName: String) {
        let normalized = apiName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "readex.shell" || normalized == "readex_shell" {
            self = .shell
            return
        }
        if let exact = Self(rawValue: normalized) {
            self = exact
            return
        }
        if let match = Self.allCases.first(where: { $0.apiName == normalized }) {
            self = match
            return
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let toolName = Self(apiName: value) {
            self = toolName
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unknown example chat tool name: \(value)"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ExampleChatToolCall: Codable, Hashable, Sendable {
    var id: String
    var name: ExampleChatToolName
    var arguments: [String: ExampleChatJSONValue]

    init(
        id: String = UUID().uuidString,
        name: ExampleChatToolName,
        arguments: [String: ExampleChatJSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct ExampleChatToolResult: Codable, Hashable, Sendable {
    var callID: String
    var name: ExampleChatToolName
    var ok: Bool
    var content: ExampleChatJSONValue?
    var internalContent: ExampleChatJSONValue?
    var errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case callID
        case name
        case ok
        case content
        case errorMessage
    }

    init(
        callID: String,
        name: ExampleChatToolName,
        ok: Bool,
        content: ExampleChatJSONValue?,
        internalContent: ExampleChatJSONValue? = nil,
        errorMessage: String?
    ) {
        self.callID = callID
        self.name = name
        self.ok = ok
        self.content = content
        self.internalContent = internalContent
        self.errorMessage = errorMessage
    }
}

struct ExampleChatProcessingTimerState {
    let displayStartedAt: Date
    var finalizedDurationMilliseconds: Int?

    var isActive: Bool {
        finalizedDurationMilliseconds == nil
    }

    mutating func finalize(at date: Date) -> Int {
        if let finalizedDurationMilliseconds {
            return finalizedDurationMilliseconds
        }
        let duration = max(100, Int(date.timeIntervalSince(displayStartedAt) * 1000))
        finalizedDurationMilliseconds = duration
        return duration
    }
}

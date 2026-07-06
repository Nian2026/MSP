import XCTest
import MSPAgentBridge
@testable import PhotoSorter

final class PhotoSorterChatPersistenceTests: XCTestCase {
    func testTitleStemUsesFirstUserMessageWithSanitizationAndTruncation() {
        XCTAssertEqual(
            PhotoSorterChatPersistence.titleStem(
                from: "  帮我清理一下截图/购物:验证码和快递照片  ",
                maxCharacters: 11
            ),
            "帮我清理一下截图 购物"
        )
    }

    func testTranscriptSnapshotRoundTripsTimelineItems() {
        let items = [
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                kind: .user,
                title: "",
                body: "清理截图",
                turnStartedAtMilliseconds: 1
            ),
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call-1",
                toolName: "exec_command",
                command: "media status",
                stdout: "ok",
                exitCode: 0,
                status: "completed",
                turnStartedAtMilliseconds: 1
            ),
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                kind: .assistantFinal,
                title: "",
                body: "完成",
                turnStartedAtMilliseconds: 1
            )
        ]

        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: items,
            activeChatVirtualPath: "/对话/清理截图.chat"
        )
        let restored = PhotoSorterChatPersistence.transcriptItems(from: snapshot)

        XCTAssertEqual(restored, items)
    }

    func testSubmittedTurnDurabilityRestoresUIAndModelHistoryBeforeAssistantResponse() throws {
        let transcriptItems = [
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                kind: .user,
                title: "",
                body: "帮我解释",
                turnStartedAtMilliseconds: 1,
                sourceTextSelections: [
                    PhotoSorterTextSelectionSnapshot(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                        selectedText: "第一段"
                    )
                ]
            )
        ]
        let modelItems = MSPPlaygroundViewModel.durableCurrentUserModelItems(
            userMessage: "帮我解释",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "第一段")
            ]
        )

        let restoredSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: transcriptItems,
            activeChatVirtualPath: "/对话/帮我解释.chat"
        )

        XCTAssertEqual(
            PhotoSorterChatPersistence.transcriptItems(from: restoredSnapshot),
            transcriptItems
        )
        let message = try XCTUnwrap(modelItems.first?.objectValue)
        XCTAssertEqual(message["role"]?.stringValue, "user")
        let content = try XCTUnwrap(message["content"]?.arrayValue)
        XCTAssertEqual(
            content.first?.objectValue?["text"]?.stringValue,
            "\n# Selected text:\n\n## Selection 1\n第一段\n\n## My request for Codex:\n帮我解释\n"
        )
    }

    func testUIProjectionSnapshotKeepsFullItems() throws {
        let items = (0..<5).map { index in
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
                kind: .assistantFinal,
                title: "",
                body: "消息 \(index)",
                turnStartedAtMilliseconds: index
            )
        }

        let snapshot = PhotoSorterChatPersistence.uiProjectionSnapshot(
            items: items,
            activeChatVirtualPath: "/对话/长对话.chat"
        )
        let projection = try XCTUnwrap(PhotoSorterChatPersistence.uiProjection(from: snapshot))

        XCTAssertEqual(projection.activeChatVirtualPath, "/对话/长对话.chat")
        XCTAssertEqual(projection.projectionVersion, PhotoSorterChatPersistence.uiProjectionVersion)
        XCTAssertNil(projection.sourceFingerprint)
        XCTAssertEqual(projection.totalItemCount, 5)
        XCTAssertEqual(projection.items.map(\.body), ["消息 0", "消息 1", "消息 2", "消息 3", "消息 4"])
    }

    func testUIProjectionSidecarRoundTrips() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatUIProjectionTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let items = [
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                kind: .user,
                title: "",
                body: "第一条"
            ),
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                kind: .assistantFinal,
                title: "",
                body: "第二条"
            )
        ]

        try PhotoSorterChatPersistence.writeUIProjection(
            items: items,
            activeChatVirtualPath: "/对话/预览.chat",
            to: packageURL
        )

        let projection = try XCTUnwrap(PhotoSorterChatPersistence.readUIProjection(from: packageURL))
        XCTAssertEqual(projection.projectionVersion, PhotoSorterChatPersistence.uiProjectionVersion)
        XCTAssertEqual(projection.totalItemCount, 2)
        XCTAssertEqual(projection.items.map(\.body), ["第一条", "第二条"])
    }

    func testCurrentUIProjectionSidecarRequiresMatchingSourceFingerprint() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatUIProjectionPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("indexes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Self.writeManifest(to: packageURL, timelineNextSeq: 8)
        let shortItems = [
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
                kind: .user,
                title: "",
                body: "继续"
            )
        ]
        let longItems = (0..<3).map { index in
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 221))")!,
                kind: .assistantFinal,
                title: "",
                body: "完整消息 \(index)"
            )
        }
        try PhotoSorterChatPersistence.writeUIProjection(
            items: shortItems,
            activeChatVirtualPath: "/对话/短预览.chat",
            to: packageURL
        )
        let transcriptSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: longItems,
            activeChatVirtualPath: "/对话/完整对话.chat"
        )
        let latestState = MSPAgentJSONValue.object([
            "latest_application_snapshots": .object([
                PhotoSorterChatPersistence.transcriptSnapshotType: .object([
                    "snapshot": transcriptSnapshot
                ])
            ])
        ])
        let data = try JSONEncoder().encode(latestState)
        try data.write(
            to: packageURL.appendingPathComponent(PhotoSorterChatPersistence.latestAgentStateRelativePath)
        )

        let projection = try XCTUnwrap(
            PhotoSorterChatPersistence.readCurrentUIProjection(from: packageURL)
        )
        XCTAssertEqual(projection.activeChatVirtualPath, "/对话/短预览.chat")
        XCTAssertEqual(projection.sourceFingerprint, "timeline:timeline.ndjson:next_seq:8")
        XCTAssertEqual(projection.totalItemCount, 1)
        XCTAssertEqual(projection.items.map(\.body), ["继续"])
    }

    func testCurrentUIProjectionRejectsStaleSourceFingerprint() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatStaleSourceUIProjectionTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("indexes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Self.writeManifest(to: packageURL, timelineNextSeq: 9)
        try PhotoSorterChatPersistence.writeUIProjection(
            items: [
                MSPAgentTimelineItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000251")!,
                    kind: .assistantFinal,
                    title: "",
                    body: "旧缓存"
                )
            ],
            activeChatVirtualPath: "/对话/旧缓存.chat",
            to: packageURL,
            sourceFingerprint: "timeline:timeline.ndjson:next_seq:8"
        )

        XCTAssertNil(PhotoSorterChatPersistence.readCurrentUIProjection(from: packageURL))
    }

    func testCurrentUIProjectionDoesNotBuildFromRawLatestAgentState() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatStaleProjectionPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("indexes", isDirectory: true),
            withIntermediateDirectories: true
        )
        let latestItems = (0..<3).map { index in
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 261))")!,
                kind: .assistantFinal,
                title: "",
                body: "权威快照消息 \(index)"
            )
        }
        let transcriptSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: latestItems,
            activeChatVirtualPath: "/对话/权威快照.chat"
        )
        let latestState = MSPAgentJSONValue.object([
            "latest_application_snapshots": .object([
                PhotoSorterChatPersistence.transcriptSnapshotType: .object([
                    "snapshot": transcriptSnapshot
                ])
            ])
        ])
        try JSONEncoder().encode(latestState).write(
            to: packageURL.appendingPathComponent(PhotoSorterChatPersistence.latestAgentStateRelativePath)
        )

        XCTAssertNil(PhotoSorterChatPersistence.readCurrentUIProjection(from: packageURL))
    }

    func testChatPackageEnvelopeValidationReadsManifestButNotTimelineContents() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatEnvelopeTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "format": "msp.chat",
            "version": 1,
            "profiles": ["core-timeline"],
            "timeline": [
                "path": "huge-timeline.ndjson",
                "record_format": "ndjson"
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: packageURL.appendingPathComponent("manifest.json"))
        try Data("{this does not need to be parsed for projection open}\n".utf8)
            .write(to: packageURL.appendingPathComponent("huge-timeline.ndjson"))

        XCTAssertNoThrow(
            try PhotoSorterChatPersistence.validateChatPackageEnvelopeForProjectionOpen(at: packageURL)
        )
    }

    func testWorkspaceChatPackageDeletesToFlatWorkspaceTrashAndRestores() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterChatTrashTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let workspace = PhotoSorterWorkspace(
            localWorkspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount()
        )
        let chatURL = rootURL
            .appendingPathComponent("对话", isDirectory: true)
            .appendingPathComponent("清理截图.chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chatURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: chatURL.appendingPathComponent("manifest.json"))

        try workspace.photoLibraryFileSystem.remove(
            "/对话/清理截图.chat",
            from: "/",
            recursive: true
        )

        let rootNames = try workspace.photoLibraryFileSystem
            .listDirectory("/", from: "/")
            .map(\.name)
        XCTAssertFalse(rootNames.contains("废纸篓"))

        let trashEntries = try workspace.photoLibraryFileSystem
            .listWorkspaceTrashForPresentation(limit: nil)
        XCTAssertEqual(trashEntries.map(\.name), ["清理截图.chat"])
        XCTAssertTrue(trashEntries.first?.virtualPath.contains("/.msp/workspace-trash/items/") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatURL.path))

        let restored = try workspace.photoLibraryFileSystem.restoreWorkspaceTrash(
            at: try XCTUnwrap(trashEntries.first?.virtualPath)
        )

        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatURL.path))
        XCTAssertTrue(try workspace.photoLibraryFileSystem.listWorkspaceTrashForPresentation(limit: nil).isEmpty)
    }

    private static func writeManifest(
        to packageURL: URL,
        timelinePath: String = PhotoSorterChatPersistence.defaultChatTimelinePath,
        timelineNextSeq: Int
    ) throws {
        let manifest: [String: Any] = [
            "format": "msp.chat",
            "version": 1,
            "profiles": ["core-timeline"],
            "timeline": [
                "path": timelinePath,
                "record_format": "ndjson",
                "next_seq": timelineNextSeq
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: packageURL.appendingPathComponent("manifest.json"))
    }
}

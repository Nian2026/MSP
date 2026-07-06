import Combine
import Photos
import MSPAgentBridge
import MSPCore
import XCTest
@testable import PhotoSorter

final class MSPPlaygroundViewModelTests: XCTestCase {
    @MainActor
    func testTranscriptMutationDoesNotInvalidateWholeViewModel() {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        var objectWillChangeCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            objectWillChangeCount += 1
        }

        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .assistantFinal,
            title: "",
            body: "streaming text"
        ))

        XCTAssertEqual(objectWillChangeCount, 0)
        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, 1)
        cancellable.cancel()
    }

    @MainActor
    func testRunningToolOutputStreamsWithoutFullTranscriptRenderRebuild() {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_063_900
        let batchID = UUID(uuidString: "00000000-0000-4000-8000-000000000399")!
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "跑一个长命令",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        viewModel.applyAgentEventForTesting(
            .toolPreparing(.execCommand, statusText: "正在执行工作区命令"),
            turnStartedAtMilliseconds: turnStartedAt
        )
        let stateRevisionAfterPreparing = viewModel.transcriptRenderController.snapshot.stateRevision
        let call = MSPAgentToolCall(
            id: "call_streaming_tool",
            name: .execCommand,
            arguments: [
                "cmd": .string("printf hello")
            ]
        )
        viewModel.applyAgentEventForTesting(
            .toolStarted(call, statusText: "正在执行工作区命令", batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )
        let stateRevisionAfterStart = viewModel.transcriptRenderController.snapshot.stateRevision
        let streamingRevisionAfterStart = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision
        XCTAssertEqual(stateRevisionAfterStart, stateRevisionAfterPreparing)
        XCTAssertNil(viewModel.transcriptRenderController.snapshot.state)

        viewModel.applyAgentEventForTesting(
            .toolOutputDelta(
                callID: "call_streaming_tool",
                name: .execCommand,
                stream: .stdout,
                text: "hello\n"
            ),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolCompleted(MSPAgentToolResult(
                callID: "call_streaming_tool",
                name: .execCommand,
                ok: true,
                content: .string("hello\n"),
                internalContent: .object([
                    "cmd": .string("printf hello"),
                    "stdout": .string("hello\n"),
                    "stderr": .string(""),
                    "exit_code": .number(0)
                ]),
                errorMessage: nil
            ), batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterStart)
        XCTAssertGreaterThan(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterStart
        )
        XCTAssertNil(viewModel.transcriptRenderController.snapshot.state)
        XCTAssertEqual(viewModel.transcript.first { $0.callID == "call_streaming_tool" }?.stdout, "hello\n")
        XCTAssertEqual(viewModel.transcript.first { $0.callID == "call_streaming_tool" }?.status, "completed")
    }

    @MainActor
    func testInitialFinalAnswerDeltaAppendsImmediatelyFromEmptyRenderedItem() async throws {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_064_100
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "写一段回复",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        viewModel.applyAgentEventForTesting(
            .finalAnswerStarted,
            turnStartedAtMilliseconds: turnStartedAt
        )
        let stateRevisionAfterStarted = try XCTUnwrap(
            viewModel.transcriptRenderController.snapshot.stateRevision
        )
        let streamingRevisionAfterStarted = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision

        viewModel.applyAgentEventForTesting(
            .finalAnswerDelta("第一块回复"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterStarted + 1)
        XCTAssertEqual(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterStarted
        )
        XCTAssertNotNil(viewModel.transcriptRenderController.snapshot.state)
        XCTAssertNil(viewModel.transcriptRenderController.snapshot.streamingUpdate)
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistantFinal)
        XCTAssertEqual(viewModel.transcript.last?.body, "第一块回复")
    }

    @MainActor
    func testFinalAnswerDeltasStreamWithoutFullTranscriptRenderRebuildAfterInitialText() throws {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_064_101
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "慢慢吐字",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        viewModel.applyAgentEventForTesting(
            .finalAnswerStarted,
            turnStartedAtMilliseconds: turnStartedAt
        )
        let streamingRevisionAfterStarted = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision
        let stateRevisionAfterStarted = try XCTUnwrap(
            viewModel.transcriptRenderController.snapshot.stateRevision
        )

        viewModel.applyAgentEventForTesting(
            .finalAnswerDelta("你"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterStarted
        )
        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterStarted + 1)
        XCTAssertEqual(viewModel.transcript.last?.body, "你")
        let stateRevisionAfterInitialText = viewModel.transcriptRenderController.snapshot.stateRevision
        let streamingRevisionAfterInitialText = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision

        viewModel.applyAgentEventForTesting(
            .finalAnswerDelta("好"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterInitialText + 1
        )
        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterInitialText)
        let update = try XCTUnwrap(viewModel.transcriptRenderController.snapshot.streamingUpdate?.updates.first)
        XCTAssertEqual(update["kind"] as? String, "main_text")
        XCTAssertEqual(update["previousTextLength"] as? Int, 1)
        XCTAssertEqual(update["appendText"] as? String, "好")
        XCTAssertEqual(update["text"] as? String, "你好")
        XCTAssertNil(viewModel.transcriptRenderController.snapshot.state)
        XCTAssertEqual(viewModel.transcript.last?.body, "你好")
    }

    @MainActor
    func testAssistantProgressDeltasStreamWithoutFullTranscriptRenderRebuildAfterInitialText() throws {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_064_103
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "先说一下你在做什么",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        let stateRevisionAfterUser = try XCTUnwrap(
            viewModel.transcriptRenderController.snapshot.stateRevision
        )
        let streamingRevisionAfterUser = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision

        viewModel.applyAgentEventForTesting(
            .assistantProgressDelta("我"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterUser + 1)
        XCTAssertEqual(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterUser
        )
        XCTAssertEqual(viewModel.transcript.last?.kind, .assistantProgress)
        XCTAssertEqual(viewModel.transcript.last?.body, "我")
        let stateRevisionAfterInitialText = viewModel.transcriptRenderController.snapshot.stateRevision
        let streamingRevisionAfterInitialText = viewModel.transcriptRenderController.snapshot.streamingUpdateRevision

        viewModel.applyAgentEventForTesting(
            .assistantProgressDelta("先"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(viewModel.transcriptRenderController.snapshot.stateRevision, stateRevisionAfterInitialText)
        XCTAssertEqual(
            viewModel.transcriptRenderController.snapshot.streamingUpdateRevision,
            streamingRevisionAfterInitialText + 1
        )
        XCTAssertEqual(viewModel.transcript.last?.body, "我先")
        XCTAssertNil(viewModel.transcriptRenderController.snapshot.state)
        let update = try XCTUnwrap(viewModel.transcriptRenderController.snapshot.streamingUpdate?.updates.first)
        XCTAssertEqual(update["kind"] as? String, "chat_progress")
        XCTAssertEqual(update["previousTextLength"] as? Int, 1)
        XCTAssertEqual(update["appendText"] as? String, "先")
        XCTAssertEqual(update["text"] as? String, "我先")
    }

    @MainActor
    func testFinalAnswerEventReplacesStreamingTranscriptImmediately() throws {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_064_102
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "完整回答也要慢慢显示",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        viewModel.applyAgentEventForTesting(
            .finalAnswerStarted,
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .finalAnswerDelta("你"),
            turnStartedAtMilliseconds: turnStartedAt
        )
        XCTAssertEqual(viewModel.transcript.last?.body, "你")

        viewModel.applyAgentEventForTesting(
            .finalAnswer("你好世界"),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertEqual(viewModel.transcript.last?.body, "你好世界")
    }

    @MainActor
    func testRuntimeErrorFlushesPendingToolOutputBeforeErrorItem() {
        let viewModel = MSPPlaygroundViewModel(loadCodexOAuthConfiguration: { .empty })
        let turnStartedAt = 1_772_000_063_901
        let batchID = UUID(uuidString: "00000000-0000-4000-8000-000000000401")!
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "继续清理照片",
            turnStartedAtMilliseconds: turnStartedAt
        ))
        let call = MSPAgentToolCall(
            id: "call_before_error",
            name: .execCommand,
            arguments: [
                "cmd": .string("media search --ocr 游戏 --from-file /tmp/batch.txt")
            ]
        )
        viewModel.applyAgentEventForTesting(
            .toolStarted(call, statusText: "正在执行工作区命令", batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolOutputDelta(
                callID: "call_before_error",
                name: .execCommand,
                stream: .stdout,
                text: "/相册/系统/截图/a.png\n"
            ),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertNil(viewModel.transcript.first { $0.callID == "call_before_error" }?.stdout)

        viewModel.applyRuntimeErrorForTesting(
            "模型请求失败：The model provider returned HTTP 429",
            turnStartedAtMilliseconds: turnStartedAt
        )

        let toolItem = viewModel.transcript.first { $0.callID == "call_before_error" }
        XCTAssertEqual(toolItem?.stdout, "/相册/系统/截图/a.png\n")
        XCTAssertEqual(viewModel.transcript.last?.kind, .error)
        XCTAssertEqual(
            viewModel.transcript.last?.body,
            "模型请求失败：The model provider returned HTTP 429"
        )
        XCTAssertTrue(
            viewModel.failedTurnRecordedForTesting(turnStartedAtMilliseconds: turnStartedAt)
        )
    }

    func testFailedTurnKeepsLatestIncrementalModelHistoryWhenFinalSnapshotRegresses() {
        let userMessage = MSPAgentJSONValue.object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string("继续清理")
                ])
            ])
        ])
        let toolCall = MSPAgentJSONValue.object([
            "type": .string("function_call"),
            "call_id": .string("call_1"),
            "name": .string("exec_command"),
            "arguments": .string("{\"cmd\":\"media search --ocr 游戏 --from-file /tmp/batch.txt\"}")
        ])
        let toolOutput = MSPAgentJSONValue.object([
            "type": .string("function_call_output"),
            "call_id": .string("call_1"),
            "output": .string("/相册/系统/截图/a.png\n")
        ])
        let regressedFinalSnapshot = [userMessage]
        let latestIncrementalHistory = [userMessage, toolCall, toolOutput]

        let failedHistory = MSPPlaygroundViewModel.modelHistoryByPreservingActiveTurnHistoryForFailedTurn(
            finalModelHistory: regressedFinalSnapshot,
            latestActiveTurnModelHistory: latestIncrementalHistory,
            status: "failed"
        )
        let completedHistory = MSPPlaygroundViewModel.modelHistoryByPreservingActiveTurnHistoryForFailedTurn(
            finalModelHistory: regressedFinalSnapshot,
            latestActiveTurnModelHistory: latestIncrementalHistory,
            status: "completed"
        )

        XCTAssertEqual(failedHistory, latestIncrementalHistory)
        XCTAssertEqual(completedHistory, regressedFinalSnapshot)
    }

    func testDurableTranscriptSnapshotDoesNotMergeModelHistoryIntoVisibleRuntimeError() {
        let visibleTranscript = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "继续清理"
            ),
            MSPAgentTimelineItem(
                kind: .error,
                title: "Error",
                body: "模型请求失败：stream error"
            )
        ]

        let merged = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: visibleTranscript
        )

        XCTAssertEqual(merged.map(\.kind), [.user, .error])
        XCTAssertFalse(merged.contains { $0.body.contains("assistant 历史来自源数据") })
        XCTAssertEqual(merged.last?.body, "模型请求失败：stream error")
    }

    func testOpeningChatPackageKeepsApplicationSnapshotAssistantInsteadOfModelHistoryAssistant() {
        let snapshotItems = [
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                kind: .user,
                title: "",
                body: "继续"
            ),
            MSPAgentTimelineItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
                kind: .assistantFinal,
                title: "",
                body: "本轮完成"
            )
        ]
        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: snapshotItems,
            activeChatVirtualPath: "/对话/删除100张照片.chat"
        )
        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: snapshot
        )

        XCTAssertEqual(restored.map(\.body), ["继续", "本轮完成"])
        XCTAssertFalse(restored.contains { $0.body == "当前文件树显示：这是一段旧回复" })
    }

    func testOpeningChatPackageRepairsPersistedDuplicateFinalsAndStreamingFragments() throws {
        let firstUserStartedAt = 1_772_000_001_000
        let secondUserStartedAt = 1_772_000_002_000
        let selectedUserStartedAt = 1_772_000_003_000
        let firstFinal = "当前照片工作区树概览：/图库 41881"
        let secondFinal = "已调用命令查看，当前树如下：/图库 41881"
        let selectedPrompt = PhotoSorterSelectedTextPromptFormatter.prompt(
            userPrompt: "以及你认为的垃圾照片",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "截图里的临时信息")
            ]
        )
        let selectedFinal = "已处理完成：本轮合计移入最近删除 111 张"
        let pollutedSnapshotItems = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "看一下当前文件树",
                turnStartedAtMilliseconds: firstUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: firstFinal,
                turnStartedAtMilliseconds: firstUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "调用命令看",
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我用 PhotoSorter 的文件树命令刷新一下当前视图。",
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call_filetree",
                toolName: "exec_command",
                command: "filetree ls /",
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolResult,
                title: "工作区命令",
                body: "Wall time: 0.02 seconds\nProcess exited with code 0\nOutput: /图库\n",
                callID: "call_filetree",
                toolName: "exec_command",
                stdout: "/图库\n",
                exitCode: 0,
                parentCallID: "call_filetree",
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "已",
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: firstFinal,
                turnStartedAtMilliseconds: firstUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: secondFinal,
                turnStartedAtMilliseconds: secondUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: selectedPrompt,
                turnStartedAtMilliseconds: selectedUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: selectedFinal,
                turnStartedAtMilliseconds: selectedUserStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "以及你认为的垃圾照片",
                turnStartedAtMilliseconds: selectedUserStartedAt,
                sourceTextSelections: [
                    PhotoSorterTextSelectionSnapshot(selectedText: "截图里的临时信息")
                ]
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: selectedFinal,
                turnStartedAtMilliseconds: selectedUserStartedAt
            )
        ]
        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: pollutedSnapshotItems,
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )
        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: snapshot
        )

        let expectedKinds: [MSPAgentTimelineItem.Kind] = [
            .user,
            .assistantFinal,
            .user,
            .assistantProgress,
            .toolCall,
            .assistantFinal,
            .user,
            .assistantFinal
        ]
        XCTAssertEqual(restored.map { $0.kind }, expectedKinds)
        XCTAssertEqual(restored.map { $0.body }, [
            "看一下当前文件树",
            firstFinal,
            "调用命令看",
            "我用 PhotoSorter 的文件树命令刷新一下当前视图。",
            "已执行工作区命令",
            secondFinal,
            "以及你认为的垃圾照片",
            selectedFinal
        ])
        let toolCard = try XCTUnwrap(restored.first { $0.kind == .toolCall })
        XCTAssertEqual(toolCard.stdout, "/图库\n")
        XCTAssertEqual(toolCard.exitCode, 0)
        XCTAssertEqual(restored.filter { $0.body == firstFinal }.count, 1)
        XCTAssertEqual(restored.filter { $0.body == selectedFinal }.count, 1)
        XCTAssertFalse(restored.contains { $0.body == "已" })
        XCTAssertEqual(restored.filter { $0.kind == .user && $0.body == "以及你认为的垃圾照片" }.count, 1)
        XCTAssertEqual(
            restored.first { $0.body == "以及你认为的垃圾照片" }?.sourceTextSelections.map { $0.selectedText },
            ["截图里的临时信息"]
        )
    }

    func testOpeningChatPackageBuildsUIProjectionFromApplicationSnapshotOnly() throws {
        let selectedPrompt = PhotoSorterSelectedTextPromptFormatter.prompt(
            userPrompt: "以及你认为的垃圾照片",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "截图里的临时信息")
            ]
        )
        let firstTurn = 1_772_000_001_000
        let secondTurn = 1_772_000_002_000
        let selectedTurn = 1_772_000_003_000
        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: "看一下当前文件树",
                    turnStartedAtMilliseconds: firstTurn
                ),
                MSPAgentTimelineItem(
                    kind: .assistantProgress,
                    title: "模型中间回复",
                    body: "当前照片工作区树概览：/图库 41881",
                    turnStartedAtMilliseconds: firstTurn
                ),
                MSPAgentTimelineItem(
                    kind: .assistantFinal,
                    title: "",
                    body: "当前照片工作区树概览：/图库 41881",
                    turnStartedAtMilliseconds: firstTurn
                ),
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: "调用命令看",
                    turnStartedAtMilliseconds: secondTurn
                ),
                MSPAgentTimelineItem(
                    kind: .assistantProgress,
                    title: "模型中间回复",
                    body: "已",
                    turnStartedAtMilliseconds: secondTurn
                ),
                MSPAgentTimelineItem(
                    kind: .assistantFinal,
                    title: "",
                    body: "已调用命令查看，当前树如下：/图库 41881",
                    turnStartedAtMilliseconds: secondTurn
                ),
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: selectedPrompt,
                    turnStartedAtMilliseconds: selectedTurn
                ),
                MSPAgentTimelineItem(
                    kind: .assistantFinal,
                    title: "",
                    body: "可以，我先按这个范围继续筛。",
                    turnStartedAtMilliseconds: selectedTurn
                )
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )

        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: snapshot
        )

        XCTAssertEqual(restored.map(\.kind), [
            .user,
            .assistantFinal,
            .user,
            .assistantFinal,
            .user,
            .assistantFinal
        ])
        XCTAssertEqual(restored.map(\.body), [
            "看一下当前文件树",
            "当前照片工作区树概览：/图库 41881",
            "调用命令看",
            "已调用命令查看，当前树如下：/图库 41881",
            "以及你认为的垃圾照片",
            "可以，我先按这个范围继续筛。"
        ])
        XCTAssertFalse(restored.contains { $0.body == "已" })
        XCTAssertFalse(restored.contains { $0.body.contains("# Selected text") })
        XCTAssertEqual(
            restored.first { $0.body == "以及你认为的垃圾照片" }?.sourceTextSelections.map(\.selectedText),
            ["截图里的临时信息"]
        )
    }

    func testCurrentUIProjectionDoesNotTrustOldPreviewOrLatestAgentState() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSorterOldPreviewIsolationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
        }
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("indexes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Self.writeChatManifest(to: packageURL, timelineNextSeq: 8)

        let oldPreviewURL = packageURL
            .appendingPathComponent("indexes", isDirectory: true)
            .appendingPathComponent("photosorter-transcript-preview.json")
        let oldPreview = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第二答"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第一答")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )
        try JSONEncoder().encode(oldPreview).write(to: oldPreviewURL)

        let uiSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第一答"),
                MSPAgentTimelineItem(kind: .user, title: "", body: "第二问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第二答")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )
        let compactedModelHistory = [
            Self.modelUser("第一问"),
            Self.modelUser("第二问"),
            Self.compactionSummaryUserMessage("压缩摘要不应该显示在 UI 里")
        ]
        let latestState = MSPAgentJSONValue.object([
            "source_fingerprint": .string("timeline:timeline.ndjson:next_seq:8"),
            "model_visible_history": .array(compactedModelHistory),
            "latest_application_snapshots": .object([
                PhotoSorterChatPersistence.transcriptSnapshotType: .object([
                    "snapshot": uiSnapshot
                ])
            ])
        ])
        try JSONEncoder().encode(latestState).write(
            to: packageURL.appendingPathComponent(PhotoSorterChatPersistence.latestAgentStateRelativePath)
        )

        XCTAssertNil(PhotoSorterChatPersistence.readCurrentUIProjection(from: packageURL))
    }

    func testOpeningChatPackageRemovesStreamingFragmentEvenWhenAnotherFinalIntervenes() {
        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "继续"),
                MSPAgentTimelineItem(kind: .assistantProgress, title: "模型中间回复", body: "已"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "先补一句不会覆盖前缀的旧回复"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "已处理完成：这才是完整回复")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )

        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: snapshot
        )

        XCTAssertEqual(restored.map(\.body), [
            "继续",
            "先补一句不会覆盖前缀的旧回复",
            "已处理完成：这才是完整回复"
        ])
        XCTAssertFalse(restored.contains { $0.body == "已" })
    }

    func testOpeningChatPackageRepairsApplicationSnapshotWithoutUsingModelHistoryAsTimelineAuthority() {
        let snapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .assistantProgress, title: "模型中间回复", body: "第一答"),
                MSPAgentTimelineItem(kind: .user, title: "", body: "第二问"),
                MSPAgentTimelineItem(kind: .assistantProgress, title: "模型中间回复", body: "已"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第一答"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第二答")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )

        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            latestApplicationStateSnapshot: snapshot
        )

        XCTAssertEqual(restored.map(\.body), ["第一问", "第一答", "第二问", "第二答"])
        XCTAssertEqual(restored.map(\.kind), [.user, .assistantFinal, .user, .assistantFinal])
    }

    func testOpeningChatPackageFallsBackToOlderApplicationSnapshotWhenLatestContainsCompactionSummary() {
        let olderSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第一答"),
                MSPAgentTimelineItem(kind: .user, title: "", body: "第二问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第二答")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )
        let pollutedLatestSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .user, title: "", body: "第二问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: Self.compactionSummaryText("坏摘要"))
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )

        let restored = MSPPlaygroundViewModel.transcriptItemsForOpeningChatPackage(
            applicationStateSnapshots: [olderSnapshot, pollutedLatestSnapshot],
            latestApplicationStateSnapshot: pollutedLatestSnapshot
        )

        XCTAssertEqual(restored.map(\.body), ["第一问", "第一答", "第二问", "第二答"])
        XCTAssertFalse(restored.contains { $0.body.hasPrefix("Another language model started") })
    }

    func testDurableTranscriptSnapshotDoesNotUseCompactedModelHistoryAsUISource() {
        let existingSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "第一问"),
                MSPAgentTimelineItem(kind: .assistantFinal, title: "", body: "第一答")
            ],
            activeChatVirtualPath: "/对话/看一下当前文件树 2.chat"
        )

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: [],
            existingSnapshot: existingSnapshot
        )

        XCTAssertEqual(restored.map(\.body), ["第一问", "第一答"])
        XCTAssertEqual(restored.map(\.kind), [.user, .assistantFinal])
        XCTAssertFalse(restored.contains { $0.body.hasPrefix("Another language model started") })
    }

    func testDurableTranscriptSnapshotKeepsSelectedTextUISeparateFromModelPrompt() throws {
        let selectionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000401"))
        let selection = PhotoSorterTextSelectionSnapshot(
            id: selectionID,
            selectedText: "图2部分应该显示成胶囊"
        )
        let visibleTranscript = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "能理解吗",
                sourceTextSelections: [selection]
            )
        ]

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: visibleTranscript
        )

        XCTAssertEqual(restored.map(\.kind), [.user])
        let userItem = try XCTUnwrap(restored.first)
        XCTAssertEqual(userItem.body, "能理解吗")
        XCTAssertFalse(userItem.body.contains("# Selected text"))
        XCTAssertEqual(userItem.sourceTextSelections.map(\.id), [selectionID])
        XCTAssertEqual(userItem.sourceTextSelections.map(\.selectedText), ["图2部分应该显示成胶囊"])
    }

    func testDurableTranscriptSnapshotRepairsPersistedSelectedTextModelPromptUserBubble() throws {
        let modelPrompt = PhotoSorterSelectedTextPromptFormatter.prompt(
            userPrompt: "去修",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "第一段选中内容"),
                PhotoSorterTextSelectionSnapshot(selectedText: "第二段选中内容")
            ]
        )
        let pollutedSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: modelPrompt
                )
            ],
            activeChatVirtualPath: "/对话/测试.chat"
        )

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: [],
            existingSnapshot: pollutedSnapshot
        )

        XCTAssertEqual(restored.map(\.kind), [.user])
        let userItem = try XCTUnwrap(restored.first)
        XCTAssertEqual(userItem.body, "去修")
        XCTAssertFalse(userItem.body.contains("# Selected text"))
        XCTAssertEqual(
            userItem.sourceTextSelections.map(\.selectedText),
            ["第一段选中内容", "第二段选中内容"]
        )
    }

    func testDurableTranscriptSnapshotDoesNotInsertModelPromptUserFromModelHistory() throws {
        let selection = PhotoSorterTextSelectionSnapshot(selectedText: "当前截图里的错乱 UI")
        let visibleTranscript = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "去修",
                sourceTextSelections: [selection]
            ),
            MSPAgentTimelineItem(
                kind: .error,
                title: "Error",
                body: "模型请求失败"
            )
        ]

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: visibleTranscript
        )

        XCTAssertEqual(restored.map(\.kind), [.user, .error])
        XCTAssertEqual(restored.filter { $0.kind == .user }.count, 1)
        let userItem = try XCTUnwrap(restored.first)
        XCTAssertEqual(userItem.body, "去修")
        XCTAssertFalse(userItem.body.contains("# Selected text"))
        XCTAssertEqual(userItem.sourceTextSelections.map(\.selectedText), ["当前截图里的错乱 UI"])
    }

    func testDurableTranscriptSnapshotRestoresApplicationSnapshotToolOutputAsShellExecution() throws {
        let output = """
        Wall time: 0.0211 seconds
        Process exited with code 0
        Output: /相册/系统/截图/767b1fcecfdd.png: 20:12 98 Caxe = mm 6xIT
        """
        let commandOutput = "/相册/系统/截图/767b1fcecfdd.png: 20:12 98 Caxe = mm 6xIT"
        let existingSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "读 OCR"),
                MSPAgentTimelineItem(
                    kind: .toolCall,
                    title: "工作区命令",
                    body: "正在执行工作区命令",
                    callID: "call_ocr",
                    toolName: "exec_command",
                    command: "media show --ocr /相册/系统/截图/767b1fcecfdd.png",
                    cwd: "/",
                    status: "inProgress"
                ),
                MSPAgentTimelineItem(
                    kind: .toolResult,
                    title: "工作区命令",
                    body: output,
                    callID: "call_ocr",
                    toolName: "exec_command",
                    parentCallID: "call_ocr"
                )
            ],
            activeChatVirtualPath: "/对话/读 OCR.chat"
        )

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: [],
            existingSnapshot: existingSnapshot
        )

        XCTAssertEqual(restored.map(\.kind), [.user, .toolCall])
        let restoredTool = try XCTUnwrap(restored.first { $0.kind == .toolCall })
        XCTAssertEqual(restoredTool.body, "已执行工作区命令")
        XCTAssertEqual(restoredTool.command, "media show --ocr /相册/系统/截图/767b1fcecfdd.png")
        XCTAssertEqual(restoredTool.cwd, "/")
        XCTAssertEqual(restoredTool.stdout, commandOutput)
        XCTAssertEqual(restoredTool.exitCode, 0)
        XCTAssertEqual(restoredTool.durationMilliseconds, 21)

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: restored, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        XCTAssertEqual(assistant["content"] as? String, "")

        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_tool_call" })
        XCTAssertEqual(toolBlock["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((toolBlock["text"] as? String ?? "").contains("Wall time"))

        let activityItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(activityItems.first { ($0["type"] as? String) == "chatToolCall" })
        XCTAssertNil(toolItem["legacyType"])
        XCTAssertEqual(toolItem["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((toolItem["text"] as? String ?? "").contains("Process exited"))

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["command"] as? String, "media show --ocr /相册/系统/截图/767b1fcecfdd.png")
        XCTAssertEqual(shellExecution["output"] as? String, commandOutput)
        XCTAssertEqual(shellExecution["exitCode"] as? Int, 0)
        XCTAssertEqual(shellExecution["wallTimeSeconds"] as? Double, 0.021)
    }

    func testDurableTranscriptSnapshotDoesNotRestoreUpdatePlanAsShellExecution() throws {
        let existingSnapshot = PhotoSorterChatPersistence.transcriptSnapshot(
            items: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "整理相册"),
                MSPAgentTimelineItem(
                    kind: .toolCall,
                    title: "工作区命令",
                    body: "已执行工作区命令",
                    callID: "call_plan",
                    toolName: MSPUpdatePlanToolSchema.name,
                    status: "completed"
                ),
                MSPAgentTimelineItem(
                    kind: .toolResult,
                    title: "工作区命令",
                    body: "Plan updated",
                    callID: "call_plan",
                    toolName: MSPUpdatePlanToolSchema.name,
                    parentCallID: "call_plan"
                )
            ],
            activeChatVirtualPath: "/对话/整理相册.chat"
        )

        let restored = MSPPlaygroundViewModel.durableTranscriptItemsForPersistence(
            visibleTranscript: [],
            existingSnapshot: existingSnapshot
        )

        XCTAssertEqual(restored.map(\.kind), [.user])
        XCTAssertFalse(restored.contains { $0.toolName == MSPUpdatePlanToolSchema.name })

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: restored, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    @MainActor
    func testWorkspaceMediaPreviewKeepsCachedContentWhenWorkspaceCacheVersionIsUnchanged() {
        let preview = Self.workspaceMediaPreview(cacheVersionToken: "index-ready-1-workspace-0")

        XCTAssertFalse(
            preview.invalidateCachedContentIfWorkspaceChanged(to: "index-ready-1-workspace-0")
        )

        XCTAssertEqual(preview.imageData, Data([0x01, 0x02]))
        XCTAssertEqual(preview.media?.path, "/图库/a.jpg")
        XCTAssertEqual(preview.message, "old message")
        XCTAssertEqual(preview.galleryItems.map(\.path), ["/图库/a.jpg", "/图库/b.jpg"])
        XCTAssertEqual(preview.galleryImageDataByPath["/图库/a.jpg"], Data([0x01, 0x02]))
        XCTAssertEqual(preview.galleryMediaByPath["/图库/b.jpg"]?.path, "/图库/b.jpg")
        XCTAssertEqual(preview.galleryMessageByPath["/图库/missing.jpg"], "missing")
        XCTAssertTrue(preview.galleryLoadingPaths.contains("/图库/loading.jpg"))
        XCTAssertTrue(preview.galleryHasMoreNodes)
        XCTAssertEqual(preview.galleryLoadedNodeCount, 2)
        XCTAssertEqual(preview.workspaceCacheVersionToken, "index-ready-1-workspace-0")
    }

    @MainActor
    func testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges() {
        let preview = Self.workspaceMediaPreview(cacheVersionToken: "index-ready-1-workspace-0")

        XCTAssertTrue(
            preview.invalidateCachedContentIfWorkspaceChanged(to: "index-ready-1-workspace-1")
        )

        XCTAssertNil(preview.imageData)
        XCTAssertNil(preview.media)
        XCTAssertNil(preview.message)
        XCTAssertFalse(preview.isLoading)
        XCTAssertFalse(preview.isLoadingMoreGalleryItems)
        XCTAssertEqual(preview.galleryItems, [])
        XCTAssertEqual(preview.galleryLoadedNodeCount, 0)
        XCTAssertFalse(preview.galleryHasMoreNodes)
        XCTAssertEqual(preview.galleryImageDataByPath, [:])
        XCTAssertEqual(preview.galleryMediaByPath, [:])
        XCTAssertEqual(preview.galleryMessageByPath, [:])
        XCTAssertEqual(preview.galleryLoadingPaths, [])
        XCTAssertEqual(preview.workspaceCacheVersionToken, "index-ready-1-workspace-1")
    }

    @MainActor
    func testReloadModelConfigurationRefreshesStaleInMemoryConfiguration() {
        var storedConfiguration = Self.configuration(
            baseURL: "https://stored.example.test/v1",
            apiKey: "stored-key",
            modelID: "stored-model"
        )
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                storedConfiguration
            },
            saveModelConfiguration: { configuration in
                storedConfiguration = configuration
            },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )

        viewModel.modelConfiguration = Self.configuration(
            baseURL: "https://api.openai.com/v1",
            apiKey: "",
            modelID: "gpt-5"
        )
        storedConfiguration = Self.configuration(
            baseURL: "https://persisted.example.test/v1/responses",
            apiKey: "persisted-key",
            modelID: "gpt-5.5"
        )

        let reloaded = viewModel.reloadModelConfiguration()

        XCTAssertEqual(reloaded.baseURL?.absoluteString, "https://persisted.example.test/v1/responses")
        XCTAssertEqual(reloaded.apiKey, "persisted-key")
        XCTAssertEqual(reloaded.modelID, "gpt-5.5")
        XCTAssertEqual(viewModel.modelConfiguration, reloaded)
    }

    @MainActor
    func testSaveModelConfigurationReloadsCanonicalStoredConfiguration() {
        var storedConfiguration = Self.configuration(
            baseURL: "https://stored.example.test/v1",
            apiKey: "stored-key",
            modelID: "stored-model"
        )
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                storedConfiguration
            },
            saveModelConfiguration: { configuration in
                storedConfiguration = configuration
            },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )

        viewModel.modelConfiguration = MSPModelConfiguration(
            providerName: " Provider ",
            baseURL: URL(string: "https://saved.example.test/v1"),
            apiKey: " saved-key ",
            modelID: " saved-model ",
            apiStyle: " responses ",
            endpointType: " openai-response ",
            endpointPathOverride: " /custom/responses ",
            reasoningEffort: " high ",
            verbosity: " low "
        )

        XCTAssertTrue(viewModel.saveModelConfiguration())
        XCTAssertEqual(storedConfiguration.baseURL?.absoluteString, "https://saved.example.test/v1")
        XCTAssertEqual(storedConfiguration.apiKey, "saved-key")
        XCTAssertEqual(storedConfiguration.modelID, "saved-model")
        XCTAssertEqual(storedConfiguration.reasoningEffort, "high")
        XCTAssertEqual(storedConfiguration.verbosity, "low")
        XCTAssertEqual(viewModel.modelConfiguration, storedConfiguration)
    }

    func testStructuredShellJSONLeakIgnoresModelAuthoredPythonDictionaryKeys() {
        let pythonSource = """
        def run_cmd(cmd):
            p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return {
                "cmd": " ".join(cmd),
                "returncode": p.returncode,
                "stdout": p.stdout,
                "stderr": p.stderr,
            }
        """

        XCTAssertFalse(MSPPlaygroundViewModel.containsStructuredShellJSONLeak(in: pythonSource))
    }

    func testStructuredShellJSONLeakDetectsRenderedInternalResultObject() {
        let leakedToolResult = """
        {"stdout":"done\\n","stderr":"","exit_code":0}
        """

        XCTAssertTrue(MSPPlaygroundViewModel.containsStructuredShellJSONLeak(in: leakedToolResult))
    }

    @MainActor
    func testSelectAgentAccessModePersistsSelection() {
        var storedAccessMode = PhotoSorterAgentAccessMode.standard
        var storedSensitiveReadPolicy = PhotoSorterSensitiveReadPolicy.askEveryTime
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            },
            loadAgentAccessMode: {
                storedAccessMode
            },
            saveAgentAccessMode: { mode in
                storedAccessMode = mode
            },
            loadSensitiveReadPolicy: {
                storedSensitiveReadPolicy
            },
            saveSensitiveReadPolicy: { policy in
                storedSensitiveReadPolicy = policy
            }
        )

        XCTAssertEqual(viewModel.agentAccessMode, .standard)

        viewModel.selectAgentAccessMode(.full)

        XCTAssertEqual(viewModel.agentAccessMode, .full)
        XCTAssertEqual(storedAccessMode, .full)
    }

    @MainActor
    func testSelectSensitiveReadPolicyPersistsSelection() {
        var storedSensitiveReadPolicy = PhotoSorterSensitiveReadPolicy.askEveryTime
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            },
            loadAgentAccessMode: {
                .standard
            },
            saveAgentAccessMode: { _ in },
            loadSensitiveReadPolicy: {
                storedSensitiveReadPolicy
            },
            saveSensitiveReadPolicy: { policy in
                storedSensitiveReadPolicy = policy
            }
        )

        XCTAssertEqual(viewModel.sensitiveReadPolicy, .askEveryTime)

        viewModel.selectSensitiveReadPolicy(.alwaysAllow)

        XCTAssertEqual(viewModel.sensitiveReadPolicy, .alwaysAllow)
        XCTAssertEqual(storedSensitiveReadPolicy, .alwaysAllow)
    }

    @MainActor
    func testStartPlaceCachePreheatPersistsRunningModeInFullAccess() {
        var storedPlaceCacheTaskMode = PhotoSorterPlaceCacheTaskMode.idle
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            },
            loadAgentAccessMode: {
                .full
            },
            saveAgentAccessMode: { _ in },
            loadSensitiveReadPolicy: {
                .askEveryTime
            },
            saveSensitiveReadPolicy: { _ in },
            loadPlaceCacheTaskMode: {
                storedPlaceCacheTaskMode
            },
            savePlaceCacheTaskMode: { mode in
                storedPlaceCacheTaskMode = mode
            }
        )

        viewModel.startPlaceCachePreheatBatch()

        XCTAssertEqual(storedPlaceCacheTaskMode, .running)
    }

    @MainActor
    func testStartPlaceCachePreheatDoesNotPersistRunningOutsideFullAccess() {
        var storedPlaceCacheTaskMode = PhotoSorterPlaceCacheTaskMode.idle
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            },
            loadAgentAccessMode: {
                .standard
            },
            saveAgentAccessMode: { _ in },
            loadSensitiveReadPolicy: {
                .askEveryTime
            },
            saveSensitiveReadPolicy: { _ in },
            loadPlaceCacheTaskMode: {
                storedPlaceCacheTaskMode
            },
            savePlaceCacheTaskMode: { mode in
                storedPlaceCacheTaskMode = mode
            }
        )

        viewModel.startPlaceCachePreheatBatch()

        XCTAssertEqual(storedPlaceCacheTaskMode, .idle)
    }

    @MainActor
    func testPauseAndResumePlaceCachePreheatPersistTaskMode() {
        var storedPlaceCacheTaskMode = PhotoSorterPlaceCacheTaskMode.running
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            },
            loadAgentAccessMode: {
                .full
            },
            saveAgentAccessMode: { _ in },
            loadSensitiveReadPolicy: {
                .askEveryTime
            },
            saveSensitiveReadPolicy: { _ in },
            loadPlaceCacheTaskMode: {
                storedPlaceCacheTaskMode
            },
            savePlaceCacheTaskMode: { mode in
                storedPlaceCacheTaskMode = mode
            }
        )

        viewModel.pausePlaceCachePreheat()
        XCTAssertEqual(storedPlaceCacheTaskMode, .paused)

        viewModel.resumePlaceCachePreheat()
        XCTAssertEqual(storedPlaceCacheTaskMode, .running)
    }

    @MainActor
    func testLaunchAutoSubmitPromptSequenceParsesArgumentsAndEnvironment() {
        XCTAssertEqual(
            MSPPlaygroundViewModel.launchAutoSubmitPromptSequenceIfRequested(
                arguments: [
                    "PhotoSorter",
                    "--msp-auto-submit-sequence-json",
                    "[\" first \",\"\",\"second\"]"
                ],
                environment: [:]
            ),
            ["first", "second"]
        )

        XCTAssertEqual(
            MSPPlaygroundViewModel.launchAutoSubmitPromptSequenceIfRequested(
                arguments: ["PhotoSorter"],
                environment: [
                    "MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON": "[\"one\",\" two \"]"
                ]
            ),
            ["one", "two"]
        )

        XCTAssertNil(
            MSPPlaygroundViewModel.launchAutoSubmitPromptSequenceIfRequested(
                arguments: ["PhotoSorter", "--msp-auto-submit-sequence-json=[]"],
                environment: [:]
            )
        )
        XCTAssertNil(
            MSPPlaygroundViewModel.launchAutoSubmitPromptSequenceIfRequested(
                arguments: ["PhotoSorter"],
                environment: [
                    "MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON": "not-json"
                ]
            )
        )
    }

    @MainActor
    func testE2EPhotoAuthorizationRequestSkipParsesArgumentsAndEnvironment() {
        XCTAssertTrue(
            MSPPlaygroundViewModel.e2ePhotoLibraryAuthorizationRequestSkipEnabled(
                arguments: [
                    "PhotoSorter",
                    "--msp-skip-photo-library-authorization-request"
                ],
                environment: [:]
            )
        )

        XCTAssertTrue(
            MSPPlaygroundViewModel.e2ePhotoLibraryAuthorizationRequestSkipEnabled(
                arguments: ["PhotoSorter"],
                environment: [
                    "MSP_PHOTOSORTER_SKIP_PHOTO_LIBRARY_AUTHORIZATION_REQUEST": "1"
                ]
            )
        )

        XCTAssertFalse(
            MSPPlaygroundViewModel.e2ePhotoLibraryAuthorizationRequestSkipEnabled(
                arguments: ["PhotoSorter"],
                environment: [
                    "MSP_PHOTOSORTER_SKIP_PHOTO_LIBRARY_AUTHORIZATION_REQUEST": "0"
                ]
            )
        )
    }

    @MainActor
    func testPhotoLibraryIndexRefreshStartsOnlyWithReadAuthorization() {
        XCTAssertTrue(
            MSPPlaygroundViewModel.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: .authorized)
        )
        XCTAssertTrue(
            MSPPlaygroundViewModel.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: .limited)
        )
        XCTAssertFalse(
            MSPPlaygroundViewModel.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: .notDetermined)
        )
        XCTAssertFalse(
            MSPPlaygroundViewModel.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: .denied)
        )
        XCTAssertFalse(
            MSPPlaygroundViewModel.shouldStartPhotoLibraryIndexRefresh(photoAuthorizationStatus: .restricted)
        )
    }

    @MainActor
    func testSubmitMessagePreservesSelectedTextOnUserTimelineItemAndClearsDraft() {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        let selectionID = UUID(uuidString: "00000000-0000-4000-8000-000000000201")!
        viewModel.composerText = "  总结一下  "
        viewModel.addSelectedTextToComposer(
            PhotoSorterTextSelectionSnapshot(
                id: selectionID,
                selectedText: "  这段是选中的对话  ",
                sourceMessageID: "assistant-message-1",
                sourceMessageRole: "assistant"
            )
        )

        viewModel.submitMessage()

        XCTAssertEqual(viewModel.composerText, "")
        XCTAssertTrue(viewModel.composerTextSelections.isEmpty)
        let item = viewModel.transcript.last
        XCTAssertEqual(item?.kind, .user)
        XCTAssertEqual(item?.body, "总结一下")
        XCTAssertEqual(item?.sourceTextSelections.map(\.id), [selectionID])
        XCTAssertEqual(item?.sourceTextSelections.map(\.selectedText), ["这段是选中的对话"])
    }

    @MainActor
    func testSubmitSelectedTextOnlyUsesExampleChatFallbackPrompt() {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        viewModel.addSelectedTextToComposer(
            PhotoSorterTextSelectionSnapshot(selectedText: "选中的内容")
        )

        viewModel.submitMessage()

        XCTAssertEqual(viewModel.transcript.last?.body, "请查看选中的文本。")
        XCTAssertEqual(viewModel.transcript.last?.sourceTextSelections.map(\.selectedText), ["选中的内容"])
    }

    func testSelectedTextPromptFormatterMatchesExampleChatShape() {
        let prompt = PhotoSorterSelectedTextPromptFormatter.prompt(
            userPrompt: "帮我解释",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "第一段"),
                PhotoSorterTextSelectionSnapshot(selectedText: "第二段")
            ]
        )

        XCTAssertEqual(
            prompt,
            "\n# Selected text:\n\n## Selection 1\n第一段\n\n## Selection 2\n第二段\n\n## My request for Codex:\n帮我解释\n"
        )
    }

    func testDurableCurrentUserModelItemsUseFullPromptForContinuation() throws {
        let items = MSPPlaygroundViewModel.durableCurrentUserModelItems(
            userMessage: "帮我解释",
            textSelections: [
                PhotoSorterTextSelectionSnapshot(selectedText: "第一段"),
                PhotoSorterTextSelectionSnapshot(selectedText: "第二段")
            ]
        )

        XCTAssertEqual(items.count, 1)
        let message = try XCTUnwrap(items.first?.objectValue)
        XCTAssertEqual(message["type"]?.stringValue, "message")
        XCTAssertEqual(message["role"]?.stringValue, "user")
        let content = try XCTUnwrap(message["content"]?.arrayValue)
        let textPart = try XCTUnwrap(content.first?.objectValue)
        XCTAssertEqual(textPart["type"]?.stringValue, "input_text")
        XCTAssertEqual(
            textPart["text"]?.stringValue,
            "\n# Selected text:\n\n## Selection 1\n第一段\n\n## Selection 2\n第二段\n\n## My request for Codex:\n帮我解释\n"
        )
    }

    @MainActor
    func testWriteStdinPollUpdatesOriginalExecCommandTranscriptItem() {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        let turnStartedAt = 1_772_000_063_700
        let command = "python3 -u -c 'import time; print(\"YIELD_START\", flush=True); time.sleep(1.2); print(\"YIELD_DONE\", flush=True)'"
        let batchID = UUID(uuidString: "00000000-0000-4000-8000-000000000301")!
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "测一下 Codex 风格等待",
            turnStartedAtMilliseconds: turnStartedAt
        ))

        let execCall = MSPAgentToolCall(
            id: "call_slow",
            name: .execCommand,
            arguments: [
                "cmd": .string(command),
                "yield_time_ms": .number(250)
            ]
        )
        viewModel.applyAgentEventForTesting(
            .toolStarted(execCall, statusText: "正在执行工作区命令", batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolOutputDelta(callID: "call_slow", name: .execCommand, stream: .stdout, text: "YIELD_START\n"),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolCompleted(MSPAgentToolResult(
                callID: "call_slow",
                name: .execCommand,
                ok: true,
                content: .string("Process running with session ID 7\nOutput:\nYIELD_START\n"),
                internalContent: .object([
                    "cmd": .string(command),
                    "stdout": .string("YIELD_START\n"),
                    "stderr": .string(""),
                    "exit_code": .number(0),
                    "session_id": .number(7)
                ]),
                errorMessage: nil
            ), batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        var toolItems = viewModel.transcript.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.count, 1)
        XCTAssertEqual(toolItems.first?.callID, "call_slow")
        XCTAssertEqual(toolItems.first?.body, "正在执行工作区命令")
        XCTAssertEqual(toolItems.first?.status, "inProgress")
        XCTAssertEqual(toolItems.first?.execSessionID, 7)
        XCTAssertNil(toolItems.first?.completedAtMilliseconds)

        viewModel.applyAgentEventForTesting(
            .assistantProgress("命令已经执行约 1 秒，我继续等。"),
            turnStartedAtMilliseconds: turnStartedAt
        )
        let pollCall = MSPAgentToolCall(
            id: "call_poll",
            name: .writeStdin,
            arguments: [
                "session_id": .number(7),
                "chars": .string("")
            ]
        )
        viewModel.applyAgentEventForTesting(
            .toolStarted(pollCall, statusText: "正在等待命令输出", batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolOutputDelta(callID: "call_poll", name: .writeStdin, stream: .stdout, text: "YIELD_DONE\n"),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolCompleted(MSPAgentToolResult(
                callID: "call_poll",
                name: .writeStdin,
                ok: true,
                content: .string("Process exited with code 0\nOutput:\nYIELD_DONE\n"),
                internalContent: .object([
                    "session_id": .number(7),
                    "stdout": .string("YIELD_DONE\n"),
                    "stderr": .string(""),
                    "exit_code": .number(0),
                    "running_session_id": .null
                ]),
                errorMessage: nil
            ), batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        toolItems = viewModel.transcript.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        XCTAssertEqual(toolItems.count, 1)
        let toolItem = toolItems.first
        XCTAssertEqual(toolItem?.callID, "call_slow")
        XCTAssertEqual(toolItem?.command, command)
        XCTAssertEqual(toolItem?.stdout, "YIELD_START\nYIELD_DONE\n")
        XCTAssertEqual(toolItem?.body, "已执行工作区命令")
        XCTAssertEqual(toolItem?.status, "completed")
        XCTAssertEqual(toolItem?.exitCode, 0)
        XCTAssertFalse(viewModel.transcript.contains { $0.callID == "call_poll" })
    }

    @MainActor
    func testPlanProgressEventUpdatesExampleChatPlanStateWithoutTranscriptToolActivity() {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        let turnStartedAt = 1_772_000_063_800
        let batchID = UUID(uuidString: "00000000-0000-4000-8000-000000000302")!

        viewModel.applyAgentEventForTesting(
            .planProgressUpdated(MSPPlanProgressUpdatedEvent(
                eventID: "turn-a:plan-update:call-plan",
                threadID: "thread-a",
                turnID: "turn-a",
                explanation: "整理测试计划",
                plan: [
                    MSPUpdatePlanItem(step: "创建测试计划", status: .completed),
                    MSPUpdatePlanItem(step: "推进到第二步", status: .inProgress),
                    MSPUpdatePlanItem(step: "推进到第三步并收尾", status: .pending)
                ]
            )),
            turnStartedAtMilliseconds: turnStartedAt
        )

        let update = viewModel.activePlanProgressUpdate
        XCTAssertEqual(update?.threadID, "thread-a")
        XCTAssertEqual(update?.turnID, "turn-a")
        XCTAssertEqual(update?.explanation, "整理测试计划")
        XCTAssertEqual(update?.steps.map(\.step), ["创建测试计划", "推进到第二步", "推进到第三步并收尾"])
        XCTAssertEqual(update?.steps.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(update?.progressPresentation.currentStepNumber, 2)
        XCTAssertEqual(update?.progressPresentation.totalStepCount, 3)
        XCTAssertEqual(update?.progressPresentation.completedStepCount, 1)
        XCTAssertEqual(update?.progressPresentation.progressFraction ?? -1, 1.0 / 3.0, accuracy: 0.0001)

        let updatePlanCall = MSPAgentToolCall(
            id: "call-plan",
            name: .updatePlan,
            arguments: [
                "plan": .array([])
            ]
        )
        viewModel.applyAgentEventForTesting(
            .toolStarted(updatePlanCall, statusText: "Updating plan", batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )
        viewModel.applyAgentEventForTesting(
            .toolCompleted(MSPAgentToolResult(
                callID: "call-plan",
                name: .updatePlan,
                ok: true,
                content: .string("Plan updated"),
                errorMessage: nil
            ), batchID: batchID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        XCTAssertFalse(viewModel.transcript.contains { $0.toolName == MSPUpdatePlanToolSchema.name })
        XCTAssertTrue(viewModel.transcript.filter { $0.kind == .toolCall || $0.kind == .toolResult }.isEmpty)
    }

    @MainActor
    func testContextCompactionEventsReuseExampleChatProgressStatusBlock() throws {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        let turnStartedAt = 1_772_000_063_900
        let compactionID = "00000000-0000-4000-8000-000000000401"
        viewModel.transcript.append(MSPAgentTimelineItem(
            kind: .user,
            title: "",
            body: "继续整理照片",
            turnStartedAtMilliseconds: turnStartedAt
        ))

        viewModel.applyAgentEventForTesting(
            .contextCompactionStarted(compactionID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        let runningBlocks = try Self.assistantSupportBlocks(
            from: viewModel.transcript,
            isGenerating: true
        )
        let runningBlock = try XCTUnwrap(runningBlocks.first)
        let runningBlockID = try XCTUnwrap(runningBlock["id"] as? String)
        XCTAssertEqual(runningBlocks.count, 1)
        XCTAssertEqual(runningBlock["kind"] as? String, "chat_progress")
        XCTAssertEqual(runningBlock["text"] as? String, "正在自动压缩上下文")
        XCTAssertEqual(runningBlock["status"] as? String, "processing")
        XCTAssertFalse(runningBlocks.contains { ($0["kind"] as? String) == "chat_processing" })
        XCTAssertFalse(runningBlocks.contains { ($0["kind"] as? String) == "readex_processing" })

        viewModel.applyAgentEventForTesting(
            .contextCompactionCompleted(compactionID),
            turnStartedAtMilliseconds: turnStartedAt
        )

        let completedPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: viewModel.transcript,
            isGenerating: true
        )
        let completedMessages = try XCTUnwrap(completedPayload["messages"] as? [[String: Any]])
        let completedAssistant = try XCTUnwrap(completedMessages.first { ($0["role"] as? String) == "assistant" })
        let completedBlocks = try XCTUnwrap(completedAssistant["supportBlocks"] as? [[String: Any]])
        let completedBlock = try XCTUnwrap(completedBlocks.first)
        XCTAssertEqual(completedBlocks.count, 1)
        XCTAssertEqual(completedAssistant["status"] as? String, "success")
        XCTAssertEqual(completedAssistant["isStreaming"] as? Bool, false)
        XCTAssertEqual(completedBlock["id"] as? String, runningBlockID)
        XCTAssertEqual(completedBlock["kind"] as? String, "chat_progress")
        XCTAssertEqual(completedBlock["text"] as? String, "上下文已自动压缩")
        XCTAssertEqual(completedBlock["status"] as? String, "success")
        XCTAssertTrue(completedBlock["durationMilliseconds"] is NSNull)
    }

    func testPhotoSorterPressureHarnessSupportsPromptSequencesAndVerifier() throws {
        let rootURL = try Self.photoSorterRootURL()
        let e2eURL = rootURL
            .appendingPathComponent("Tools")
            .appendingPathComponent("E2E")

        let e2eRunner = try String(
            contentsOf: e2eURL.appendingPathComponent("run-real-model-e2e.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON",
            "MSP_PLAYGROUND_E2E_EXPECT_FINAL_ANSWERS",
            "SIMCTL_CHILD_MSP_PLAYGROUND_AUTO_SUBMIT_SEQUENCE_JSON",
            "MSP_PHOTOSORTER_E2E_SKIP_PHOTO_AUTH_REQUEST",
            "SIMCTL_CHILD_MSP_PHOTOSORTER_SKIP_PHOTO_LIBRARY_AUTHORIZATION_REQUEST",
            "--msp-skip-photo-library-authorization-request",
            "MSP_PLAYGROUND_E2E_ALLOW_VISIBLE_EXEC_COMMAND",
            "contains_exec_command_outside_user_messages",
            "contains_internal_shell_tool_name",
            "cp \"$EVENT_LOG\" \"$OUT_DIR/events.jsonl\"",
            "final_answers=$final_answer_count"
        ] {
            XCTAssertTrue(e2eRunner.contains(required), "PhotoSorter E2E runner missing \(required)")
        }

        let viewModelSource = try String(
            contentsOf: rootURL
                .appendingPathComponent("App")
                .appendingPathComponent("MSPPlaygroundViewModel.swift"),
            encoding: .utf8
        )
        for required in [
            "e2eEventLog?.record(probe.name, fields: probe.fields)",
            "\"contains_exec_command_outside_user_messages\"",
            "\"content_text\"",
            "\"text\": text"
        ] {
            XCTAssertTrue(viewModelSource.contains(required), "PhotoSorter ViewModel E2E event log missing \(required)")
        }

        let transcriptSupportRenderer = try String(
            contentsOf: rootURL
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-message-block-support-renderer.js"),
            encoding: .utf8
        )
        let legacyLowerPrefix = ["read", "ex"].joined()
        let legacyUpperPrefix = ["Read", "ex"].joined()
        let legacyShellExecutionPropertyPrefix = "\(legacyLowerPrefix)ShellExecution"
        let legacyShellExecutionFunctionPrefix = "\(legacyUpperPrefix)ShellExecution"
        for required in [
            "__\(legacyShellExecutionPropertyPrefix)ScrollState",
            "data-\(legacyLowerPrefix)-shell-execution-scroll-key",
            "mark\(legacyShellExecutionFunctionPrefix)UserScroll",
            "restore\(legacyShellExecutionFunctionPrefix)ScrollState",
            "previous?.userPinned",
            "requestAnimationFrame(restore)",
            "scroll.__\(legacyShellExecutionPropertyPrefix)RestoringScroll",
            "button.__\(legacyShellExecutionPropertyPrefix)Shell",
            "function update\(legacyShellExecutionFunctionPrefix)Transcript",
            "output.startsWith(previousOutput)",
            "function update\(legacyShellExecutionFunctionPrefix)Viewer",
            "function updateExisting\(legacyShellExecutionFunctionPrefix)Item",
            "wrapper.dataset.\(legacyLowerPrefix)ToolDisclosureKey",
            "\"wheel\", \"touchstart\", \"pointerdown\"",
            "\"ArrowUp\", \"ArrowDown\", \"PageUp\", \"PageDown\", \"Home\", \"End\", \" \""
        ] {
            XCTAssertTrue(
                transcriptSupportRenderer.contains(required),
                "PhotoSorter transcript shell scroll state support missing \(required)"
            )
        }

        let pressureRunner = try String(
            contentsOf: e2eURL.appendingPathComponent("run-real-model-pressure.sh"),
            encoding: .utf8
        )
        for required in [
            "MSP_PHOTOSORTER_PRESSURE_PROMPTS_FILE",
            "MSP_PHOTOSORTER_PRESSURE_RESET_APP",
            "MSP_PHOTOSORTER_REQUIRE_CPYTHON",
            "verify-real-model-pressure-log.py",
            "MSP_PLAYGROUND_E2E_PROMPT_SEQUENCE_JSON",
            "MSP_PHOTOSORTER_PRESSURE_REQUIRE_EXEC_SESSION_CONTRACT",
            "--require-exec-session-contract",
            "MSP_PLAYGROUND_E2E_RESET_APP=\"$RESET_APP\""
        ] {
            XCTAssertTrue(pressureRunner.contains(required), "PhotoSorter pressure runner missing \(required)")
        }

        let promptsURL = e2eURL
            .appendingPathComponent("pressure")
            .appendingPathComponent("photosorter-virtual-workspace-prompts.json")
        let promptsData = try Data(contentsOf: promptsURL)
        let prompts = try JSONDecoder().decode([String].self, from: promptsData)
        XCTAssertGreaterThanOrEqual(prompts.count, 4)

        let firstPrompt = prompts[0].lowercased()
        for forbidden in ["ios", "msp", "sandbox", "broker", "materialized", "launcher", "virtual", "photosorter"] {
            XCTAssertFalse(firstPrompt.contains(forbidden), "first PhotoSorter pressure prompt discloses \(forbidden)")
        }

        for required in ["/图库", "/相册", "/最近删除", "/tmp", "PHOTO_ROOT_DONE"] {
            XCTAssertTrue(prompts[0].contains(required), "PhotoSorter root pressure prompt missing \(required)")
        }
        for required in ["pathlib", "subprocess", "find /图库", "find /相册", "PHOTO_PYTHON_DONE"] {
            XCTAssertTrue(prompts[1].contains(required), "PhotoSorter Python pressure prompt missing \(required)")
        }
        for required in ["xargs", "移动", "删除", "PHOTO_STATE_BATCH_DONE"] {
            XCTAssertTrue(prompts[2].contains(required), "PhotoSorter state pressure prompt missing \(required)")
        }
        for required in [
            "looks_like_regular_linux",
            "can_distinguish_from_regular_linux",
            "leaked_internal_paths"
        ] {
            XCTAssertTrue(prompts[prompts.count - 1].contains(required), "PhotoSorter feedback prompt missing \(required)")
        }
    }

    @MainActor
    func testMediaViewAuthorizationWaitsForSelectedImages() async throws {
        let viewModel = MSPPlaygroundViewModel(
            loadModelConfiguration: {
                Self.configuration(
                    baseURL: "https://stored.example.test/v1",
                    apiKey: "stored-key",
                    modelID: "stored-model"
                )
            },
            saveModelConfiguration: { _ in },
            loadCodexOAuthConfiguration: {
                .empty
            }
        )
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let first = PhotoSorterMediaViewItem(
            id: firstID,
            image: Self.authorizationImage(path: "/图库/a.png")
        )
        let second = PhotoSorterMediaViewItem(
            id: secondID,
            image: Self.authorizationImage(path: "/图库/b.png")
        )
        let request = PhotoSorterMediaViewAuthorizationRequest(
            purpose: .askUser,
            message: "请确认这些候选图，取消勾选想保留的。",
            items: [first, second],
            limitSkippedPaths: ["/图库/c.png"]
        )

        let task = Task { @MainActor in
            await viewModel.authorizeMediaView(request)
        }
        await Task.yield()

        XCTAssertEqual(viewModel.mediaViewAuthorizationPrompt?.items.map(\.path), ["/图库/a.png", "/图库/b.png"])
        XCTAssertEqual(viewModel.mediaViewAuthorizationPrompt?.message, "请确认这些候选图，取消勾选想保留的。")
        XCTAssertEqual(viewModel.mediaViewAuthorizationPrompt?.limitSkippedPaths, ["/图库/c.png"])

        viewModel.allowMediaViewAuthorization(selectedItemIDs: [secondID])
        let decision = await task.value

        XCTAssertEqual(decision.allowedItemIDs, [secondID])
        XCTAssertNil(viewModel.mediaViewAuthorizationPrompt)
    }

    private static func configuration(
        baseURL: String,
        apiKey: String,
        modelID: String
    ) -> MSPModelConfiguration {
        MSPModelConfiguration(
            providerName: "OpenAI-compatible",
            baseURL: URL(string: baseURL),
            apiKey: apiKey,
            modelID: modelID,
            apiStyle: "responses",
            endpointType: "openai-response",
            endpointPathOverride: "/v1/responses",
            reasoningEffort: "medium",
            verbosity: "medium"
        )
    }

    private static func photoSorterRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func authorizationImage(path: String) -> PhotoSorterOriginalImage {
        PhotoSorterOriginalImage(
            path: path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            mimeType: "image/png",
            pixelWidth: 100,
            pixelHeight: 100,
            data: Data([0x01])
        )
    }

    private static func workspaceMediaPreview(
        cacheVersionToken: String
    ) -> WorkspaceMediaPreview {
        WorkspaceMediaPreview(
            title: "a.jpg",
            path: "/图库/a.jpg",
            imageData: Data([0x01, 0x02]),
            media: PhotoSorterMediaPreview(
                path: "/图库/a.jpg",
                fileName: "a.jpg",
                kind: .image,
                pixelWidth: 10,
                pixelHeight: 10,
                thumbnailData: Data([0x01, 0x02]),
                photoLibraryLocalIdentifier: "asset-a",
                fileURL: nil
            ),
            message: "old message",
            isLoading: true,
            galleryItems: [
                WorkspaceFileNode(
                    name: "a.jpg",
                    path: "/图库/a.jpg",
                    type: .regularFile,
                    mediaKind: .image
                ),
                WorkspaceFileNode(
                    name: "b.jpg",
                    path: "/图库/b.jpg",
                    type: .regularFile,
                    mediaKind: .image
                )
            ],
            galleryLoadedNodeCount: 2,
            galleryHasMoreNodes: true,
            isLoadingMoreGalleryItems: true,
            galleryImageDataByPath: [
                "/图库/a.jpg": Data([0x01, 0x02])
            ],
            galleryMediaByPath: [
                "/图库/b.jpg": PhotoSorterMediaPreview(
                    path: "/图库/b.jpg",
                    fileName: "b.jpg",
                    kind: .image,
                    pixelWidth: 10,
                    pixelHeight: 10,
                    thumbnailData: Data([0x03, 0x04]),
                    photoLibraryLocalIdentifier: "asset-b",
                    fileURL: nil
                )
            ],
            galleryMessageByPath: [
                "/图库/missing.jpg": "missing"
            ],
            galleryLoadingPaths: ["/图库/loading.jpg"],
            workspaceCacheVersionToken: cacheVersionToken
        )
    }

    private static func assistantSupportBlocks(
        from transcript: [MSPAgentTimelineItem],
        isGenerating: Bool
    ) throws -> [[String: Any]] {
        let payload = ExampleChatTranscriptPayloadFactory.payload(
            from: transcript,
            isGenerating: isGenerating
        )
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        return try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
    }

    private static func modelUser(_ text: String) -> MSPAgentJSONValue {
        modelMessage(role: "user", phase: nil, text: text)
    }

    private static func modelAssistantCommentary(_ text: String) -> MSPAgentJSONValue {
        modelMessage(role: "assistant", phase: "commentary", text: text)
    }

    private static func modelAssistantFinal(_ text: String) -> MSPAgentJSONValue {
        modelMessage(role: "assistant", phase: "final_answer", text: text)
    }

    private static func compactionSummaryUserMessage(_ text: String) -> MSPAgentJSONValue {
        modelUser(compactionSummaryText(text))
    }

    private static func compactionSummaryText(_ text: String) -> String {
        "Another language model started to solve this problem and produced a summary of its thinking process. \(text)"
    }

    private static func modelMessage(
        role: String,
        phase: String?,
        text: String
    ) -> MSPAgentJSONValue {
        var object: [String: MSPAgentJSONValue] = [
            "type": .string("message"),
            "role": .string(role),
            "content": .array([
                .object([
                    "type": .string(role == "assistant" ? "output_text" : "input_text"),
                    "text": .string(text)
                ])
            ])
        ]
        if let phase {
            object["phase"] = .string(phase)
        }
        return .object(object)
    }

    private static func writeChatManifest(
        to packageURL: URL,
        timelineNextSeq: Int
    ) throws {
        let manifest: [String: Any] = [
            "schema_version": 1,
            "package_id": UUID().uuidString,
            "created_at": "2026-07-03T00:00:00Z",
            "profiles": ["core-timeline", "agent-timeline"],
            "timeline": [
                "path": PhotoSorterChatPersistence.defaultChatTimelinePath,
                "next_seq": timelineNextSeq
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageURL.appendingPathComponent("manifest.json"))
    }
}

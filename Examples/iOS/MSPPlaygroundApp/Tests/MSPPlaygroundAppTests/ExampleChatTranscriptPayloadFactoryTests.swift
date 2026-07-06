import XCTest
@testable import MSPPlaygroundApp

final class ExampleChatTranscriptPayloadFactoryTests: XCTestCase {
    func testPresentationUsesMSPPlaygroundTypographyScale() throws {
        let presentation = ExampleChatTranscriptPayloadFactory.presentation(
            isGenerating: false,
            fontScale: 1.2
        )
        let style = try XCTUnwrap(presentation["style"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(presentation["bodyFontSize"] as? Double), 22.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(presentation["roleFontSize"] as? Double), 16.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(presentation["supportFontSize"] as? Double), 21.0, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(style["chatToolActivityFontSize"] as? Double),
            21.6,
            accuracy: 0.0001
        )
        XCTAssertNil(style["readexToolActivityFontSize"])
    }

    func testRunningTurnImmediatelyProjectsExampleChatProcessingPlaceholder() throws {
        let turnStartedAt = 1_772_000_060_000
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "user")

        let assistant = messages[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["status"] as? String, "streaming")
        XCTAssertEqual(assistant["isStreaming"] as? Bool, true)

        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let processingBlock = try XCTUnwrap(supportBlocks.first)
        XCTAssertEqual(processingBlock["kind"] as? String, "chat_processing")
        XCTAssertNil(processingBlock["legacyKind"])
        XCTAssertEqual(processingBlock["status"] as? String, "processing")
        XCTAssertEqual(processingBlock["startedAtMilliseconds"] as? Int, turnStartedAt)
        XCTAssertEqual(processingBlock["chatTurnStartedAtMilliseconds"] as? Int, turnStartedAt)
        XCTAssertTrue(processingBlock["chatTurnDurationMilliseconds"] is NSNull)
        XCTAssertNil(processingBlock["readexTurnStartedAtMilliseconds"])

        let workedForItem = try XCTUnwrap(processingBlock["workedForItem"] as? [String: Any])
        XCTAssertEqual(workedForItem["status"] as? String, "working")
        XCTAssertEqual(workedForItem["startedAtMs"] as? Int, turnStartedAt)
        XCTAssertNil(workedForItem["completedAtMs"] as? Int)

        let processingItems = try XCTUnwrap(processingBlock["items"] as? [[String: Any]])
        let thinkingItem = try XCTUnwrap(processingItems.first)
        XCTAssertEqual(thinkingItem["type"] as? String, "progress")
        XCTAssertEqual(thinkingItem["text"] as? String, "正在思考")
        XCTAssertEqual(thinkingItem["status"] as? String, "processing")
        XCTAssertEqual(thinkingItem["completed"] as? Bool, false)
    }

    func testRunningTurnKeepsThinkingPlaceholderAfterAssistantProgressSegment() throws {
        let turnStartedAt = 1_772_000_061_000
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "先分析一下",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先看一下当前工作区。",
                startedAtMilliseconds: turnStartedAt + 120,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])

        XCTAssertEqual(supportBlocks.map { $0["kind"] as? String }, [
            "chat_progress",
            "chat_processing"
        ])
        XCTAssertEqual(supportBlocks[0]["status"] as? String, "success")

        let processingItems = try XCTUnwrap(supportBlocks[1]["items"] as? [[String: Any]])
        XCTAssertEqual(processingItems.first?["type"] as? String, "progress")
        XCTAssertEqual(processingItems.first?["text"] as? String, "正在思考")
        XCTAssertEqual(processingItems.first?["status"] as? String, "processing")
    }

    func testRunningToolSuppressesThinkingUntilToolCompletes() throws {
        let turnStartedAt = 1_772_000_062_000
        let runningItems: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "列目录",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_live",
                command: "ls /",
                cwd: "/",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]
        let completedItems: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "列目录",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call_done",
                command: "ls /",
                cwd: "/",
                stdout: "welcome.txt\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 200,
                completedAtMilliseconds: turnStartedAt + 600,
                durationMilliseconds: 400,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let runningPayload = ExampleChatTranscriptPayloadFactory.payload(from: runningItems, isGenerating: true)
        let runningMessages = try XCTUnwrap(runningPayload["messages"] as? [[String: Any]])
        let runningAssistant = try XCTUnwrap(runningMessages.first { ($0["role"] as? String) == "assistant" })
        let runningSupportBlocks = try XCTUnwrap(runningAssistant["supportBlocks"] as? [[String: Any]])
        XCTAssertEqual(runningSupportBlocks.map { $0["kind"] as? String }, ["chat_tool_call"])

        let completedPayload = ExampleChatTranscriptPayloadFactory.payload(from: completedItems, isGenerating: true)
        let completedMessages = try XCTUnwrap(completedPayload["messages"] as? [[String: Any]])
        let completedAssistant = try XCTUnwrap(completedMessages.first { ($0["role"] as? String) == "assistant" })
        let completedSupportBlocks = try XCTUnwrap(completedAssistant["supportBlocks"] as? [[String: Any]])
        XCTAssertEqual(completedSupportBlocks.map { $0["kind"] as? String }, [
            "chat_tool_call",
            "chat_processing"
        ])
        let thinkingItems = try XCTUnwrap(completedSupportBlocks[1]["items"] as? [[String: Any]])
        XCTAssertEqual(thinkingItems.first?["text"] as? String, "正在思考")
    }

    func testWorkspaceCommandToolActivityUsesExampleChatProcessingTimeline() throws {
        let turnStartedAt = 1_772_000_000_000
        let toolStartedAt = turnStartedAt + 400
        let toolCompletedAt = turnStartedAt + 1_900
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区"
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先查看目录。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 3_200
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                detail: "退出码: 0",
                callID: "call_1",
                command: "ls /",
                cwd: "/",
                stdout: "welcome.txt\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: toolStartedAt,
                completedAtMilliseconds: toolCompletedAt,
                durationMilliseconds: 1_500,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 3_200
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我看到了一个欢迎文件。",
                startedAtMilliseconds: turnStartedAt + 2_000,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 3_200
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "工作区里有 welcome.txt。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 3_200
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let blocks = try XCTUnwrap(assistant["blocks"] as? [[String: Any]])

        XCTAssertTrue(blocks.isEmpty)
        XCTAssertEqual(assistant["content"] as? String, "工作区里有 welcome.txt。")
        XCTAssertEqual(supportBlocks.map { $0["kind"] as? String }, [
            "chat_progress",
            "chat_tool_call",
            "chat_progress"
        ])
        XCTAssertEqual(supportBlocks.map { $0["text"] as? String }, [
            "我先查看目录。",
            "已执行工作区命令",
            "我看到了一个欢迎文件。"
        ])
        XCTAssertEqual(supportBlocks.map { $0["chatTurnStartedAtMilliseconds"] as? Int }, [
            turnStartedAt,
            turnStartedAt,
            turnStartedAt
        ])
        XCTAssertEqual(supportBlocks.map { $0["chatTurnDurationMilliseconds"] as? Int }, [
            3_200,
            3_200,
            3_200
        ])

        let toolBlock = supportBlocks[1]
        let processingItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(processingItems.first { ($0["type"] as? String) == "chatToolCall" })
        XCTAssertNil(toolItem["legacyType"])
        XCTAssertEqual(toolItem["tool"] as? String, "workspace.shell")
        XCTAssertEqual(toolItem["server"] as? String, "workspace")
        XCTAssertEqual(toolItem["status"] as? String, "completed")
        XCTAssertEqual(toolItem["completed"] as? Bool, true)
        XCTAssertEqual(toolItem["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((toolItem["text"] as? String ?? "").contains("exec_command"))
        XCTAssertFalse((toolItem["text"] as? String ?? "").contains("welcome.txt"))
        let arguments = try XCTUnwrap(toolItem["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["cmd"] as? String, "ls /")
        XCTAssertEqual(arguments["cwd"] as? String, "/")

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["command"] as? String, "ls /")
        XCTAssertEqual(shellExecution["user"] as? String, "user@workspace")
        XCTAssertEqual(shellExecution["kind"] as? String, "list_files")
        XCTAssertEqual(shellExecution["target"] as? String, "/")
        XCTAssertEqual(shellExecution["output"] as? String, "welcome.txt\n")
        XCTAssertEqual(shellExecution["exitCode"] as? Int, 0)

        let commandExecution = try XCTUnwrap(toolItem["commandExecution"] as? [String: Any])
        let commandActions = try XCTUnwrap(commandExecution["commandActions"] as? [[String: Any]])
        let commandAction = try XCTUnwrap(commandActions.first)
        XCTAssertEqual(commandAction["type"] as? String, "unknown")
        XCTAssertNil(commandAction["path"] as? String)
    }

    func testApplyPatchToolActivityProjectsExampleChatApplyPatchDiffPreviewInsteadOfShell() throws {
        let turnStartedAt = 1_772_000_100_000
        let patchInput = """
        *** Begin Patch
        *** Update File: hello.txt
        @@
        -old
        +new
        *** End Patch
        """
        let diff = """
        diff --git a/hello.txt b/hello.txt
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let previewItem = AssistantSupportPreviewItem(
            kind: .markdown,
            title: "文本文件差异",
            subtitle: "hello.txt · +1 -1",
            documentName: "hello.txt",
            filePath: "hello.txt",
            fileName: "hello.txt",
            payload: .object([
                "chat_preview_kind": .string("apply_patch_diff"),
                "patch_status": .string("applied"),
                "status": .string("applied"),
                "p": .string("hello.txt"),
                "file_name": .string("hello.txt"),
                "turn_diff": .string(diff),
                "diff": .string(diff),
                "changed_paths": .array([.string("hello.txt")]),
                "lines_added": .number(1),
                "lines_removed": .number(1),
                "operation_id": .string("1B3E7C54-5E25-4A64-8D69-33C0244E8B74"),
                "can_undo": .bool(true),
                "can_redo": .bool(false)
            ])
        )
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "改 hello.txt",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "apply_patch",
                body: "已编辑 hello.txt",
                callID: "call_apply_patch",
                toolName: "apply_patch",
                command: patchInput,
                status: "completed",
                previewItems: [previewItem],
                startedAtMilliseconds: turnStartedAt + 200,
                completedAtMilliseconds: turnStartedAt + 700,
                durationMilliseconds: 500,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first)
        let activityItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(activityItems.first)

        XCTAssertEqual(toolBlock["chatToolName"] as? String, "apply_patch")
        XCTAssertNil(toolBlock["readexToolName"])
        XCTAssertEqual(toolItem["tool"] as? String, "apply_patch")
        XCTAssertEqual(toolItem["chatToolName"] as? String, "apply_patch")
        XCTAssertNil(toolItem["readexToolName"])
        XCTAssertEqual(toolItem["text"] as? String, "已编辑 hello.txt")
        XCTAssertTrue(toolItem["detailText"] == nil || toolItem["detailText"] is NSNull)
        XCTAssertNil(toolItem["shellExecution"])
        XCTAssertNil(toolItem["commandExecution"])

        let arguments = try XCTUnwrap(toolItem["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["input"] as? String, patchInput)
        XCTAssertNil(arguments["cmd"])
        XCTAssertNil(arguments["cwd"])

        let previews = try XCTUnwrap(toolItem["previewItems"] as? [[String: Any]])
        let projectedPreview = try XCTUnwrap(previews.first)
        XCTAssertNil(projectedPreview["markdown"])
        XCTAssertEqual(projectedPreview["fileName"] as? String, "hello.txt")
        XCTAssertEqual(projectedPreview["filePath"] as? String, "hello.txt")
        let previewPayload = try XCTUnwrap(projectedPreview["payload"] as? [String: Any])
        XCTAssertEqual(previewPayload["chat_preview_kind"] as? String, "apply_patch_diff")
        XCTAssertNil(previewPayload["readex_preview_kind"])
        XCTAssertEqual(previewPayload["patch_status"] as? String, "applied")
        XCTAssertNil(previewPayload["readex_patch_activity_kind"])
        XCTAssertEqual(previewPayload["file_name"] as? String, "hello.txt")
        XCTAssertEqual(previewPayload["turn_diff"] as? String, diff)
        XCTAssertEqual(previewPayload["changed_paths"] as? [String], ["hello.txt"])
        XCTAssertEqual(previewPayload["operation_id"] as? String, "1B3E7C54-5E25-4A64-8D69-33C0244E8B74")
        XCTAssertEqual((previewPayload["lines_added"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((previewPayload["lines_removed"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(previewPayload["can_undo"] as? Bool, true)
        XCTAssertEqual(previewPayload["can_redo"] as? Bool, false)
    }

    func testMultipleWorkspaceCommandsStayInChronologicalSupportBlockOrder() throws {
        let turnStartedAt = 1_772_000_050_000
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "检查工作区并读欢迎文件",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先列出工作区。",
                startedAtMilliseconds: turnStartedAt + 100,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                detail: "退出码: 0",
                callID: "call_ls",
                command: "ls /",
                cwd: "/",
                stdout: "welcome.txt\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 300,
                completedAtMilliseconds: turnStartedAt + 1_100,
                durationMilliseconds: 800,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我看到 welcome.txt，接着读取它。",
                startedAtMilliseconds: turnStartedAt + 1_300,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                detail: "退出码: 0",
                callID: "call_cat",
                command: "cat /welcome.txt",
                cwd: "/",
                stdout: "hello from workspace\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 1_500,
                completedAtMilliseconds: turnStartedAt + 2_400,
                durationMilliseconds: 900,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "文件内容已经读取完。",
                startedAtMilliseconds: turnStartedAt + 2_600,
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            ),
            MSPAgentTimelineItem(
                kind: .assistantFinal,
                title: "",
                body: "welcome.txt 的内容是 hello from workspace。",
                turnStartedAtMilliseconds: turnStartedAt,
                turnDurationMilliseconds: 5_200
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])

        XCTAssertEqual(assistant["content"] as? String, "welcome.txt 的内容是 hello from workspace。")
        XCTAssertEqual(supportBlocks.map { $0["kind"] as? String }, [
            "chat_progress",
            "chat_tool_call",
            "chat_progress",
            "chat_tool_call",
            "chat_progress"
        ])
        XCTAssertEqual(supportBlocks.map { $0["text"] as? String }, [
            "我先列出工作区。",
            "已执行工作区命令",
            "我看到 welcome.txt，接着读取它。",
            "已执行工作区命令",
            "文件内容已经读取完。"
        ])

        let toolBlocks = supportBlocks.filter { ($0["kind"] as? String) == "chat_tool_call" }
        XCTAssertEqual(toolBlocks.count, 2)
        let firstToolItem = try XCTUnwrap((toolBlocks[0]["items"] as? [[String: Any]])?.first)
        let secondToolItem = try XCTUnwrap((toolBlocks[1]["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstToolItem["text"] as? String, "已执行工作区命令")
        XCTAssertEqual(secondToolItem["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((firstToolItem["text"] as? String ?? "").contains("welcome.txt"))
        XCTAssertFalse((secondToolItem["text"] as? String ?? "").contains("hello from workspace"))

        let firstShellExecution = try XCTUnwrap(firstToolItem["shellExecution"] as? [String: Any])
        let secondShellExecution = try XCTUnwrap(secondToolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(firstShellExecution["output"] as? String, "welcome.txt\n")
        XCTAssertEqual(secondShellExecution["output"] as? String, "hello from workspace\n")
    }

    func testFailedWorkspaceCommandUsesFailureStatusWithoutLeakingOutputAsTitle() throws {
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(kind: .user, title: "", body: "找文件"),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "工作区命令执行失败",
                detail: "退出码: 127",
                callID: "call_find",
                command: "find /docs -maxdepth 2 -print",
                cwd: "/",
                stdout: "",
                stderr: "find: command not found\n",
                exitCode: 127,
                status: "failed",
                startedAtMilliseconds: 1_772_000_010_000,
                completedAtMilliseconds: 1_772_000_010_300,
                durationMilliseconds: 300,
                turnStartedAtMilliseconds: 1_772_000_009_000,
                turnDurationMilliseconds: 2_000
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_tool_call" })
        let processingItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(processingItems.first { ($0["type"] as? String) == "chatToolCall" })

        XCTAssertEqual(assistant["status"] as? String, "failed")
        XCTAssertEqual(toolBlock["status"] as? String, "failed")
        XCTAssertEqual(toolItem["text"] as? String, "工作区命令执行失败")
        XCTAssertEqual(toolItem["status"] as? String, "failed")
        XCTAssertFalse((toolItem["text"] as? String ?? "").contains("find: command not found"))

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["output"] as? String, "find: command not found\n")
        XCTAssertEqual(shellExecution["exitCode"] as? Int, 127)
    }

    func testToolActivityExpansionIDsAreOnlyIncludedWhenRequested() throws {
        let toolItem = MSPAgentTimelineItem(
            kind: .toolCall,
            title: "工作区命令",
            body: "已执行工作区命令",
            detail: "退出码: 0",
            callID: "call_ls",
            command: "ls /",
            cwd: "/",
            stdout: "welcome.txt\n",
            stderr: "",
            exitCode: 0,
            status: "completed",
            startedAtMilliseconds: 1_772_000_030_000,
            completedAtMilliseconds: 1_772_000_030_500,
            durationMilliseconds: 500,
            turnStartedAtMilliseconds: 1_772_000_029_000,
            turnDurationMilliseconds: 1_200
        )
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(kind: .user, title: "", body: "列目录"),
            toolItem
        ]

        let collapsedPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: items,
            isGenerating: false
        )
        XCTAssertEqual(
            collapsedPayload["expandedExampleChatToolActivityBlockIDs"] as? [String],
            []
        )

        let expandedPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: items,
            isGenerating: false,
            expandToolActivityBlocks: true
        )
        let expandedIDs = try XCTUnwrap(expandedPayload["expandedExampleChatToolActivityBlockIDs"] as? [String])
        XCTAssertEqual(expandedIDs, [toolItem.id.uuidString])
    }

    func testWorkspaceCommandActionsUseExampleChatShellDisplayClassification() {
        let listAction = ExampleChatWorkspaceShellTranscriptDisplaySupport
            .shellCommandAction(for: "ls /Documents")
        XCTAssertEqual(listAction.type, "list_files")
        XCTAssertEqual(listAction.path, "/Documents")

        let readAction = ExampleChatWorkspaceShellTranscriptDisplaySupport
            .shellCommandAction(for: "cat './notes/read me.md'")
        XCTAssertEqual(readAction.type, "read")
        XCTAssertEqual(readAction.path, "./notes/read me.md")

        let searchAction = ExampleChatWorkspaceShellTranscriptDisplaySupport
            .shellCommandAction(for: "rg -n \"needle\" ./notes")
        XCTAssertEqual(searchAction.type, "search")
        XCTAssertEqual(searchAction.query, "needle")
        XCTAssertEqual(searchAction.path, "./notes")

        let pipelineAction = ExampleChatWorkspaceShellTranscriptDisplaySupport
            .shellCommandAction(for: "cat /tmp/a.txt | wc -l")
        XCTAssertEqual(pipelineAction.type, "read")
        XCTAssertEqual(pipelineAction.path, "/tmp/a.txt")
    }

    func testRunningTurnCarriesLiveExampleChatTimerWithoutStaticDuration() throws {
        let turnStartedAt = 1_772_000_020_000
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我看看工作区",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "我先看看。",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_live",
                command: "ls /",
                cwd: "/",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 600,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let progressBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_progress" })
        let toolBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_tool_call" })
        let processingItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(processingItems.first { ($0["type"] as? String) == "chatToolCall" })

        XCTAssertEqual(assistant["status"] as? String, "streaming")
        XCTAssertEqual(assistant["isStreaming"] as? Bool, true)
        XCTAssertEqual(progressBlock["status"] as? String, "success")
        XCTAssertEqual(toolBlock["status"] as? String, "inProgress")
        XCTAssertEqual(toolBlock["chatTurnStartedAtMilliseconds"] as? Int, turnStartedAt)
        XCTAssertTrue(toolBlock["chatTurnDurationMilliseconds"] is NSNull)
        XCTAssertEqual(toolItem["text"] as? String, "正在执行工作区命令")
        XCTAssertEqual(toolItem["status"] as? String, "inProgress")
        XCTAssertEqual(toolItem["completed"] as? Bool, false)
        XCTAssertTrue(toolItem["durationMilliseconds"] is NSNull)
    }

    func testWorkspaceCommandToolActivityUsesExampleChatStreamingToolPresentationHelper() throws {
        let startedAt = Date(timeIntervalSince1970: 1_772_000_040)
        let completedAt = startedAt.addingTimeInterval(1.4)
        let call = ExampleChatToolCall(
            id: "call_helper",
            name: .shell,
            arguments: [
                "cmd": .string("cat /welcome.txt"),
                "cwd": .string("/")
            ]
        )

        let started = try XCTUnwrap(ExampleChatStreamingToolPresentationHelper.startedPresentation(
            in: [],
            activeBlockID: nil,
            activeStartedAt: startedAt,
            text: ExampleChatShellTranscriptDisplaySupport.shellStartedStatusText(for: call),
            detailText: nil,
            previewItems: [],
            chatToolCall: call,
            chatToolName: .shell,
            chatToolBatchID: nil,
            processingStartedAtMilliseconds: 1_772_000_040_000,
            at: startedAt
        ))
        let startedBlock = try XCTUnwrap(started.blocks.last)
        XCTAssertEqual(startedBlock.kind, .chatToolCall)
        XCTAssertEqual(startedBlock.text, "正在执行工作区命令")
        XCTAssertEqual(startedBlock.status, "inProgress")
        XCTAssertEqual(startedBlock.activityItems.first?.status, "inProgress")
        XCTAssertEqual(startedBlock.activityItems.first?.shellExecution?.command, "cat /welcome.txt")

        let result = ExampleChatToolResult(
            callID: call.id,
            name: .shell,
            ok: true,
            content: .string("hello\n"),
            internalContent: ExampleChatShellTranscriptDisplaySupport.internalContent(
                command: "cat /welcome.txt",
                cwd: "/",
                exitCode: 0,
                wallTimeSeconds: 1.4,
                output: "hello\n",
                rawOutput: "hello\n"
            ),
            errorMessage: nil
        )
        let internalContent = try XCTUnwrap(result.internalContent?.objectValue)
        XCTAssertEqual(internalContent["kind"]?.stringValue, "example_chat.workspace_shell_execution")
        XCTAssertNotEqual(internalContent["kind"]?.stringValue, "readex.workspace_shell_execution")

        let legacyResult = ExampleChatToolResult(
            callID: "call_legacy_helper",
            name: .shell,
            ok: true,
            content: .string("legacy\n"),
            internalContent: .object([
                "kind": .string("readex.workspace_shell_execution"),
                "command": .string("cat /legacy.txt"),
                "cwd": .string("/"),
                "exit_code": .number(0),
                "wall_time_seconds": .number(0.2),
                "output": .string("legacy\n"),
                "raw_output": .string("legacy\n")
            ]),
            errorMessage: nil
        )
        let legacyShellExecution = try XCTUnwrap(
            ExampleChatShellTranscriptDisplaySupport.shellExecution(for: legacyResult, existing: nil)
        )
        XCTAssertEqual(legacyShellExecution.command, "cat /legacy.txt")
        XCTAssertEqual(legacyShellExecution.output, "legacy\n")
        XCTAssertEqual(legacyShellExecution.wallTimeSeconds, 0.2)

        let finalized = try XCTUnwrap(ExampleChatStreamingToolPresentationHelper.finalizedPresentation(
            in: started.blocks,
            activeBlockID: started.activeBlockID,
            targetBlockID: started.activeBlockID,
            activeStartedAt: started.activeStartedAt,
            explicitStartedAt: startedAt,
            text: ExampleChatShellTranscriptDisplaySupport.shellCompletedStatusText(
                for: result,
                existing: startedBlock.activityItems.first?.shellExecution
            ),
            detailText: nil,
            previewItems: [],
            chatToolName: .shell,
            chatToolBatchID: nil,
            result: result,
            at: completedAt
        ))
        let finalizedBlock = try XCTUnwrap(finalized.blocks.last)
        let finalizedItem = try XCTUnwrap(finalizedBlock.activityItems.first)
        XCTAssertEqual(finalizedBlock.text, "已执行工作区命令")
        XCTAssertEqual(finalizedBlock.status, "completed")
        XCTAssertEqual(finalizedItem.status, "completed")
        XCTAssertEqual(finalizedItem.shellExecution?.output, "hello\n")
        XCTAssertEqual(finalizedItem.commandExecution?.commandActions.first?.type, "unknown")
    }
}

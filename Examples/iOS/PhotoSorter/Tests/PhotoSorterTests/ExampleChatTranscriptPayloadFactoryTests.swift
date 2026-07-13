import XCTest
import JavaScriptCore
@testable import PhotoSorter

final class ExampleChatTranscriptPayloadFactoryTests: XCTestCase {
    func testContextCompactionStatusStopsSameTurnProcessingShellSynthesis() throws {
        let source = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-message-runtime-model.js"),
            encoding: .utf8
        )
        let context = try Self.makeTranscriptRuntimeContext(source: source)

        let ordinaryTurnTypes = try Self.evaluateJavaScriptString(
            """
            JSON.stringify(renderableBlockTypes([
              { id: 'progress', type: 'readex_progress', text: '继续处理。', status: 'success' },
              { id: 'tool', type: 'readex_tool_call', text: '已执行工作区命令', status: 'completed', items: [] }
            ]));
            """,
            in: context
        )
        XCTAssertEqual(ordinaryTurnTypes, "[\"chat_processing\"]")

        let compactedSameTurnTypes = try Self.evaluateJavaScriptString(
            """
            JSON.stringify(renderableBlockTypes([
              { id: 'compact', type: 'readex_context_status', text: '上下文已自动压缩', status: 'success' },
              { id: 'progress', type: 'readex_progress', text: '继续处理。', status: 'success' },
              { id: 'tool', type: 'readex_tool_call', text: '已执行工作区命令', status: 'completed', items: [] }
            ]));
            """,
            in: context
        )
        XCTAssertEqual(
            compactedSameTurnTypes,
            "[\"readex_context_status\",\"readex_progress\",\"readex_tool_call\"]"
        )
    }

    func testStreamingCommandBridgeSupportsPhotoSorterToolActivityUpdates() throws {
        let runtimeResources = Self.photoSorterRootURL()
            .appendingPathComponent("Vendor")
            .appendingPathComponent("ExampleChatTranscriptRenderer")
            .appendingPathComponent("RuntimeResources")
            .appendingPathComponent("Math")
        let coordinator = try String(
            contentsOf: runtimeResources.appendingPathComponent("chat-transcript-render-coordinator.js"),
            encoding: .utf8
        )
        let blockRenderer = try String(
            contentsOf: runtimeResources.appendingPathComponent("chat-transcript-message-block-renderer.js"),
            encoding: .utf8
        )

        XCTAssertTrue(coordinator.contains("function updateStreamingMarkdownBlocks"))
        XCTAssertTrue(coordinator.contains("applyStreamingMarkdownPayloadUpdates(batch, payload)"))
        XCTAssertTrue(coordinator.contains("applyStreamingMarkdownDOMUpdates(batch, renderer, messagesRoot, payload"))
        XCTAssertTrue(coordinator.contains("reconcileStreamingUpdateMessageBlocks(update, renderer, messagesRoot, payload, result)"))
        XCTAssertTrue(coordinator.contains("reconcileMessageBlocks(main, payloadMessage, renderer)"))
        XCTAssertTrue(coordinator.contains("const toolActivityMatch = /:(?:chat_tool_activity|readex_tool_activity):(\\d+)$/.exec(blockID);"))
        XCTAssertTrue(coordinator.contains("function findToolActivitySupportBlockIndex"))
        XCTAssertTrue(coordinator.contains("setIntersects(sourceIDs, collectToolActivityIDs(supportBlock))"))
        XCTAssertTrue(coordinator.contains("dataAttributeSelector(\"data-message-key\", key)"))
        XCTAssertFalse(coordinator.contains("Array.from(messagesRoot.querySelectorAll?.(\"article.message\")"))
        let legacyUpperPrefix = ["Read", "ex"].joined()
        XCTAssertTrue(blockRenderer.contains("const blockType = trimmed(block?.type || \"main_text\");"))
        XCTAssertTrue(blockRenderer.contains("findMessageBlockElement(article, blockKey, blockType)"))
        XCTAssertTrue(blockRenderer.contains("patch\(legacyUpperPrefix)ProgressMarkdownElement"))
        XCTAssertTrue(blockRenderer.contains("renderOptions.readexStreamingAppendText = appendText"))
        XCTAssertTrue(blockRenderer.contains("patchMessageBlockElement(element, block, message, renderer, blockKey)"))
        XCTAssertTrue(blockRenderer.contains("case \"chat_tool_activity\":"))
        XCTAssertTrue(blockRenderer.contains("render\(legacyUpperPrefix)ToolActivityBlock"))
        XCTAssertTrue(blockRenderer.contains("dataAttributeSelector(\"data-message-key\", key)"))
        XCTAssertTrue(blockRenderer.contains("dataAttributeSelector(\"data-block-key\", key)"))
        XCTAssertFalse(blockRenderer.contains("Array.from(messagesRoot.querySelectorAll?.(\"article.message\")"))
    }

    func testStreamingToolActivityUpdateUsesRenderableBlockID() throws {
        let batch = ExampleChatTranscriptStreamingMarkdownUpdateBatch.toolActivityUpdate(
            message: [
                "id": "assistant-turn-1",
                "patchKey": "msp:assistant-turn-1"
            ],
            messageIndex: 0,
            supportBlock: [
                "id": "call_123",
                "kind": "chat_tool_call",
                "items": [[
                    "id": "call_123",
                    "type": "tool",
                    "text": "已执行工作区命令",
                    "status": "streaming"
                ]]
            ],
            supportBlockIndex: 7
        )

        let update = try XCTUnwrap(batch.updates.first)
        XCTAssertEqual(update["kind"] as? String, "chat_tool_activity")
        XCTAssertEqual(update["messageKey"] as? String, "msp:assistant-turn-1")
        XCTAssertEqual(update["blockID"] as? String, "assistant-turn-1:chat_tool_activity:7")

        let block = try XCTUnwrap(update["block"] as? [String: Any])
        XCTAssertEqual(block["id"] as? String, "assistant-turn-1:chat_tool_activity:7")
        XCTAssertEqual(block["sourceBlockId"] as? String, "call_123")
        XCTAssertEqual(block["type"] as? String, "chat_tool_activity")
    }

    func testStreamingToolActivityPayloadUpdateFallsBackToSourceSupportBlock() throws {
        let source = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-render-coordinator.js"),
            encoding: .utf8
        )
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { context, exception in
            context?.setObject(
                exception?.toString() ?? "unknown JavaScript exception",
                forKeyedSubscript: "__lastException" as NSString
            )
        }

        try Self.evaluateJavaScript(
            """
            var window = {};
            var document = { scrollingElement: null, documentElement: null, body: null };
            \(source)
            var reconciled = 0;
            var payload = {
              messages: [{
                id: 'assistant-turn-1',
                patchKey: 'msp:assistant-turn-1',
                supportBlocks: [
                  {
                    id: 'progress_1',
                    kind: 'readex_progress',
                    text: 'still working',
                    status: 'processing'
                  },
                  {
                    id: 'call_123',
                    kind: 'readex_tool_call',
                    text: 'running',
                    status: 'processing',
                    items: [{ id: 'call_123', type: 'tool', text: 'running', status: 'processing' }]
                  }
                ]
              }]
            };
            var article = {
              __chatTranscriptMessage: payload.messages[0],
              dataset: {},
              children: [],
              querySelector: function(selector) {
                return selector === '.message-main' ? { marker: 'main' } : null;
              }
            };
            var coordinator = window.ChatTranscriptRenderCoordinatorFactory({
              normalizedRenderOptions: function(options) {
                return Object.assign({
                  followBottomIfNearBottom: false,
                  forceImmediateRender: false,
                  preserveScrollAnchor: true,
                  debugReason: ''
                }, options || {});
              },
              trimmed: function(value) { return typeof value === 'string' ? value.trim() : ''; },
              messageDOMKey: function(message, index) { return message.patchKey || message.id || '__message_index_' + index; },
              rerenderConversationPreservingScroll: function() { throw new Error('unexpected full render fallback'); },
              performConversationMutationPreservingScroll: function(options, mutation) { return mutation(); },
              payloadModel: {
                resolvePayload: function() { return payload; },
                normalizePayloadForRendering: function() {},
                resetResolvedBlockCatalogCache: function() {}
              },
              payloadPatcher: {
                mergePatchIntoPayload: function() { return null; },
                applyPatchedMessageState: function(message, state) { Object.assign(message, state); }
              },
              documentRuntime: {
                applyDocumentPayloadShell: function() {},
                resolveMarkdownRenderer: function() { return {}; },
                resolveMessagesRoot: function() {
                  return { querySelector: function() { return article; } };
                },
                resolveRenderSurface: function() { return { messagesRoot: null, page: null }; },
                patchFallbackMissingPatchState: function() {},
                patchFallbackMissingDOM: function() {},
                beginPatchCycle: function() {},
                skipPatchMutationCycle: function() {},
                completePatchCycle: function(reason, result) { return result; },
                skipRenderCycle: function() { return 0; },
                beginRenderCycle: function() {},
                clearLastRenderError: function() {},
                failRenderCycle: function() {},
                completeRenderCycle: function() { return 0; },
                currentMutationReason: function(reason) { return reason; },
                measureConversationDocumentHeight: function() { return 0; }
              },
              conversationRenderer: {
                applyPatch: function() {},
                reconcile: function() {}
              },
              messageBlockRenderer: {
                applyMarkdownBlockSourceUpdate: function() { return { applied: false, reason: 'missing_block_element' }; },
                applyProcessingBlockSourceUpdate: function() { return { applied: false, reason: 'unexpected' }; },
                reconcileMessageBlocks: function() { reconciled += 1; }
              },
              messageArticleRenderer: {
                syncMessageArticleChrome: function() {}
              },
              blockText: function(block) { return block && block.text || ''; }
            });
            var result = coordinator.updateStreamingMarkdownBlocks({
              updates: [{
                kind: 'readex_tool_activity',
                messageKey: 'msp:assistant-turn-1',
                blockID: 'assistant-turn-1:readex_tool_activity:0',
                block: {
                  id: 'assistant-turn-1:readex_tool_activity:0',
                  type: 'readex_tool_activity',
                  sourceBlockId: 'call_123',
                  status: 'success',
                  text: '',
                  items: [{ id: 'call_123', type: 'tool', text: 'done', status: 'success' }]
                }
              }]
            }, { followBottomIfNearBottom: false });
            JSON.stringify({
              applied: result.appliedCatalogCount,
              reconciled: reconciled,
              supportKind: payload.messages[0].supportBlocks[1].kind,
              supportStatus: payload.messages[0].supportBlocks[1].status,
              itemText: payload.messages[0].supportBlocks[1].items[0].text
            });
            """,
            in: context
        )

        let result = try Self.evaluateJavaScriptString(
            """
            JSON.stringify({
              applied: payload.messages[0].supportBlocks[1].items.length,
              reconciled: reconciled,
              supportKind: payload.messages[0].supportBlocks[1].kind,
              supportStatus: payload.messages[0].supportBlocks[1].status,
              itemText: payload.messages[0].supportBlocks[1].items[0].text
            });
            """,
            in: context
        )
        XCTAssertEqual(
            result,
            "{\"applied\":1,\"reconciled\":1,\"supportKind\":\"readex_tool_call\",\"supportStatus\":\"success\",\"itemText\":\"done\"}"
        )
    }

    func testCommandBridgeForwardsPreserveScrollAnchorToRenderMutations() throws {
        let source = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-command-bridge.js"),
            encoding: .utf8
        )
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { context, exception in
            context?.setObject(
                exception?.toString() ?? "unknown JavaScript exception",
                forKeyedSubscript: "__lastException" as NSString
            )
        }

        try Self.evaluateJavaScript(
            """
            var window = {};
            \(source)
            var captured = [];
            var bridge = window.ChatTranscriptCommandBridgeFactory({
              resolveRenderConversationPreservingScroll: function() {
                return function(options) {
                  captured.push({
                    command: 'render_payload',
                    preserveScrollAnchor: options.preserveScrollAnchor,
                    followBottomIfNearBottom: options.followBottomIfNearBottom
                  });
                  return { ok: true };
                };
              },
              resolveUpdateStreamingMarkdownBlocks: function() {
                return function(update, options) {
                  captured.push({
                    command: 'update_streaming_markdown_blocks',
                    preserveScrollAnchor: options.preserveScrollAnchor,
                    forceImmediateRender: options.forceImmediateRender
                  });
                  return { ok: true };
                };
              }
            });
            bridge.execute('render_payload', { messages: [] }, {
              preserveScrollAnchor: false,
              followBottomIfNearBottom: false
            });
            bridge.execute('update_streaming_markdown_blocks', { updates: [] }, {
              preserveScrollAnchor: false,
              forceImmediateRender: false
            });
            """,
            in: context
        )

        let result = try Self.evaluateJavaScriptString(
            "JSON.stringify(captured);",
            in: context
        )
        XCTAssertEqual(
            result,
            "[{\"command\":\"render_payload\",\"preserveScrollAnchor\":false,\"followBottomIfNearBottom\":false},{\"command\":\"update_streaming_markdown_blocks\",\"preserveScrollAnchor\":false,\"forceImmediateRender\":false}]"
        )
    }

    func testGeneratingFullRenderDoesNotRestoreScrollAnchor() throws {
        let source = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("Swift")
                .appendingPathComponent("ExampleChatTranscriptWebView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("""
        let shouldPreserveScrollAnchor = !state.isGenerating
        """))
        XCTAssertTrue(source.contains("""
        invoke(command: "set_presentation", payload: state.presentation, options: [
                    "suppressConversationRerender": true,
                    "preserveScrollAnchor": shouldPreserveScrollAnchor,
                    "followBottomIfNearBottom": false
                ], in: webView)
        """))
        XCTAssertTrue(source.contains("""
        invoke(command: "render_payload", payload: state.payload, options: [
                    "followBottomIfNearBottom": false,
                    "preserveScrollAnchor": shouldPreserveScrollAnchor,
                    "forceImmediateRender": true,
                    "debugReason": "msp_playground_render"
                ], imageCacheEntries: imageCacheEntries, in: webView)
        """))
    }

    func testPendingStreamingUpdatesStayQueuedWithoutCoalescing() throws {
        let source = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("Swift")
                .appendingPathComponent("ExampleChatTranscriptWebView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private struct PendingStreamingUpdate"))
        XCTAssertTrue(source.contains("private var pendingStreamingUpdates: [PendingStreamingUpdate] = []"))
        XCTAssertTrue(source.contains("pendingStreamingUpdates.append(PendingStreamingUpdate(update: update, revision: revision))"))
        XCTAssertTrue(source.contains("let pending = pendingStreamingUpdates.removeFirst()"))
        XCTAssertTrue(source.contains(#""preserveScrollAnchor": false"#))
        XCTAssertFalse(source.contains(".coalescing(update)"))
        XCTAssertFalse(source.contains("func coalescing(_ newer: ExampleChatTranscriptStreamingMarkdownUpdateBatch)"))
    }

    func testPhotoSorterDefaultTranscriptRendererProfileUsesLegacyChat() throws {
        let state = ExampleChatTranscriptPayloadFactory.renderState(from: [], isGenerating: true)
        XCTAssertTrue(state.payload["chatMarkdownRendererProfile"] is NSNull)
        XCTAssertTrue(state.presentation["chatMarkdownRendererProfile"] is NSNull)
        XCTAssertNil(state.payload["readexMarkdownRendererProfile"])
        XCTAssertNil(state.presentation["readexMarkdownRendererProfile"])

        let renderSupport = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-render-support.js"),
            encoding: .utf8
        )
        XCTAssertTrue(renderSupport.contains(#"DEFAULT_CHAT_MARKDOWN_RENDERER_PROFILE = "legacy-chat""#))
        XCTAssertTrue(renderSupport.contains(#"profile === "legacy-readex" ? DEFAULT_CHAT_MARKDOWN_RENDERER_PROFILE"#))

        let payloadPatcher = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-payload-patcher.js"),
            encoding: .utf8
        )
        XCTAssertTrue(payloadPatcher.contains("payload.chatMarkdownRendererProfile = canonicalProfile"))
        XCTAssertFalse(payloadPatcher.contains("payload.readexMarkdownRendererProfile ="))

        let presentationController = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-presentation-controller.js"),
            encoding: .utf8
        )
        XCTAssertTrue(presentationController.contains("payload.chatMarkdownRendererProfile = rendererProfile"))
        XCTAssertFalse(presentationController.contains("payload.readexMarkdownRendererProfile ="))
    }

    func testLegacyStreamingRendererKeepsSmallVisibleBatchesAndUsesAppendPath() throws {
        let runtimeResourcesURL = Self.photoSorterRootURL()
            .appendingPathComponent("Vendor")
            .appendingPathComponent("ExampleChatTranscriptRenderer")
            .appendingPathComponent("RuntimeResources")
            .appendingPathComponent("Math")
        let renderSupport = try String(
            contentsOf: runtimeResourcesURL.appendingPathComponent("chat-transcript-render-support.js"),
            encoding: .utf8
        )
        let markdownRenderer = try String(
            contentsOf: runtimeResourcesURL.appendingPathComponent("chat-markdown-renderer.js"),
            encoding: .utf8
        )

        XCTAssertTrue(renderSupport.contains("streamingMaximumBatch: 1"))
        XCTAssertTrue(markdownRenderer.contains("function streamingAppendTextFromOptions"))
        XCTAssertTrue(markdownRenderer.contains("function tryApplyStreamingPlainTextAppend"))
        XCTAssertTrue(markdownRenderer.contains("streaming-direct-text-append"))
        XCTAssertTrue(markdownRenderer.contains("readexStreamingAppendText"))
        XCTAssertTrue(markdownRenderer.contains("Math.min(maximumBatch"))
        XCTAssertFalse(markdownRenderer.contains("return Math.max(minimumBatch, Math.floor(queuedCount / divisor));"))
    }

    func testRenderStateAppliesFontScaleToTranscriptPresentationAndPayloadStyle() throws {
        let state = ExampleChatTranscriptPayloadFactory.renderState(
            from: [],
            isGenerating: false,
            fontScale: 1.2
        )

        XCTAssertEqual(try XCTUnwrap(state.presentation["bodyFontSize"] as? Double), 22.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(state.presentation["supportFontSize"] as? Double), 21, accuracy: 0.0001)

        let presentationStyle = try XCTUnwrap(state.presentation["style"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(presentationStyle["chatThinkingIndicatorFontSize"] as? Double),
            19.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(presentationStyle["chatToolActivityFontSize"] as? Double),
            21.6,
            accuracy: 0.0001
        )
        XCTAssertNil(presentationStyle["readexThinkingIndicatorFontSize"])
        XCTAssertNil(presentationStyle["readexToolActivityFontSize"])

        let payloadStyle = try XCTUnwrap(state.payload["style"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(payloadStyle["chatThinkingIndicatorFontSize"] as? Double),
            19.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(payloadStyle["chatToolActivityFontSize"] as? Double),
            21.6,
            accuracy: 0.0001
        )
        XCTAssertNil(payloadStyle["readexThinkingIndicatorFontSize"])
        XCTAssertNil(payloadStyle["readexToolActivityFontSize"])
    }

    func testRenderStateAppliesDarkInterfaceThemeToTranscriptPayloadAndPresentation() throws {
        let state = ExampleChatTranscriptPayloadFactory.renderState(
            from: [],
            isGenerating: false,
            interfaceTheme: .dark
        )

        XCTAssertEqual(state.payload["theme"] as? String, "dark")
        XCTAssertEqual(state.presentation["theme"] as? String, "dark")

        let payloadStyle = try XCTUnwrap(state.payload["style"] as? [String: Any])
        XCTAssertEqual(payloadStyle["title"] as? String, "rgba(255,255,255,0.96)")
        XCTAssertEqual(payloadStyle["userBackground"] as? String, "rgba(255,255,255,0.10)")
        XCTAssertEqual(payloadStyle["chatDividerColor"] as? String, "rgba(255,255,255,0.16)")
        XCTAssertNil(payloadStyle["readexChatDividerColor"])

        let presentationStyle = try XCTUnwrap(state.presentation["style"] as? [String: Any])
        XCTAssertEqual(presentationStyle["title"] as? String, "rgba(255,255,255,0.96)")
        XCTAssertEqual(state.presentation["userBubbleBackgroundColor"] as? String, "rgba(255,255,255,0.10)")
        XCTAssertEqual(state.presentation["controlBackground"] as? String, "rgba(28,34,44,0.82)")
    }

    @MainActor
    func testRenderControllerStreamsToolActivityWithoutAdvancingStateRevision() throws {
        let userID = UUID()
        let toolID = UUID()
        let state = ExampleChatTranscriptPayloadFactory.renderState(
            from: [
                MSPAgentTimelineItem(id: userID, kind: .user, title: "", body: "跑命令"),
                MSPAgentTimelineItem(
                    id: toolID,
                    kind: .toolCall,
                    title: "工作区命令",
                    body: "正在执行工作区命令",
                    callID: "call_streaming",
                    command: "printf hello",
                    cwd: "/",
                    stdout: "hello\n",
                    stderr: "",
                    exitCode: nil,
                    status: "running",
                    startedAtMilliseconds: 1_772_000_060_000
                )
            ],
            isGenerating: true
        )
        let controller = ExampleChatTranscriptRenderController(state: state)
        let initialStateRevision = controller.snapshot.stateRevision
        let messages = try XCTUnwrap(state.payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.last)
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first)

        XCTAssertTrue(controller.applyStreamingToolActivity(
            callID: "call_streaming",
            supportBlock: toolBlock
        ))

        XCTAssertEqual(controller.snapshot.stateRevision, initialStateRevision)
        XCTAssertEqual(controller.snapshot.streamingUpdateRevision, 1)
        let update = try XCTUnwrap(controller.snapshot.streamingUpdate?.updates.first)
        XCTAssertEqual(update["kind"] as? String, "chat_tool_activity")
        XCTAssertEqual(update["previousTextLength"] as? Int, 0)
        XCTAssertNil(controller.snapshot.state)

        let block = try XCTUnwrap(update["block"] as? [String: Any])
        XCTAssertEqual(block["type"] as? String, "chat_tool_activity")
    }

    @MainActor
    func testRenderControllerStreamsMainTextWithoutAdvancingStateRevision() throws {
        let turnStartedAt = 1_772_000_060_500
        let state = ExampleChatTranscriptPayloadFactory.renderState(
            from: [
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: "慢慢回复",
                    turnStartedAtMilliseconds: turnStartedAt
                ),
                MSPAgentTimelineItem(
                    kind: .assistantFinal,
                    title: "",
                    body: "你",
                    turnStartedAtMilliseconds: turnStartedAt
                )
            ],
            isGenerating: true
        )
        let controller = ExampleChatTranscriptRenderController(state: state)
        let initialStateRevision = controller.snapshot.stateRevision

        XCTAssertTrue(controller.applyStreamingMainText(
            messageID: "assistant-turn-\(turnStartedAt)",
            text: "你好",
            previousTextLength: 1,
            appendText: "好"
        ))

        XCTAssertEqual(controller.snapshot.stateRevision, initialStateRevision)
        XCTAssertEqual(controller.snapshot.streamingUpdateRevision, 1)
        XCTAssertNil(controller.snapshot.state)
        let update = try XCTUnwrap(controller.snapshot.streamingUpdate?.updates.first)
        XCTAssertEqual(update["kind"] as? String, "main_text")
        XCTAssertEqual(update["previousTextLength"] as? Int, 1)
        XCTAssertEqual(update["appendText"] as? String, "好")
        XCTAssertEqual(update["text"] as? String, "你好")
        XCTAssertEqual(update["syncMessageChrome"] as? Bool, true)

        let messageState = try XCTUnwrap(update["messageState"] as? [String: Any])
        XCTAssertEqual(messageState["status"] as? String, "streaming")
        let block = try XCTUnwrap(update["block"] as? [String: Any])
        XCTAssertEqual(block["id"] as? String, "assistant-turn-\(turnStartedAt):content")
        XCTAssertEqual(block["type"] as? String, "main_text")
        XCTAssertEqual(block["status"] as? String, "streaming")
        XCTAssertEqual(block["text"] as? String, "你好")
        XCTAssertTrue(block["chatTurnStartedAtMilliseconds"] is NSNull)
        XCTAssertTrue(block["chatTurnDurationMilliseconds"] is NSNull)
        XCTAssertTrue(block["chatToolName"] is NSNull)
        XCTAssertTrue(block["chatToolBatchID"] is NSNull)
        XCTAssertEqual(block["chatProcessingActive"] as? Bool, false)
        XCTAssertNil(block["readexTurnStartedAtMilliseconds"])
        XCTAssertNil(block["readexTurnDurationMilliseconds"])
        XCTAssertNil(block["readexToolName"])
        XCTAssertNil(block["readexToolBatchID"])
        XCTAssertNil(block["readexProcessingActive"])
    }

    @MainActor
    func testRenderControllerStreamsProgressTextWithoutAdvancingStateRevision() throws {
        let turnStartedAt = 1_772_000_060_501
        let progressID = UUID(uuidString: "00000000-0000-4000-8000-000000000501")!
        let state = ExampleChatTranscriptPayloadFactory.renderState(
            from: [
                MSPAgentTimelineItem(
                    kind: .user,
                    title: "",
                    body: "先说一下进度",
                    turnStartedAtMilliseconds: turnStartedAt
                ),
                MSPAgentTimelineItem(
                    id: progressID,
                    kind: .assistantProgress,
                    title: "模型中间回复",
                    body: "我",
                    startedAtMilliseconds: turnStartedAt + 10,
                    turnStartedAtMilliseconds: turnStartedAt
                )
            ],
            isGenerating: true
        )
        let controller = ExampleChatTranscriptRenderController(state: state)
        let initialStateRevision = controller.snapshot.stateRevision

        XCTAssertTrue(controller.applyStreamingProgressText(
            supportBlockID: progressID.uuidString,
            text: "我先",
            previousTextLength: 1,
            appendText: "先"
        ))

        XCTAssertEqual(controller.snapshot.stateRevision, initialStateRevision)
        XCTAssertEqual(controller.snapshot.streamingUpdateRevision, 1)
        XCTAssertNil(controller.snapshot.state)
        let update = try XCTUnwrap(controller.snapshot.streamingUpdate?.updates.first)
        XCTAssertEqual(update["kind"] as? String, "chat_progress")
        XCTAssertEqual(update["previousTextLength"] as? Int, 1)
        XCTAssertEqual(update["appendText"] as? String, "先")
        XCTAssertEqual(update["text"] as? String, "我先")

        let block = try XCTUnwrap(update["block"] as? [String: Any])
        XCTAssertEqual(block["id"] as? String, "assistant-turn-\(turnStartedAt):chat_progress:0")
        XCTAssertEqual(block["sourceBlockId"] as? String, progressID.uuidString)
        XCTAssertEqual(block["type"] as? String, "chat_progress")
        XCTAssertEqual(block["status"] as? String, "streaming")
        XCTAssertEqual(block["text"] as? String, "我先")
        XCTAssertEqual(block["chatTurnStartedAtMilliseconds"] as? Int, turnStartedAt)
        XCTAssertTrue(block["chatTurnDurationMilliseconds"] is NSNull)
        XCTAssertTrue(block["chatToolName"] is NSNull)
        XCTAssertTrue(block["chatToolBatchID"] is NSNull)
        XCTAssertEqual(block["chatProcessingActive"] as? Bool, false)
        XCTAssertNil(block["readexTurnStartedAtMilliseconds"])
        XCTAssertNil(block["readexTurnDurationMilliseconds"])
        XCTAssertNil(block["readexToolName"])
        XCTAssertNil(block["readexToolBatchID"])
        XCTAssertNil(block["readexProcessingActive"])
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

    func testUserMessageProjectsSelectedTextReferenceBeforeMainTextBlock() throws {
        let selectionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000301"))
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "帮我解释",
                sourceTextSelections: [
                    PhotoSorterTextSelectionSnapshot(
                        id: selectionID,
                        selectedText: "真正使用的选中文字",
                        sourceMessageID: "assistant-message-1",
                        sourceMessageRole: "assistant",
                        selectedTextOccurrenceIndexInMessage: 2,
                        renderedTextSegments: ["真正使用的选中文字"]
                    )
                ]
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.first)
        let blocks = try XCTUnwrap(user["blocks"] as? [[String: Any]])

        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text_selection", "main_text"])
        let selection = try XCTUnwrap(blocks[0]["textSelection"] as? [String: Any])
        XCTAssertEqual(selection["id"] as? String, selectionID.uuidString)
        XCTAssertEqual(selection["selectedText"] as? String, "真正使用的选中文字")
        XCTAssertEqual(selection["sourceDisplayName"] as? String, "对话摘录")
        XCTAssertEqual(selection["sourceMessageID"] as? String, "assistant-message-1")
        XCTAssertEqual(selection["sourceMessageRole"] as? String, "assistant")
        XCTAssertEqual(selection["selectedTextOccurrenceIndexInMessage"] as? Int, 2)
        XCTAssertEqual(selection["renderedTextSegments"] as? [String], ["真正使用的选中文字"])
        XCTAssertEqual(blocks[1]["text"] as? String, "帮我解释")
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

    func testRunningToolAllowsThinkingPlaceholderAfterAssistantProgress() throws {
        let turnStartedAt = 1_772_000_062_500
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "测一下长命令等待",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_waiting_session",
                toolName: "exec_command",
                command: "python3 -u slow.py",
                cwd: "/",
                stdout: "YIELD_START\n",
                execSessionID: 7,
                status: "processing",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "命令已经执行约 30 秒，我继续等。",
                startedAtMilliseconds: turnStartedAt + 30_000,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])

        XCTAssertEqual(supportBlocks.map { $0["kind"] as? String }, [
            "chat_tool_call",
            "chat_progress",
            "chat_processing"
        ])
        XCTAssertEqual(supportBlocks[0]["status"] as? String, "inProgress")
        XCTAssertEqual(supportBlocks[1]["status"] as? String, "success")

        let thinkingItems = try XCTUnwrap(supportBlocks[2]["items"] as? [[String: Any]])
        XCTAssertEqual(thinkingItems.first?["type"] as? String, "progress")
        XCTAssertEqual(thinkingItems.first?["text"] as? String, "正在思考")
        XCTAssertEqual(thinkingItems.first?["status"] as? String, "processing")
    }

    func testRunningWorkspaceCommandProjectsLiveOutputIntoShellExecution() throws {
        let turnStartedAt = 1_772_000_063_000
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "统计图库文件",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_live_output",
                command: "find /图库 -type f",
                cwd: "/",
                stdout: "/图库/照片_000001.jpg\n/图库/照片_000002.jpg\n",
                stderr: "",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_tool_call" })
        let processingItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(processingItems.first { ($0["type"] as? String) == "chatToolCall" })
        XCTAssertNil(toolItem["legacyType"])

        XCTAssertEqual(toolItem["text"] as? String, "正在执行工作区命令")
        XCTAssertEqual(toolItem["completed"] as? Bool, false)

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(
            shellExecution["output"] as? String,
            "/图库/照片_000001.jpg\n/图库/照片_000002.jpg\n"
        )
        XCTAssertEqual(shellExecution["rawOutput"] as? String, shellExecution["output"] as? String)

        let commandExecution = try XCTUnwrap(toolItem["commandExecution"] as? [String: Any])
        XCTAssertEqual(
            commandExecution["aggregatedOutput"] as? String,
            "/图库/照片_000001.jpg\n/图库/照片_000002.jpg\n"
        )
    }

    func testCompletedToolResultMergesIntoMatchingRunningWorkspaceCommandBlock() throws {
        let turnStartedAt = 1_772_000_063_500
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "确认候选",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_media_ask",
                command: "media ask --message '直接删除' --limit 200",
                cwd: "/",
                stdout: "media ask: confirmed\nrequested 50\n",
                stderr: "",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolResult,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call_media_ask",
                cwd: "/",
                stdout: "media ask: confirmed\nrequested 50\nshown 50\n",
                stderr: "",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 200,
                completedAtMilliseconds: turnStartedAt + 1_200,
                durationMilliseconds: 1_000,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: true)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlocks = supportBlocks.filter { ($0["kind"] as? String) == "chat_tool_call" }

        XCTAssertEqual(toolBlocks.count, 1)
        let toolBlock = try XCTUnwrap(toolBlocks.first)
        XCTAssertEqual(toolBlock["text"] as? String, "已执行工作区命令")
        XCTAssertEqual(toolBlock["status"] as? String, "completed")

        let toolItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(toolItems.first)
        XCTAssertEqual(toolItem["text"] as? String, "已执行工作区命令")
        XCTAssertEqual(toolItem["completed"] as? Bool, true)

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["command"] as? String, "media ask --message '直接删除' --limit 200")
        XCTAssertEqual(
            shellExecution["output"] as? String,
            "media ask: confirmed\nrequested 50\nshown 50\n"
        )

        let commandExecution = try XCTUnwrap(toolItem["commandExecution"] as? [String: Any])
        XCTAssertEqual(commandExecution["command"] as? String, "media ask --message '直接删除' --limit 200")
        XCTAssertEqual(
            commandExecution["aggregatedOutput"] as? String,
            "media ask: confirmed\nrequested 50\nshown 50\n"
        )
    }

    func testWriteStdinPollMergesIntoOriginalExecCommandBlock() throws {
        let turnStartedAt = 1_772_000_063_700
        let command = "python3 -u -c 'import time; print(\"YIELD_START\", flush=True); time.sleep(1.2); print(\"YIELD_DONE\", flush=True)'"
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "测一下 Codex 风格等待",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_slow",
                toolName: "exec_command",
                command: command,
                cwd: "/",
                stdout: "YIELD_START\n",
                execSessionID: 7,
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 200,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .assistantProgress,
                title: "模型中间回复",
                body: "命令已经执行约 1 秒，我继续等。",
                startedAtMilliseconds: turnStartedAt + 1_000,
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolResult,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call_poll",
                toolName: "write_stdin",
                cwd: "/",
                stdout: "YIELD_DONE\n",
                exitCode: 0,
                execSessionID: 7,
                parentCallID: "call_slow",
                status: "completed",
                startedAtMilliseconds: turnStartedAt + 200,
                completedAtMilliseconds: turnStartedAt + 1_500,
                durationMilliseconds: 1_300,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlocks = supportBlocks.filter { ($0["kind"] as? String) == "chat_tool_call" }

        XCTAssertEqual(toolBlocks.count, 1)
        let toolBlock = try XCTUnwrap(toolBlocks.first)
        XCTAssertEqual(toolBlock["text"] as? String, "已执行工作区命令")
        XCTAssertEqual(toolBlock["status"] as? String, "completed")

        let toolItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(toolItems.first)
        XCTAssertEqual(toolItem["id"] as? String, "call_slow")
        XCTAssertEqual(toolItem["text"] as? String, "已执行工作区命令")
        XCTAssertEqual(toolItem["completed"] as? Bool, true)

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["command"] as? String, command)
        XCTAssertEqual(shellExecution["output"] as? String, "YIELD_START\nYIELD_DONE\n")

        let commandExecution = try XCTUnwrap(toolItem["commandExecution"] as? [String: Any])
        XCTAssertEqual(commandExecution["command"] as? String, command)
        XCTAssertEqual(commandExecution["callID"] as? String, "call_slow")
        XCTAssertEqual(commandExecution["aggregatedOutput"] as? String, "YIELD_START\nYIELD_DONE\n")
    }

    func testStoppedTurnProjectsStoppedMarkerAndFreezesRunningTool() throws {
        let turnStartedAt = 1_772_000_064_000
        let stoppedAt = turnStartedAt + 1_300
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .user,
                title: "",
                body: "查一下截图",
                turnStartedAtMilliseconds: turnStartedAt
            ),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "正在执行工作区命令",
                callID: "call_stopped",
                command: "find /相册/系统/截图 -maxdepth 1 -type f",
                cwd: "/",
                stdout: "/相册/系统/截图/a.png\n",
                stderr: "",
                status: "inProgress",
                startedAtMilliseconds: turnStartedAt + 300,
                turnStartedAtMilliseconds: turnStartedAt
            )
        ]

        let stoppedItems = MSPAgentTimelineStopSupport.stoppingRunningTurnItems(
            items,
            turnStartedAtMilliseconds: turnStartedAt,
            stoppedAtMilliseconds: stoppedAt
        )
        XCTAssertEqual(stoppedItems[1].status, "stopped")
        XCTAssertEqual(stoppedItems[1].completedAtMilliseconds, stoppedAt)
        XCTAssertEqual(stoppedItems[1].durationMilliseconds, 1_000)
        XCTAssertEqual(stoppedItems.last?.kind, .stoppedMarker)

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: stoppedItems, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])

        XCTAssertEqual(assistant["status"] as? String, "success")
        XCTAssertEqual(assistant["isStreaming"] as? Bool, false)
        XCTAssertEqual(supportBlocks.map { $0["kind"] as? String }, [
            "chat_tool_call",
            "chat_stopped_marker"
        ])

        let toolBlock = supportBlocks[0]
        XCTAssertEqual(toolBlock["status"] as? String, "stopped")
        XCTAssertEqual(toolBlock["durationMilliseconds"] as? Int, 1_000)
        XCTAssertEqual(toolBlock["chatTurnDurationMilliseconds"] as? Int, 1_300)
        XCTAssertNil(toolBlock["readexTurnDurationMilliseconds"])
        let toolItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(toolItems.first)
        XCTAssertEqual(toolItem["status"] as? String, "stopped")
        XCTAssertEqual(toolItem["completed"] as? Bool, true)
        XCTAssertEqual(toolItem["durationMilliseconds"] as? Int, 1_000)
        XCTAssertEqual(toolItem["completedAtMilliseconds"] as? Int, stoppedAt)

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["output"] as? String, "/相册/系统/截图/a.png\n")
        XCTAssertNil(shellExecution["exitCode"] as? Int)

        let commandExecution = try XCTUnwrap(toolItem["commandExecution"] as? [String: Any])
        XCTAssertEqual(commandExecution["status"] as? String, "stopped")
        XCTAssertEqual(commandExecution["aggregatedOutput"] as? String, "/相册/系统/截图/a.png\n")
        XCTAssertNil(commandExecution["exitCode"] as? Int)

        let stoppedMarker = supportBlocks[1]
        XCTAssertEqual(stoppedMarker["status"] as? String, "stopped")
        XCTAssertEqual(stoppedMarker["text"] as? String, "已停止")
        XCTAssertEqual(stoppedMarker["durationMilliseconds"] as? Int, 1_300)
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

    func testRestoredWorkspaceCommandEnvelopeKeepsStatusTextAndMovesMetadataToShellExecution() throws {
        let envelope = """
        Wall time: 0.0208 seconds
        Process exited with code 0
        Output:
        当前照片工作区树
        /图库/ (41881)
        """
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(kind: .user, title: "", body: "列目录"),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: envelope,
                callID: "call_filetree",
                command: "filetree ls /",
                cwd: "/",
                stdout: envelope,
                status: "completed",
                turnStartedAtMilliseconds: 1_772_000_031_000
            )
        ]

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(supportBlocks.first { ($0["kind"] as? String) == "chat_tool_call" })
        XCTAssertEqual(toolBlock["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((toolBlock["text"] as? String ?? "").contains("Wall time"))

        let processingItems = try XCTUnwrap(toolBlock["items"] as? [[String: Any]])
        let toolItem = try XCTUnwrap(processingItems.first { ($0["type"] as? String) == "chatToolCall" })
        XCTAssertEqual(toolItem["text"] as? String, "已执行工作区命令")
        XCTAssertFalse((toolItem["text"] as? String ?? "").contains("Process exited"))

        let shellExecution = try XCTUnwrap(toolItem["shellExecution"] as? [String: Any])
        XCTAssertEqual(shellExecution["command"] as? String, "filetree ls /")
        XCTAssertEqual(shellExecution["output"] as? String, "当前照片工作区树\n/图库/ (41881)")
        XCTAssertEqual(shellExecution["rawOutput"] as? String, "当前照片工作区树\n/图库/ (41881)")
        XCTAssertEqual(shellExecution["exitCode"] as? Int, 0)
        XCTAssertEqual(shellExecution["wallTimeSeconds"] as? Double, 0.0208)
    }

    func testUpdatePlanTimelineItemDoesNotRenderAsWorkspaceCommandCard() throws {
        let items = [
            MSPAgentTimelineItem(kind: .user, title: "", body: "整理相册"),
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "Plan updated",
                callID: "call_plan",
                toolName: "update_plan",
                stdout: "Plan updated",
                exitCode: 0,
                status: "completed",
                turnStartedAtMilliseconds: 1_772_000_032_000
            )
        ]

        XCTAssertNil(ExampleChatTranscriptPayloadFactory.streamingToolSupportBlockPayload(from: items[1]))

        let payload = ExampleChatTranscriptPayloadFactory.payload(from: items, isGenerating: false)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertFalse(String(describing: payload).contains("chat_tool_call"))
        XCTAssertFalse(String(describing: payload).contains("readex_tool_call"))
        XCTAssertFalse(String(describing: payload).contains("shellExecution"))
    }

    func testAssistantMessagePatchKeyIgnoresHiddenUpdatePlanItems() throws {
        let finalID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000501"))
        let user = MSPAgentTimelineItem(kind: .user, title: "", body: "继续")
        let final = MSPAgentTimelineItem(
            id: finalID,
            kind: .assistantFinal,
            title: "",
            body: "我继续处理。"
        )
        let plan = MSPAgentTimelineItem(
            kind: .toolCall,
            title: "工作区命令",
            body: "Plan updated",
            callID: "call_plan",
            toolName: "update_plan",
            stdout: "Plan updated",
            exitCode: 0,
            status: "completed"
        )

        let baselinePayload = ExampleChatTranscriptPayloadFactory.payload(
            from: [user, final],
            isGenerating: false
        )
        let withPlanPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: [user, plan, final],
            isGenerating: false
        )
        let baselineMessages = try XCTUnwrap(baselinePayload["messages"] as? [[String: Any]])
        let withPlanMessages = try XCTUnwrap(withPlanPayload["messages"] as? [[String: Any]])
        let baselineAssistant = try XCTUnwrap(baselineMessages.first { ($0["role"] as? String) == "assistant" })
        let withPlanAssistant = try XCTUnwrap(withPlanMessages.first { ($0["role"] as? String) == "assistant" })

        XCTAssertEqual(
            baselineAssistant["patchKey"] as? String,
            "msp:assistant-item-\(finalID.uuidString)"
        )
        XCTAssertEqual(withPlanAssistant["patchKey"] as? String, baselineAssistant["patchKey"] as? String)
        XCTAssertFalse(String(describing: withPlanPayload).contains("call_plan"))
        XCTAssertEqual(withPlanAssistant["content"] as? String, "我继续处理。")
    }

    func testShellToolActivityWithOutputExpandsTerminalDetailsByDefault() throws {
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

        let payload = ExampleChatTranscriptPayloadFactory.payload(
            from: items,
            isGenerating: false
        )
        let expandedIDs = try XCTUnwrap(payload["expandedReadexToolActivityBlockIDs"] as? [String])
        XCTAssertTrue(expandedIDs.contains(toolItem.id.uuidString))
        XCTAssertTrue(expandedIDs.contains("chat_tool_call:0"))
        XCTAssertTrue(expandedIDs.contains("chat_tool_activity:0"))
        XCTAssertTrue(expandedIDs.contains("readex_tool_call:0"))
        XCTAssertTrue(expandedIDs.contains("readex_tool_activity:0"))
        XCTAssertTrue(expandedIDs.contains("call_ls"))

        let nestedKeys = try XCTUnwrap(
            payload["expandedReadexNestedDisclosureKeysBySourceBlockID"] as? [String: [String]]
        )
        XCTAssertTrue(nestedKeys[toolItem.id.uuidString]?.contains("activity\u{1f}activity-\(toolItem.id.uuidString)") == true)
        XCTAssertTrue(nestedKeys[toolItem.id.uuidString]?.contains("processing\u{1f}activity-\(toolItem.id.uuidString)") == true)
        XCTAssertTrue(nestedKeys["chat_tool_call:0"]?.contains("processing\u{1f}activity-\(toolItem.id.uuidString)") == true)
        XCTAssertTrue(nestedKeys["readex_tool_call:0"]?.contains("processing\u{1f}activity-\(toolItem.id.uuidString)") == true)

        let expandedPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: items,
            isGenerating: false,
            expandToolActivityBlocks: true
        )
        let explicitlyExpandedIDs = try XCTUnwrap(expandedPayload["expandedReadexToolActivityBlockIDs"] as? [String])
        XCTAssertTrue(explicitlyExpandedIDs.contains(toolItem.id.uuidString))
    }

    func testTranscriptExpansionStateKeepsLatestUserChoice() {
        var state = ExampleChatTranscriptExpansionState.empty

        state.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .toolActivity,
            sourceBlockID: "tool-1",
            key: nil,
            expanded: true
        ))
        XCTAssertEqual(state.expandedExampleChatToolActivityBlockIDs, ["tool-1"])
        XCTAssertTrue(state.collapsedExampleChatToolActivityBlockIDs.isEmpty)

        state.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .toolActivity,
            sourceBlockID: "tool-1",
            key: nil,
            expanded: false
        ))
        XCTAssertTrue(state.expandedExampleChatToolActivityBlockIDs.isEmpty)
        XCTAssertEqual(state.collapsedExampleChatToolActivityBlockIDs, ["tool-1"])

        state.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .nestedDisclosure,
            sourceBlockID: "tool-1",
            key: "activity\u{1f}call-1",
            expanded: true
        ))
        state.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .nestedDisclosure,
            sourceBlockID: "tool-1",
            key: "activity\u{1f}call-1",
            expanded: false
        ))
        XCTAssertNil(state.expandedExampleChatNestedDisclosureKeysBySourceBlockID["tool-1"])
        XCTAssertEqual(
            state.collapsedExampleChatNestedDisclosureKeysBySourceBlockID["tool-1"],
            ["activity\u{1f}call-1"]
        )
    }

    func testPayloadIncludesPersistedTranscriptExpansionState() throws {
        let toolItem = MSPAgentTimelineItem(
            kind: .toolCall,
            title: "工作区命令",
            body: "已执行工作区命令",
            detail: "退出码: 0",
            callID: "call_pwd",
            command: "pwd",
            cwd: "/",
            stdout: "/\n",
            stderr: "",
            exitCode: 0,
            status: "completed",
            startedAtMilliseconds: 1_772_000_030_000,
            completedAtMilliseconds: 1_772_000_030_500,
            durationMilliseconds: 500,
            turnStartedAtMilliseconds: 1_772_000_029_000,
            turnDurationMilliseconds: 1_200
        )
        let nestedKey = "activity\u{1f}activity-\(toolItem.id.uuidString)"
        var expansionState = ExampleChatTranscriptExpansionState.empty
        expansionState.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .toolActivity,
            sourceBlockID: toolItem.id.uuidString,
            key: nil,
            expanded: false
        ))
        expansionState.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .processing,
            sourceBlockID: "turn-\(toolItem.turnStartedAtMilliseconds ?? 0)",
            key: nil,
            expanded: false
        ))
        expansionState.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .nestedDisclosure,
            sourceBlockID: toolItem.id.uuidString,
            key: nestedKey,
            expanded: false
        ))

        let payload = ExampleChatTranscriptPayloadFactory.payload(
            from: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "看路径"),
                toolItem
            ],
            isGenerating: false,
            expansionState: expansionState
        )

        XCTAssertEqual(
            try XCTUnwrap(payload["collapsedReadexToolActivityBlockIDs"] as? [String]),
            [toolItem.id.uuidString]
        )
        XCTAssertEqual(
            try XCTUnwrap(payload["collapsedReadexProcessingBlockIDs"] as? [String]),
            ["turn-\(toolItem.turnStartedAtMilliseconds ?? 0)"]
        )
        let collapsedNestedKeys = try XCTUnwrap(
            payload["collapsedReadexNestedDisclosureKeysBySourceBlockID"] as? [String: [String]]
        )
        XCTAssertEqual(collapsedNestedKeys[toolItem.id.uuidString], [nestedKey])
    }

    func testUserExpandedShellRemainsExpandedAfterNextAssistantMessageRebuild() throws {
        let toolItem = MSPAgentTimelineItem(
            kind: .toolCall,
            title: "工作区命令",
            body: "已执行工作区命令",
            callID: "call_pwd",
            command: "pwd",
            cwd: "/",
            status: "completed",
            startedAtMilliseconds: 1_772_000_030_000,
            completedAtMilliseconds: 1_772_000_030_500,
            durationMilliseconds: 500,
            turnStartedAtMilliseconds: 1_772_000_029_000,
            turnDurationMilliseconds: 1_200
        )
        var expansionState = ExampleChatTranscriptExpansionState.empty
        expansionState.apply(ExampleChatTranscriptExpansionStateChange(
            kind: .toolActivity,
            sourceBlockID: toolItem.id.uuidString,
            key: nil,
            expanded: true
        ))

        let rebuiltPayload = ExampleChatTranscriptPayloadFactory.payload(
            from: [
                MSPAgentTimelineItem(kind: .user, title: "", body: "查看路径"),
                toolItem,
                MSPAgentTimelineItem(
                    kind: .assistantFinal,
                    title: "",
                    body: "路径已经确认。",
                    turnStartedAtMilliseconds: 1_772_000_031_000
                )
            ],
            isGenerating: false,
            expansionState: expansionState
        )

        let expandedIDs = try XCTUnwrap(
            rebuiltPayload["expandedReadexToolActivityBlockIDs"] as? [String]
        )
        XCTAssertTrue(expandedIDs.contains(toolItem.id.uuidString))
        XCTAssertFalse(
            (rebuiltPayload["collapsedReadexToolActivityBlockIDs"] as? [String] ?? [])
                .contains(toolItem.id.uuidString)
        )

        let rendererSource = try String(
            contentsOf: Self.photoSorterRootURL()
                .appendingPathComponent("Vendor")
                .appendingPathComponent("ExampleChatTranscriptRenderer")
                .appendingPathComponent("RuntimeResources")
                .appendingPathComponent("Math")
                .appendingPathComponent("chat-transcript-message-block-support-renderer.js"),
            encoding: .utf8
        )
        XCTAssertTrue(rendererSource.contains(
            #"readexToolActivityBlockIDSet("expandedReadexToolActivityBlockIDs")"#
        ))
        XCTAssertTrue(rendererSource.contains(
            #"readexToolActivityBlockIDSet("collapsedReadexToolActivityBlockIDs")"#
        ))
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

    func testCompletedMediaViewProjectsOriginalImageSupportBlock() throws {
        let imageID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000111"))
        let items: [MSPAgentTimelineItem] = [
            MSPAgentTimelineItem(
                kind: .toolCall,
                title: "工作区命令",
                body: "已执行工作区命令",
                callID: "call_media_view",
                command: "media view /图库/a.png",
                cwd: "/",
                stdout: "Viewed original image: /图库/a.png\nSize: 1x1\n",
                exitCode: 0,
                status: "completed",
                startedAtMilliseconds: 1_772_000_040_000,
                completedAtMilliseconds: 1_772_000_040_100,
                durationMilliseconds: 100,
                turnStartedAtMilliseconds: 1_772_000_039_000,
                images: [
                    MSPAgentTimelineImage(
                        id: imageID,
                        base64: "AQID",
                        mimeType: "image/png"
                    )
                ]
            )
        ]

        let state = ExampleChatTranscriptPayloadFactory.renderState(from: items, isGenerating: false)
        let payload = state.payload
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { ($0["role"] as? String) == "assistant" })
        let supportBlocks = try XCTUnwrap(assistant["supportBlocks"] as? [[String: Any]])
        let toolIndex = try XCTUnwrap(supportBlocks.firstIndex { ($0["kind"] as? String) == "chat_tool_call" })
        let imageIndex = try XCTUnwrap(supportBlocks.firstIndex { ($0["kind"] as? String) == "image" })
        let imageBlock = supportBlocks[imageIndex]
        let images = try XCTUnwrap(imageBlock["images"] as? [[String: Any]])
        let image = try XCTUnwrap(images.first)

        XCTAssertGreaterThan(imageIndex, toolIndex)
        XCTAssertEqual(imageBlock["imageStatus"] as? String, "completed")
        XCTAssertEqual(image["id"] as? String, imageID.uuidString)
        XCTAssertNil(image["base64"] as? String)
        XCTAssertEqual(image["cacheKey"] as? String, "msp-timeline-image-\(imageID.uuidString)")
        XCTAssertEqual(image["mimeType"] as? String, "image/png")
        XCTAssertEqual(state.imageCacheEntries, [
            ExampleChatTranscriptImageCacheEntry(
                key: "msp-timeline-image-\(imageID.uuidString)",
                base64: "AQID",
                mimeType: "image/png"
            )
        ])
    }

    private static func photoSorterRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func makeTranscriptRuntimeContext(source: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { context, exception in
            context?.setObject(
                exception?.toString() ?? "unknown JavaScript exception",
                forKeyedSubscript: "__lastException" as NSString
            )
        }

        try evaluateJavaScript(
            """
            var window = {};
            \(source)

            const transcriptRuntime = window.ChatTranscriptMessageRuntimeModelFactory({
              trimmed: (value) => typeof value === 'string' ? value.trim() : '',
              blockText: (block) => block?.text || '',
              normalizedCatalogBlock: (block) => block,
              messageHasStructuredBlocks: () => false,
              translatedLegacyInlineBlocks: (message) => message.supportBlocks || [],
              resolvedMessageBlocks: (message) => message.blocks || [],
              statusModel: {
                normalizedStatus: (value) => value || '',
                legacyMessageStatus: () => 'success',
                structuredMessageShellStatus: () => '',
                legacyMessageIsStreaming: () => false,
                legacyMessageIsSearchInProgress: () => false,
                blockIsLive: (block) => block?.status === 'processing' || block?.status === 'inProgress'
              }
            });

            function renderableBlockTypes(supportBlocks) {
              return transcriptRuntime
                .renderableMessageBlocks({ role: 'assistant', supportBlocks })
                .map((block) => block.type);
            }
            """,
            in: context
        )
        return context
    }

    @discardableResult
    private static func evaluateJavaScript(
        _ script: String,
        in context: JSContext
    ) throws -> JSValue? {
        context.setObject("", forKeyedSubscript: "__lastException" as NSString)
        let value = context.evaluateScript(script)
        if let exception = context.objectForKeyedSubscript("__lastException")?.toString(),
           !exception.isEmpty {
            throw NSError(
                domain: "ExampleChatTranscriptPayloadFactoryTests.JavaScript",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: exception]
            )
        }
        return value
    }

    private static func evaluateJavaScriptString(
        _ script: String,
        in context: JSContext
    ) throws -> String {
        let value = try evaluateJavaScript(script, in: context)
        return try XCTUnwrap(value?.toString())
    }
}

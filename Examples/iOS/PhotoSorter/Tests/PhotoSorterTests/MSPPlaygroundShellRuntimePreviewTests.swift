import CoreGraphics
import Foundation
import Darwin
import MSPAgentBridge
import ModelShellProxy
import XCTest
@testable import PhotoSorter

final class MSPPlaygroundShellRuntimePreviewTests: XCTestCase {
    @MainActor
    func testThumbnailCacheKeyIncludesWorkspaceCacheVersion() {
        let node = WorkspaceFileNode(
            name: "same.jpg",
            path: "/图库/same.jpg",
            type: .regularFile,
            size: 123,
            modificationDate: Date(timeIntervalSince1970: 42),
            mediaKind: .image
        )

        let firstVersionKey = MSPPlaygroundShellRuntime.thumbnailCacheKey(
            for: node,
            targetSize: CGSize(width: 40, height: 40),
            cacheVersion: "index-ready-1-workspace-0"
        )
        let sameVersionKey = MSPPlaygroundShellRuntime.thumbnailCacheKey(
            for: node,
            targetSize: CGSize(width: 40, height: 40),
            cacheVersion: "index-ready-1-workspace-0"
        )
        let nextWorkspaceVersionKey = MSPPlaygroundShellRuntime.thumbnailCacheKey(
            for: node,
            targetSize: CGSize(width: 40, height: 40),
            cacheVersion: "index-ready-1-workspace-1"
        )

        XCTAssertEqual(firstVersionKey, sameVersionKey)
        XCTAssertNotEqual(firstVersionKey, nextWorkspaceVersionKey)
        XCTAssertTrue(firstVersionKey.contains("index-ready-1-workspace-0"))
        XCTAssertTrue(nextWorkspaceVersionKey.contains("index-ready-1-workspace-1"))
    }

    @MainActor
    func testQuickLookURLResolvesLocalWorkspaceFile() throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let tmpURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        let fileURL = tmpURL.appendingPathComponent("agent-notes.txt")
        try "hello from agent\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let runtime = try Self.makeRuntime(rootURL: rootURL)

        XCTAssertEqual(
            runtime.quickLookURL(for: "/tmp/agent-notes.txt")?.standardizedFileURL,
            fileURL.standardizedFileURL
        )
    }

    @MainActor
    func testQuickLookURLIgnoresDirectoriesAndPhotoLibraryVirtualPaths() throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runtime = try Self.makeRuntime(rootURL: rootURL)

        XCTAssertNil(runtime.quickLookURL(for: "/tmp"))
        XCTAssertNil(runtime.quickLookURL(for: "/图库/example.jpg"))
    }

    @MainActor
    func testPhotoSorterShellExcludesExpensiveContentCommandsButKeepsNavigationCommands() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let tmpURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try "scratch\n".write(
            to: tmpURL.appendingPathComponent("agent-notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let runtime = try Self.makeRuntime(rootURL: rootURL)

        let blocked = await runtime.run("sha256sum --version")
        let find = await runtime.run("find / -maxdepth 1 -type d")
        let cat = await runtime.run("cat /tmp/agent-notes.txt")

        XCTAssertEqual(blocked.exitCode, 127)
        XCTAssertEqual(blocked.stderr, "sha256sum: command not found\n")
        XCTAssertEqual(find.exitCode, 0)
        XCTAssertEqual(cat.exitCode, 0)
        XCTAssertEqual(cat.stdout, "scratch\n")
    }

    @MainActor
    func testPhotoSorterShellRegistersChatReadCommand() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let help = await runtime.run("chat help read")

        XCTAssertEqual(help.exitCode, 0)
        XCTAssertEqual(help.stderr, "")
        XCTAssertTrue(help.stdout.contains("chat read <path>"))
        XCTAssertTrue(help.stdout.contains("--scope full|recent"))
        XCTAssertTrue(help.stdout.contains("--json"))
    }

    @MainActor
    func testPhotoSorterShellFindsChatPackagesAsFilesAndReadsThem() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let packageURL = rootURL
            .appendingPathComponent("对话", isDirectory: true)
            .appendingPathComponent("历史.chat", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try """
        {
          "format": "msp.chat",
          "version": 1,
          "package_id": "chatpkg_photosorter_shell_file_facade",
          "created_at": "2026-07-03T00:00:00Z",
          "updated_at": "2026-07-03T00:00:02Z",
          "profiles": ["core-timeline"],
          "capabilities": ["read_core"],
          "timeline": {
            "path": "timeline.ndjson",
            "encoding": "utf-8",
            "record_format": "ndjson"
          }
        }
        """.write(
            to: packageURL.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"id":"evt_photosorter_chat_001","type":"message","seq":1,"created_at":"2026-07-03T00:00:00Z","durability":"durable_replay","payload":{"role":"user","content":"继续整理照片"}}
        {"id":"evt_photosorter_chat_002","type":"message","seq":2,"created_at":"2026-07-03T00:00:01Z","durability":"durable_replay","payload":{"role":"assistant","phase":"final","content":"我会接着上次的整理上下文继续。"}}
        """.write(
            to: packageURL.appendingPathComponent("timeline.ndjson"),
            atomically: true,
            encoding: .utf8
        )

        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let findFiles = await runtime.run("find / -name '*.chat' -type f | sort")
        let findDirs = await runtime.run("find / -name '*.chat' -type d | sort")
        let findInsidePackage = await runtime.run("find /对话/历史.chat -maxdepth 2 -print")
        let read = await runtime.run("chat read /对话/历史.chat")

        XCTAssertEqual(findFiles.exitCode, 0, findFiles.stderr)
        XCTAssertEqual(findFiles.stdout, "/对话/历史.chat\n")
        XCTAssertEqual(findDirs.exitCode, 0, findDirs.stderr)
        XCTAssertEqual(findDirs.stdout, "")
        XCTAssertEqual(findInsidePackage.exitCode, 0, findInsidePackage.stderr)
        XCTAssertEqual(findInsidePackage.stdout, "/对话/历史.chat\n")
        XCTAssertEqual(read.exitCode, 0, read.stderr)
        XCTAssertTrue(read.stdout.hasPrefix("# 对话归档\n"))
        XCTAssertTrue(read.stdout.contains("路径：/对话/历史.chat"))
        XCTAssertTrue(read.stdout.contains("### 用户\n\n继续整理照片"))
        XCTAssertTrue(read.stdout.contains("### AI\n\n我会接着上次的整理上下文继续。"))
    }

    @MainActor
    func testPhotoSorterExecCommandBridgeYieldsAndPollsSession() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()

        let firstRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'start\\n'; sleep 0.35; printf 'end\\n'",
            yieldTimeMilliseconds: 100
        ))

        let sessionID = try XCTUnwrap(firstRead.runningSessionID)
        var output = firstRead.result.stdout
        var exitCode = firstRead.exitCode

        for _ in 0..<8 where exitCode == nil {
            let poll = await bridge.writeStdin(MSPWriteStdinCall(
                sessionID: sessionID,
                chars: "",
                yieldTimeMilliseconds: 100
            ))
            output += poll.result.stdout
            exitCode = poll.exitCode
            if poll.runningSessionID == nil {
                break
            }
        }

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.contains("start\n"), output)
        XCTAssertTrue(output.contains("end\n"), output)
    }

    @MainActor
    func testPhotoSorterExecSessionPollDoesNotWaitForSlowLiveOutputHandler() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()
        let slowOutputHandler: MSPExecCommandOutputHandler = { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let firstRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "sleep 0.4; printf 'slow-handler-done\\n'",
            yieldTimeMilliseconds: 250
        ), onOutput: slowOutputHandler)

        let sessionID = try XCTUnwrap(firstRead.runningSessionID)
        let startedAt = Date()
        let poll = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "",
            yieldTimeMilliseconds: 1
        ), onOutput: slowOutputHandler)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertNil(poll.runningSessionID)
        XCTAssertEqual(poll.exitCode, 0)
        XCTAssertEqual(poll.result.stdout, "slow-handler-done\n")
        XCTAssertEqual(poll.result.stderr, "")
    }

    @MainActor
    func testPhotoSorterExecSessionLiveOutputHandlerStaysOrderedWhenSlow() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()
        let capture = ShellOutputEventCapture()
        let outputHandler: MSPExecCommandOutputHandler = { event in
            if event.text.contains("ORDER_1") {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            await capture.append(event.text)
        }

        let read = await bridge.runSession(MSPExecCommandCall(
            cmd: "printf 'ORDER_1\\n'; sleep 0.05; printf 'ORDER_2\\n'; sleep 0.05; printf 'ORDER_3\\n'",
            yieldTimeMilliseconds: 1_000
        ), onOutput: outputHandler)
        XCTAssertEqual(read.exitCode, 0)

        var joined = ""
        for _ in 0..<20 {
            joined = await capture.events().joined()
            if joined.contains("ORDER_3\n") {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(joined.contains("ORDER_1\n"), joined)
        XCTAssertTrue(joined.contains("ORDER_2\n"), joined)
        XCTAssertTrue(joined.contains("ORDER_3\n"), joined)
        XCTAssertLessThan(
            joined.distance(from: joined.startIndex, to: joined.range(of: "ORDER_1\n")!.lowerBound),
            joined.distance(from: joined.startIndex, to: joined.range(of: "ORDER_2\n")!.lowerBound)
        )
        XCTAssertLessThan(
            joined.distance(from: joined.startIndex, to: joined.range(of: "ORDER_2\n")!.lowerBound),
            joined.distance(from: joined.startIndex, to: joined.range(of: "ORDER_3\n")!.lowerBound)
        )
    }

    @MainActor
    func testPhotoSorterExecCommandBridgeWritesNonEmptyStdinToPipeSession() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()

        let firstRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "cat",
            yieldTimeMilliseconds: 100
        ))

        let sessionID = try XCTUnwrap(firstRead.runningSessionID)
        XCTAssertEqual(firstRead.result.stdout, "")
        XCTAssertEqual(firstRead.result.stderr, "")

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "hello from photosorter\n",
            yieldTimeMilliseconds: 100
        ))

        XCTAssertEqual(write.runningSessionID, sessionID)
        XCTAssertEqual(write.exitCode, nil)
        XCTAssertEqual(write.result.stdout, "hello from photosorter\n")
        XCTAssertEqual(write.result.stderr, "")

        let eof = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{4}",
            yieldTimeMilliseconds: 250
        ))

        XCTAssertNil(eof.runningSessionID)
        XCTAssertEqual(eof.exitCode, 0)
        XCTAssertEqual(eof.result.stdout, "")
        XCTAssertEqual(eof.result.stderr, "")
    }

    @MainActor
    func testPhotoSorterExecCommandBridgeReadBuiltinConsumesLiveStdinByRecord() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()

        let firstRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "read -r FIRST; printf 'first:%s\\n' \"$FIRST\"; read -r SECOND; printf 'second:%s\\n' \"$SECOND\"",
            yieldTimeMilliseconds: 100
        ))

        let sessionID = try XCTUnwrap(firstRead.runningSessionID)
        XCTAssertEqual(firstRead.result.stdout, "")
        XCTAssertEqual(firstRead.result.stderr, "")

        let write = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "alpha\nbeta\n",
            yieldTimeMilliseconds: 500
        ))

        XCTAssertNil(write.runningSessionID)
        XCTAssertEqual(write.exitCode, 0)
        XCTAssertEqual(write.result.stdout, "first:alpha\nsecond:beta\n")
        XCTAssertEqual(write.result.stderr, "")
    }

    @MainActor
    func testPhotoSorterExecCommandBridgeLateWriteAfterEOFReturnsCompletedResult() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)
        let bridge = runtime.execCommandBridge()

        let firstRead = await bridge.runSession(MSPExecCommandCall(
            cmd: "cat >/dev/null; sleep 0.6; printf 'after-eof\\n'",
            yieldTimeMilliseconds: 100
        ))

        let sessionID = try XCTUnwrap(firstRead.runningSessionID)

        let eof = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "\u{4}",
            yieldTimeMilliseconds: 1
        ))

        XCTAssertEqual(eof.runningSessionID, sessionID)
        XCTAssertEqual(eof.exitCode, nil)

        try await Task.sleep(nanoseconds: 750_000_000)

        let lateWrite = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "too late\n",
            yieldTimeMilliseconds: 100
        ))

        XCTAssertNil(lateWrite.runningSessionID)
        XCTAssertEqual(lateWrite.exitCode, 0)
        XCTAssertEqual(lateWrite.result.stdout, "after-eof\n")
        XCTAssertEqual(lateWrite.result.stderr, "")
    }

    @MainActor
    func testAlbumHelpWorksThroughRuntimeStderrMergeAndHeadPipeline() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)

        let result = await runtime.run("album --help 2>&1 | head -120")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("album add [--create] --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(result.stdout.contains("album remove --from-file <path-list> <user-album-path>"))
        XCTAssertTrue(result.stdout.contains("album rm <user-album-path>..."))
        XCTAssertTrue(result.stdout.contains("album rm --from-file <path-list>"))
    }

    @MainActor
    func testPhotoSorterPressureRootScriptCompletesWithoutBlockingOnPhotoIndex() async throws {
        let rootURL = try Self.makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = try Self.makeRuntime(rootURL: rootURL)

        let command = """
        pwd
        ls -la /
        ls -la /图库
        ls -la /相册
        ls -la /相册/系统
        ls -la /相册/用户
        ls -la /最近删除
        ls -la /tmp
        mkdir -p /tmp/photo-pressure
        ls -la / > /tmp/photo-pressure/root-list.txt
        {
          echo '### /相册'
          ls -la /相册
          echo
          echo '### /相册/系统'
          ls -la /相册/系统
        } > /tmp/photo-pressure/album-list.txt
        {
          echo '照片工作区结构简要记录：'
          echo '- 根目录包含照片库视图 /图库、相册视图 /相册、最近删除 /最近删除，以及临时目录 /tmp。'
        } > /tmp/photo-pressure/summary.txt
        (ls -la /图库/does-not-exist.jpg) > /tmp/photo-pressure/missing-gallery-error.txt 2>&1 || true
        find /tmp/photo-pressure -maxdepth 1 -type f | sort
        """

        let result = try await Self.runWithTimeout(seconds: 3) {
            await runtime.run(command)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("/tmp/photo-pressure/root-list.txt"))
        XCTAssertTrue(result.stdout.contains("/tmp/photo-pressure/album-list.txt"))
        XCTAssertTrue(result.stdout.contains("/tmp/photo-pressure/summary.txt"))
        XCTAssertTrue(result.stdout.contains("/tmp/photo-pressure/missing-gallery-error.txt"))
    }

    @MainActor
    func testShellCommandExecutorRunsCommandHandlersOffMainThread() async throws {
        let shell = ModelShellProxy()
        try shell.register("thread-check") { _, _ in
            MSPCommandResult(stdout: pthread_main_np() == 1 ? "main\n" : "background\n")
        }
        let executor = MSPPlaygroundShellCommandExecutor(shell: shell)

        let result = await executor.run("thread-check")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "background\n")
    }

    func testShellOutputCoalescerDoesNotFlushOnEveryLine() async {
        let capture = ShellOutputEventCapture()
        let coalescer = MSPPlaygroundShellOutputCoalescer(
            stream: .stdout,
            command: "printf",
            startedAt: Date(),
            diagnosticsLog: .shared,
            outputHandler: { event in
                await capture.append(event.text)
            }
        )

        await coalescer.append(Data("first\n".utf8))
        await coalescer.append(Data("second\n".utf8))

        let eventsBeforeFlush = await capture.events()
        XCTAssertEqual(eventsBeforeFlush, [])

        await coalescer.flush()

        let eventsAfterFlush = await capture.events()
        XCTAssertEqual(eventsAfterFlush, ["first\nsecond\n"])
    }

    @MainActor
    func testAgentRuntimeCanStartTurnOffMainThreadAndReturnUIErrorOnMainThread() async {
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { _ in MSPCommandResult() },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared
        )
        let callbackCapture = AgentRuntimeCallbackCapture()

        let startedOffMainThread = await Task.detached {
            let startedOffMainThread = pthread_main_np() == 0
            await runtime.runTurn(
                userMessage: "hello",
                configuration: .placeholder,
                codexOAuthConfiguration: .empty,
                agentAccessMode: .standard,
                sensitiveReadPolicy: .askEveryTime,
                onRequestBuilt: { _ in },
                onEvent: { _ in },
                onRuntimeError: { text in
                    callbackCapture.recordRuntimeError(
                        text,
                        wasOnMainThread: pthread_main_np() == 1
                    )
                }
            )
            return startedOffMainThread
        }.value

        XCTAssertTrue(startedOffMainThread)
        XCTAssertTrue(callbackCapture.runtimeErrorWasOnMainThread)
        XCTAssertTrue(callbackCapture.runtimeErrorText.contains("模型"))
    }

    @MainActor
    func testAgentRuntimeBuildsPhotoSorterPromptLayers() async {
        let requestCapture = AgentRuntimeRequestBodyCapture()
        let configurationCapture = AgentConversationConfigurationCapture()
        let modelRequestCapture = AgentModelRequestCapture()
        let modelClient = CapturingAgentModelClient(requestCapture: modelRequestCapture)
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { _ in MSPCommandResult() },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared,
            runtimeFactory: { _, execCommandBridge in
                MSPAgentRuntime(
                    modelClientFactory: { conversationConfiguration in
                        configurationCapture.record(conversationConfiguration)
                        return modelClient
                    },
                    execCommandBridge: execCommandBridge
                )
            }
        )

        await runtime.runTurn(
            userMessage: "帮我整理截图",
            configuration: MSPModelConfiguration(
                providerName: "Test",
                baseURL: URL(string: "http://127.0.0.1:1/v1"),
                apiKey: "test-key",
                modelID: "test-model",
                reasoningEffort: "medium",
                verbosity: "low"
            ),
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .askEveryTime,
            onRequestBuilt: { body in
                requestCapture.record(body)
            },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )

        guard let body = requestCapture.requestBody else {
            XCTFail("Expected runtime to build a request before transport failure")
            return
        }

        guard let conversationConfiguration = configurationCapture.configuration else {
            XCTFail("Expected runtime to build a conversation configuration")
            return
        }
        XCTAssertTrue(conversationConfiguration.compactionPolicy.enabled)
        XCTAssertEqual(conversationConfiguration.compactionPolicy.tokenLimitScope, .bodyAfterPrefix)
        XCTAssertFalse(conversationConfiguration.compactionPolicy.tokenBudgetFeatureEnabled)
        XCTAssertTrue(conversationConfiguration.compactionPolicy.remoteCompactionEnabled)
        XCTAssertFalse(conversationConfiguration.compactionPolicy.remoteCompactionV2Enabled)

        XCTAssertTrue(body.instructions.contains("You are PhotoSorter"))
        XCTAssertTrue(body.instructions.contains("Linux-like command environment"))
        XCTAssertTrue(body.instructions.contains("Python scripts may be used"))
        XCTAssertTrue(body.instructions.contains("current-stage path list with at most 3000"))
        XCTAssertTrue(body.instructions.contains("Stage paths are paths considered in this stage"))
        XCTAssertTrue(body.instructions.contains("media list /相册/系统/截图 > /tmp/screenshots_batch1.txt"))
        XCTAssertTrue(body.instructions.contains("raw recall matches to stdout"))
        XCTAssertTrue(body.instructions.contains("Raw matches are not refined candidates"))
        XCTAssertTrue(body.instructions.contains("Raw matching paths are written directly to `/tmp/ocr_matches.txt`"))
        XCTAssertTrue(body.instructions.contains("Raw matching paths are written directly to `/tmp/vlm_matches.txt`"))
        XCTAssertTrue(body.instructions.contains("media search --ocr"))
        XCTAssertTrue(body.instructions.contains("Treat `media search --ocr` and `media search --vlm` results as raw recall matches"))
        XCTAssertTrue(body.instructions.contains("raw recall matches, not final candidates"))
        XCTAssertTrue(body.instructions.contains("Stage files are the source of truth for batch media paths"))
        XCTAssertTrue(body.instructions.contains("do not hand-write large path arrays, heredocs, or copied path lists in Python or shell"))
        XCTAssertTrue(body.instructions.contains("Multi-command batches that create or consume stage files should start with `set -e`"))
        XCTAssertTrue(body.instructions.contains("do not use hard-coded assertions such as `assert len(paths) == 100`"))
        XCTAssertTrue(body.instructions.contains("Python must not be the source of a large hand-written list of photo paths"))
        XCTAssertTrue(body.instructions.contains("that exact photo's full cached OCR text must be personally read in your own model-visible context before you do anything with that photo"))
        XCTAssertTrue(body.instructions.contains("Before you have personally read that exact photo's full cached OCR text in your own model-visible context, performing any operation on that photo is not allowed at all"))
        XCTAssertTrue(body.instructions.contains("\"Any operation\" includes keeping it in or excluding it from a refined list"))
        XCTAssertTrue(body.instructions.contains("writing a reason/confidence for it, sending it to `media ask`, placing it in a review album"))
        XCTAssertTrue(body.instructions.contains("This is a per-media-item rule: satisfying it for one media item does not satisfy it for any other media item"))
        XCTAssertTrue(body.instructions.contains("If OCR is uncached, do not treat OCR as reviewed"))
        XCTAssertTrue(body.instructions.contains("This requirement applies to every single image independently"))
        XCTAssertTrue(body.instructions.contains("Search snippets, search JSONL, sampling"))
        XCTAssertTrue(body.instructions.contains("Correct workflow: first write raw search matches to a match file"))
        XCTAssertTrue(body.instructions.contains("printed in model-visible command output and you considered it yourself"))
        XCTAssertTrue(body.instructions.contains("write it to `/tmp` first, then read the evidence file back into model-visible output in contiguous line ranges"))
        XCTAssertTrue(body.instructions.contains("sed -n '1,500p' /tmp/ocr_match_evidence_chunk1.txt"))
        XCTAssertTrue(body.instructions.contains("sed -n '501,1000p' /tmp/ocr_match_evidence_chunk1.txt"))
        XCTAssertTrue(body.instructions.contains("complete OCR/VLM record has appeared in your model-visible context"))
        XCTAssertTrue(body.instructions.contains("Merely redirecting evidence to `/tmp`"))
        XCTAssertTrue(body.instructions.contains("it must not be the thing that reads OCR/VLM evidence and decides which raw matches are refined candidates"))
        XCTAssertTrue(body.instructions.contains("If there are too many raw matches to evidence-review now"))
        XCTAssertTrue(body.instructions.contains("a larger input limit such as 200 is acceptable because cached OCR is being read, not live OCR"))
        XCTAssertTrue(body.instructions.contains("came directly from `media search --vlm`"))
        XCTAssertTrue(body.instructions.contains("acceptable for bounded evidence review because those paths are known to have cached VLM matches"))
        XCTAssertTrue(body.instructions.contains("do not assume VLM is cached"))
        XCTAssertTrue(body.instructions.contains("media show --ocr --from-file /tmp/ocr_matches_review_chunk1.txt --limit 50"))
        XCTAssertTrue(body.instructions.contains("media show --vlm --from-file /tmp/vlm_matches_review_chunk1.txt --limit 50"))
        XCTAssertTrue(body.instructions.contains("media show --ocr --from-file /tmp/ocr_matches_review_chunk1.txt --limit 200 > /tmp/ocr_match_evidence_chunk1.txt"))
        XCTAssertTrue(body.instructions.contains("media show --ocr --from-file /tmp/selected_for_ocr.txt --limit 20"))
        XCTAssertTrue(body.instructions.contains("media show --vlm --from-file /tmp/selected_for_vlm.txt --limit 3"))
        XCTAssertTrue(body.instructions.contains("media view --from-file /tmp/uncertain_paths.txt --limit 20"))
        XCTAssertTrue(body.instructions.contains("media ask --message <short user-facing message> --from-jsonl <candidate-jsonl> --limit 200"))
        XCTAssertTrue(body.instructions.contains("for cleanup, deletion, move, album-organization, or classification candidate sets after you have personally reviewed per-item evidence"))
        XCTAssertTrue(body.instructions.contains("--write-selected /tmp/ask_selected.txt --write-excluded /tmp/ask_excluded.txt --write-skipped /tmp/ask_skipped.txt"))
        XCTAssertTrue(body.instructions.contains("Use them for follow-up commands instead of reconstructing long path lists from stdout"))
        XCTAssertTrue(body.instructions.contains("skipped is not a user rejection or preservation signal"))
        XCTAssertTrue(body.instructions.contains("For evidence-reviewed candidate sets, create a JSONL file in `/tmp`"))
        XCTAssertTrue(body.instructions.contains("path` plus optional `title`, `confidence`, `basis`, `matched_terms`, `risk`, and `detail`"))
        XCTAssertTrue(body.instructions.contains("json.dumps(..., ensure_ascii=False)"))
        XCTAssertTrue(body.instructions.contains("The JSONL must be built from refined candidates, not raw search matches"))
        XCTAssertTrue(body.instructions.contains("sending that set with `media ask --from-file`, bare path operands, or any review UI without per-item JSONL reasons is not allowed at all"))
        XCTAssertTrue(body.instructions.contains("A global `--message` is not a substitute for per-item reasons"))
        XCTAssertTrue(body.instructions.contains("Correct workflow after evidence review"))
        XCTAssertTrue(body.instructions.contains("Use `media ask --from-file` only for path-only review"))
        XCTAssertTrue(body.instructions.contains("Do not use it for evidence-reviewed cleanup, deletion, move, album-organization, or classification candidates"))
        XCTAssertTrue(body.instructions.contains("Search JSONL snippets are recall evidence only"))
        XCTAssertTrue(body.instructions.contains("they do not count as full per-image evidence review"))
        XCTAssertTrue(body.instructions.contains("media ask --message \"我根据 OCR、截图相册和缓存视觉摘要筛出了这些疑似物流临时截图"))
        XCTAssertTrue(body.instructions.contains("media search --ocr --format jsonl"))
        XCTAssertTrue(body.instructions.contains("path, source, query_kind, query, match, and snippet"))
        XCTAssertTrue(body.instructions.contains("`--message` text is shown to the user"))
        XCTAssertTrue(body.instructions.contains("not for sending original media contents to the model"))
        XCTAssertTrue(body.instructions.contains("what evidence you used, and how confident you are"))
        XCTAssertTrue(body.instructions.contains("把握较高"))
        XCTAssertTrue(body.instructions.contains("do not invent numeric percentages"))
        XCTAssertTrue(body.instructions.contains("Do not imply that you visually inspected the original images unless you actually used `media view`"))
        XCTAssertTrue(body.instructions.contains("我根据截图相册、时间范围和 OCR 文字筛出了疑似验证码/登录码截图"))
        XCTAssertTrue(body.instructions.contains("我根据缓存视觉摘要和少量元数据筛出了疑似游戏截图"))
        XCTAssertTrue(body.instructions.contains("我综合 OCR 文字、缓存视觉摘要和日期信息筛出了这些疑似购物/物流截图"))
        XCTAssertTrue(body.instructions.contains("我只按相册和时间范围做了初筛"))
        XCTAssertTrue(body.instructions.contains("Treat the user's selection and note as the source of truth"))
        XCTAssertTrue(body.instructions.contains("evidence-review raw matches yourself first, write a refined candidate list"))
        XCTAssertTrue(body.instructions.contains("create refined candidates yourself as much as reasonably possible"))
        XCTAssertTrue(body.instructions.contains("`excluded` means the user saw the media item and unchecked it"))
        XCTAssertTrue(body.instructions.contains("Media evidence commands such as `media show`, `media show --ocr`, and `media show --vlm` may include `media ask excluded count by user: N`"))
        XCTAssertTrue(body.instructions.contains("If this line is absent for a media item, treat its recorded count as 0"))
        XCTAssertTrue(body.instructions.contains("Any positive count is a user preservation intent and low-candidate signal"))
        XCTAssertTrue(body.instructions.contains("avoid repeatedly asking about the same item unless the user asks or the current task gives a clear reason"))
        XCTAssertTrue(body.instructions.contains("look for the common reason the user may have unchecked them before"))
        XCTAssertTrue(body.instructions.contains("This is open-ended: repeated exclusions can indicate any user-specific keep preference"))
        XCTAssertTrue(body.instructions.contains("Do not turn examples into hard rules and do not delete solely from this signal"))
        XCTAssertTrue(body.instructions.contains("我看到你之前多次取消勾选物理学习类照片"))
        XCTAssertTrue(body.instructions.contains("do not include them again in later `media ask` batches for the same task"))
        XCTAssertTrue(body.instructions.contains("`skipped` means the photo was not confirmed by the user"))
        XCTAssertTrue(body.instructions.contains("failed to load, timed out, was unavailable, or the user confirmed before it appeared"))
        XCTAssertTrue(body.instructions.contains("do not skip user review merely to reduce burden"))
        XCTAssertTrue(body.instructions.contains("consideration for the user's attention and fatigue"))
        XCTAssertTrue(body.instructions.contains("200-item limit is a hard maximum, not a target size"))
        XCTAssertTrue(body.instructions.contains("Avoid making the user review many consecutive batches"))
        XCTAssertTrue(body.instructions.contains("continue with the same review pace"))
        XCTAssertTrue(body.instructions.contains("after a couple of batches"))
        XCTAssertTrue(body.instructions.contains("create one current-stage path list with `media list <scope>`"))
        XCTAssertTrue(body.instructions.contains("Separate stage path generation, raw search matches, evidence-reviewed refined candidates, user-confirmed paths, and actions"))
        XCTAssertTrue(body.instructions.contains("stage path count, raw match count, refined candidate count, user-confirmed count"))
        XCTAssertTrue(body.instructions.contains("For less common options, run `filetree --help`, `media --help`, `media help <topic>`, or `album help <topic>`"))
        XCTAssertTrue(body.instructions.contains("When the user explicitly asks to inspect, summarize, continue from, compare, or answer questions about a saved `.chat` conversation file"))
        XCTAssertTrue(body.instructions.contains("chat read <path> --scope recent --turn-limit 5"))
        XCTAssertTrue(body.instructions.contains("chat read <path> --scope full"))
        XCTAssertTrue(body.instructions.contains("Do not proactively read saved chat records unless the user asks for a saved `.chat` conversation"))
        XCTAssertTrue(body.instructions.contains("focused refined candidate sets"))
        XCTAssertTrue(body.instructions.contains("A review path must contain refined candidates, not raw search matches"))
        XCTAssertTrue(body.instructions.contains("Create them only from refined candidates, never from raw search matches"))
        XCTAssertTrue(body.instructions.contains("dumping full-library OCR or VLM results into a temp file; for raw matches, surface full evidence into model-visible output in bounded evidence-review chunks instead"))
        XCTAssertTrue(body.instructions.contains("media show --ocr --from-file /tmp/cleanup_ocr_matches.txt --limit 50"))
        XCTAssertTrue(body.instructions.contains("media show --vlm --from-file /tmp/cleanup_vlm_matches.txt --limit 50"))
        XCTAssertTrue(body.instructions.contains("Do not create the refined file by copying a raw match file unchanged"))
        XCTAssertTrue(body.instructions.contains("by letting a script parse OCR/VLM evidence and decide matches for you"))
        XCTAssertTrue(body.instructions.contains("Safe refinement shape after the required evidence for each included image has been visible in your context and reviewed by you"))
        XCTAssertTrue(body.instructions.contains("derive from the"))
        XCTAssertTrue(body.instructions.contains("existing match file instead of retyping paths"))
        XCTAssertTrue(body.instructions.contains("awk 'NR==3 || NR==7 || NR==12' /tmp/cleanup_ocr_matches.txt"))
        XCTAssertTrue(body.instructions.contains("refined_count=%s"))
        XCTAssertTrue(body.instructions.contains("Unreviewed raw matches must remain out of the refined list"))
        XCTAssertTrue(body.instructions.contains("build `/tmp/cleanup_refined_with_reasons.jsonl` from the evidence-reviewed refined set"))
        XCTAssertTrue(body.instructions.contains("Do not fall back to `media ask --from-file` after evidence review"))
        XCTAssertTrue(body.instructions.contains("media trash --from-file /tmp/cleanup_refined.txt --limit 200"))
        XCTAssertTrue(body.instructions.contains("album add --create --from-file /tmp/refined_candidates.txt"))
        XCTAssertTrue(body.instructions.contains("album add --create --from-file /tmp/target_a_refined.txt"))
        XCTAssertTrue(body.instructions.contains("When cached VLM is available and useful"))
        XCTAssertTrue(body.instructions.contains("Never decide that a media item should be deleted, moved, added to a final album, or sent as a refined cleanup candidate based only on VLM"))
        XCTAssertTrue(body.instructions.contains("VLM is a small local-model summary and can be wrong or incomplete"))
        XCTAssertTrue(body.instructions.contains("final refinement must combine all available evidence, especially the item's own full OCR when cached or obtainable"))
        XCTAssertTrue(body.instructions.contains("If VLM is the only content evidence, treat the item as uncertain"))
        XCTAssertTrue(body.instructions.contains("When both OCR and VLM evidence are available for the same media item, use both together before refinement or action"))
        XCTAssertTrue(body.instructions.contains("Do not ignore OCR because VLM looks confident, and do not ignore VLM when visual content matters"))
        XCTAssertTrue(body.instructions.contains("If OCR and VLM disagree, cover different parts of the image, or one signal is weak or irrelevant, lower confidence"))
        XCTAssertFalse(body.instructions.contains("album add --create --from-file /tmp/cleanup_candidates.txt"))
        XCTAssertFalse(body.instructions.contains("album add --create --from-file /tmp/target_a_paths.txt"))
        XCTAssertFalse(body.instructions.contains("album add --create --from-file /tmp/target_b_paths.txt"))
        XCTAssertFalse(body.instructions.contains("Use OCR and/or VLM depending on access mode"))
        XCTAssertFalse(body.instructions.contains("media trash --from-file /tmp/cleanup_candidates.txt --limit 200"))
        XCTAssertFalse(body.instructions.contains("head -20 /tmp/selected_for_ocr.txt"))
        XCTAssertFalse(body.instructions.contains("head -20 /tmp/uncertain_paths.txt"))
        XCTAssertFalse(body.instructions.contains("media show --ocr --from-file /tmp/selected_for_ocr.txt --limit 20 >"))
        XCTAssertFalse(body.instructions.contains("media show --vlm --from-file /tmp/selected_for_vlm.txt --limit 3 >"))
        XCTAssertFalse(body.instructions.contains("/tmp/cleanup_ocr_evidence.txt"))
        XCTAssertFalse(body.instructions.contains("/tmp/cleanup_vlm_evidence.txt"))
        XCTAssertFalse(body.instructions.contains("refined = ["))
        XCTAssertFalse(body.instructions.contains("Path(\"/tmp/cleanup_refined.txt\").write_text"))
        XCTAssertFalse(body.instructions.contains("create one current-stage candidate list"))
        XCTAssertFalse(body.instructions.contains("candidate count, matched count, confirmed count"))
        XCTAssertFalse(body.instructions.contains("When you have per-item reasons, prefer `media ask --from-jsonl`"))
        XCTAssertFalse(body.instructions.contains("when per-item reasons are available, otherwise"))
        XCTAssertFalse(body.instructions.contains("xargs -d '\\n' -a /tmp/selected_for_ocr.txt -n 20 media show --ocr"))
        XCTAssertFalse(body.instructions.contains("xargs -d '\\n' -a /tmp/uncertain_paths.txt -n 20 media view"))
        XCTAssertTrue(body.instructions.contains("Do not run several tool-call rounds in a row"))
        XCTAssertTrue(body.instructions.contains("consider calling `update_plan` before the first scan or action"))
        XCTAssertTrue(body.instructions.contains("Agent-created review albums"))
        XCTAssertFalse(body.instructions.contains("You are working with a Linux workspace"))
        XCTAssertTrue(body.promptCacheKey?.hasPrefix("photosorter-agent-v41:") == true)
        XCTAssertTrue(body.tools.map(\.name).contains(MSPUpdatePlanToolSchema.name))

        let developerText = body.input.first?.content.map(\.text).joined(separator: "\n") ?? ""
        XCTAssertTrue(developerText.contains("PhotoSorter dynamic context"))
        XCTAssertTrue(developerText.contains("Execution surface: Linux-like command environment for the PhotoSorter workspace."))
        XCTAssertFalse(developerText.contains("默认工作区文件树"))
        XCTAssertFalse(developerText.contains("大相册和大批量策略"))
    }

    @MainActor
    func testSensitiveReadPolicyChangePreservesModelTranscriptHistory() async throws {
        let modelRequestCapture = AgentModelRequestCapture()
        let modelClient = CapturingAgentModelClient(requestCapture: modelRequestCapture)
        let factoryCounter = AgentRuntimeFactoryCounter()
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { _ in MSPCommandResult() },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared,
            runtimeFactory: { _, execCommandBridge in
                factoryCounter.increment()
                return MSPAgentRuntime(
                    modelClientFactory: { _ in modelClient },
                    execCommandBridge: execCommandBridge
                )
            }
        )
        let configuration = Self.agentConfiguration(modelID: "test-model")

        await runtime.runTurn(
            userMessage: "第一轮",
            configuration: configuration,
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .askEveryTime,
            onRequestBuilt: { _ in },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )
        await runtime.runTurn(
            userMessage: "继续",
            configuration: configuration,
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .alwaysAllow,
            onRequestBuilt: { _ in },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )

        XCTAssertEqual(factoryCounter.value, 1)
        let secondInputText = try await modelRequestCapture.inputJSONText(at: 1)
        XCTAssertTrue(secondInputText.contains("msg_history_0"))
        XCTAssertTrue(secondInputText.contains("第一轮完成"))
        XCTAssertTrue(secondInputText.contains("Sensitive media read policy: always allow."))
        XCTAssertFalse(secondInputText.contains("Sensitive media read policy: ask every time."))
    }

    @MainActor
    func testAgentRuntimeForwardsIncrementalTranscriptSnapshots() async throws {
        let modelRequestCapture = AgentModelRequestCapture()
        let modelClient = CapturingAgentModelClient(requestCapture: modelRequestCapture)
        let snapshotCapture = AgentRuntimeTranscriptSnapshotCapture()
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { _ in MSPCommandResult() },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared,
            runtimeFactory: { _, execCommandBridge in
                MSPAgentRuntime(
                    modelClientFactory: { _ in modelClient },
                    execCommandBridge: execCommandBridge
                )
            }
        )

        await runtime.runTurn(
            userMessage: "第一轮",
            configuration: Self.agentConfiguration(modelID: "test-model"),
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .askEveryTime,
            onRequestBuilt: { _ in },
            onTranscriptSnapshotUpdated: { items in
                await snapshotCapture.append(items)
            },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )

        let snapshots = await snapshotCapture.snapshots()
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
        XCTAssertEqual(Self.agentInputSignatures(from: snapshots[0]), [
            "message:user:第一轮"
        ])
        XCTAssertTrue(
            snapshots.contains { snapshot in
                Self.agentInputSignatures(from: snapshot).contains("message:assistant:第一轮完成")
            }
        )
    }

    @MainActor
    func testAgentRuntimeInterruptPreservesStoppedContextForImmediateFollowup() async throws {
        let modelRequestCapture = AgentModelRequestCapture()
        let modelClient = InterruptibleAgentModelClient(requestCapture: modelRequestCapture)
        let commandGate = BlockingPhotoSorterCommandGate()
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { call, _ in
                XCTAssertEqual(call.cmd, "sleep 3000")
                await commandGate.runUntilReleased()
                return .success(stdout: "late\n")
            },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared,
            runtimeFactory: { _, execCommandBridge in
                MSPAgentRuntime(
                    modelClientFactory: { _ in modelClient },
                    execCommandBridge: execCommandBridge
                )
            }
        )
        let configuration = Self.agentConfiguration(modelID: "test-model")

        let firstTurn = Task {
            await runtime.runTurn(
                userMessage: "第一轮：运行慢命令",
                configuration: configuration,
                codexOAuthConfiguration: .empty,
                agentAccessMode: .standard,
                sensitiveReadPolicy: .askEveryTime,
                onRequestBuilt: { _ in },
                onEvent: { _ in },
                onRuntimeError: { _ in }
            )
        }
        try await modelRequestCapture.waitForCount(1)
        try await commandGate.waitUntilStarted()

        let maybeInterruptHandle = try await runtime.interruptActiveTurn()
        let interruptHandle = try XCTUnwrap(maybeInterruptHandle)
        XCTAssertEqual(interruptHandle.target.status, .running)
        XCTAssertGreaterThanOrEqual(
            interruptHandle.requestedAt
                .timeIntervalSince(interruptHandle.target.startedAt),
            0
        )

        let followupTurn = Task {
            await runtime.runTurn(
                userMessage: "第二轮：继续",
                configuration: configuration,
                codexOAuthConfiguration: .empty,
                agentAccessMode: .standard,
                sensitiveReadPolicy: .askEveryTime,
                onRequestBuilt: { _ in },
                onEvent: { _ in },
                onRuntimeError: { _ in }
            )
        }
        try await modelRequestCapture.waitForCount(2)

        let followupInput = try await modelRequestCapture.input(at: 1)
        XCTAssertEqual(Self.agentInputSignatures(from: followupInput), [
            "message:developer",
            "message:user:第一轮：运行慢命令",
            "message:assistant:我会运行一个慢命令。",
            "function_call:exec_command:call_photosorter_blocked",
            "function_call_output:call_photosorter_blocked:aborted",
            "message:user:\(MSPAgentInterruptedTurnMarker.text)",
            "message:user:第二轮：继续"
        ])

        let terminal = try await interruptHandle.terminalResponse()
        XCTAssertEqual(terminal.reason, .interrupted)
        await commandGate.release()
        await firstTurn.value
        await followupTurn.value
    }

    @MainActor
    func testConversationRebuildMigratesModelTranscriptHistory() async throws {
        let modelRequestCapture = AgentModelRequestCapture()
        let modelClient = CapturingAgentModelClient(requestCapture: modelRequestCapture)
        let factoryCounter = AgentRuntimeFactoryCounter()
        let runtime = MSPPlaygroundAgentRuntime(
            execCommandBridge: MSPExecCommandBridge { _ in MSPCommandResult() },
            photoLibraryMount: PhotoLibraryMount(),
            diagnosticsLog: .shared,
            runtimeFactory: { _, execCommandBridge in
                factoryCounter.increment()
                return MSPAgentRuntime(
                    modelClientFactory: { _ in modelClient },
                    execCommandBridge: execCommandBridge
                )
            }
        )

        await runtime.runTurn(
            userMessage: "第一轮",
            configuration: Self.agentConfiguration(modelID: "test-model-a"),
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .askEveryTime,
            onRequestBuilt: { _ in },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )
        await runtime.runTurn(
            userMessage: "继续",
            configuration: Self.agentConfiguration(modelID: "test-model-b"),
            codexOAuthConfiguration: .empty,
            agentAccessMode: .standard,
            sensitiveReadPolicy: .askEveryTime,
            onRequestBuilt: { _ in },
            onEvent: { _ in },
            onRuntimeError: { _ in }
        )

        XCTAssertEqual(factoryCounter.value, 2)
        let secondInputText = try await modelRequestCapture.inputJSONText(at: 1)
        XCTAssertTrue(secondInputText.contains("msg_history_0"))
        XCTAssertTrue(secondInputText.contains("第一轮完成"))
    }

    func testFullAccessNotesPreferCachedSearchBeforeLargeOCRReads() {
        let notes = PhotoSorterAgentAccessMode.full.environmentNotes.joined(separator: "\n")

        XCTAssertTrue(notes.contains("For large cache-backed filtering, prefer `media search --ocr` or `media search --vlm`"))
        XCTAssertTrue(notes.contains("cap uncached input paths to 20 per command-tool call"))
        XCTAssertFalse(notes.contains("Use the application OCR batching policy before large OCR reads"))
    }

    private static func makeWorkspaceRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPPlaygroundShellRuntimePreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func runWithTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimeoutError()
            }
            guard let value = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return value
        }
    }

    @MainActor
    private static func makeRuntime(rootURL: URL) throws -> MSPPlaygroundShellRuntime {
        try MSPPlaygroundShellRuntime(
            workspaceURL: rootURL,
            photoLibraryMount: PhotoLibraryMount(),
            agentAccessModeProvider: PhotoSorterAgentAccessModeState(),
            arguments: ["--msp-cpython-library-path="],
            environment: [:]
        )
    }

    private static func agentConfiguration(modelID: String) -> MSPModelConfiguration {
        MSPModelConfiguration(
            providerName: "Test",
            baseURL: URL(string: "https://example.test/v1"),
            apiKey: "test-key",
            modelID: modelID,
            reasoningEffort: "medium",
            verbosity: "low"
        )
    }

    private static func agentInputSignatures(
        from input: [MSPAgentJSONValue]
    ) -> [String] {
        input.compactMap { item in
            guard let object = item.objectValue else {
                return nil
            }
            if let type = object["type"]?.stringValue,
               type == "function_call" {
                return [
                    "function_call",
                    object["name"]?.stringValue ?? "",
                    object["call_id"]?.stringValue ?? ""
                ].joined(separator: ":")
            }
            if let type = object["type"]?.stringValue,
               type == "function_call_output" {
                return [
                    "function_call_output",
                    object["call_id"]?.stringValue ?? "",
                    object["output"]?.stringValue ?? ""
                ].joined(separator: ":")
            }
            guard let role = object["role"]?.stringValue else {
                return nil
            }
            if role == "developer" {
                return "message:developer"
            }
            let text = object["content"]?.arrayValue?.compactMap {
                $0.objectValue?["text"]?.stringValue
            }.joined(separator: "\n") ?? ""
            return ["message", role, text].joined(separator: ":")
        }
    }
}

private struct TimeoutError: Error {}

private actor ShellOutputEventCapture {
    private var capturedEvents: [String] = []

    func append(_ text: String) {
        capturedEvents.append(text)
    }

    func events() -> [String] {
        capturedEvents
    }
}

private actor AgentModelRequestCapture {
    private var inputs: [[MSPAgentJSONValue]] = []

    func append(_ request: MSPAgentRequestEnvelope) {
        inputs.append(request.input)
    }

    func inputJSONText(at index: Int) throws -> String {
        let input = inputs[index]
        let data = try JSONSerialization.data(
            withJSONObject: input.map(\.jsonObject),
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    func input(at index: Int) throws -> [MSPAgentJSONValue] {
        guard inputs.indices.contains(index) else {
            return try XCTUnwrap(nil as [MSPAgentJSONValue]?)
        }
        return inputs[index]
    }

    func waitForCount(_ targetCount: Int) async throws {
        for _ in 0..<200 {
            if inputs.count >= targetCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(targetCount) model requests; saw \(inputs.count)")
    }
}

private actor AgentRuntimeTranscriptSnapshotCapture {
    private var capturedSnapshots: [[MSPAgentJSONValue]] = []

    func append(_ items: [MSPAgentJSONValue]) {
        capturedSnapshots.append(items)
    }

    func snapshots() -> [[MSPAgentJSONValue]] {
        capturedSnapshots
    }
}

private actor CapturingAgentModelClient: MSPAgentModelTurnClient {
    private let requestCapture: AgentModelRequestCapture
    private var turnIndex = 0

    init(requestCapture: AgentModelRequestCapture) {
        self.requestCapture = requestCapture
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = turnIndex
        turnIndex += 1
        await requestCapture.append(request)
        let text = index == 0 ? "第一轮完成" : "继续完成"
        let messageID = index == 0 ? "msg_history_0" : "msg_history_\(index)"
        return MSPAgentModelTurnOutput(
            finalAnswer: text,
            responseID: "resp_\(index)",
            nativeOutputItems: [
                .object([
                    "type": .string("message"),
                    "id": .string(messageID),
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string(text)
                        ])
                    ])
                ])
            ]
        )
    }
}

private actor InterruptibleAgentModelClient: MSPAgentModelTurnClient {
    private let requestCapture: AgentModelRequestCapture
    private var turnIndex = 0

    init(requestCapture: AgentModelRequestCapture) {
        self.requestCapture = requestCapture
    }

    func nextTurn(
        request: MSPAgentRequestEnvelope,
        onDelta: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        let index = turnIndex
        turnIndex += 1
        await requestCapture.append(request)
        if index == 0 {
            return MSPAgentModelTurnOutput(
                assistantMessage: "我会运行一个慢命令。",
                toolCalls: [
                    MSPAgentToolCall(
                        id: "call_photosorter_blocked",
                        name: .execCommand,
                        arguments: ["cmd": .string("sleep 3000")]
                    )
                ],
                nativeOutputItems: [
                    .object([
                        "type": .string("message"),
                        "id": .string("msg_photosorter_blocked"),
                        "role": .string("assistant"),
                        "phase": .string("assistant_message"),
                        "content": .array([
                            .object([
                                "type": .string("output_text"),
                                "text": .string("我会运行一个慢命令。")
                            ])
                        ])
                    ]),
                    .object([
                        "type": .string("function_call"),
                        "id": .string("fc_photosorter_blocked"),
                        "call_id": .string("call_photosorter_blocked"),
                        "name": .string(MSPAgentToolName.execCommand.rawValue),
                        "arguments": .string(#"{"cmd":"sleep 3000"}"#)
                    ])
                ]
            )
        }
        return MSPAgentModelTurnOutput(
            finalAnswer: "继续完成",
            responseID: "resp_followup_after_interrupt",
            nativeOutputItems: [
                .object([
                    "type": .string("message"),
                    "id": .string("msg_followup_after_interrupt"),
                    "role": .string("assistant"),
                    "phase": .string("final_answer"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string("继续完成")
                        ])
                    ])
                ])
            ]
        )
    }
}

private actor BlockingPhotoSorterCommandGate {
    private var isStarted = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func runUntilReleased() async {
        isStarted = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if isStarted {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for blocking PhotoSorter command")
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class AgentRuntimeFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class AgentConversationConfigurationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedConfiguration: MSPAgentConversationConfiguration?

    var configuration: MSPAgentConversationConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return capturedConfiguration
    }

    func record(_ configuration: MSPAgentConversationConfiguration) {
        lock.lock()
        capturedConfiguration = configuration
        lock.unlock()
    }
}

@MainActor
private final class AgentRuntimeCallbackCapture: @unchecked Sendable {
    private(set) var runtimeErrorText = ""
    private(set) var runtimeErrorWasOnMainThread = false

    func recordRuntimeError(_ text: String, wasOnMainThread: Bool) {
        runtimeErrorText = text
        runtimeErrorWasOnMainThread = wasOnMainThread
    }
}

@MainActor
private final class AgentRuntimeRequestBodyCapture: @unchecked Sendable {
    private(set) var requestBody: MSPAgentRequestBody?

    func record(_ body: MSPAgentRequestBody) {
        requestBody = body
    }
}

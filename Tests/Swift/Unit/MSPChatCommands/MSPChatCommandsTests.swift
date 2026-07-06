import Foundation
import XCTest
import MSPChat
import MSPChatCommands
import MSPCore

final class MSPChatCommandsTests: XCTestCase {
    func testCommandPackRegistersChatRead() async throws {
        let registry = try MSPCommandRegistry()
        try MSPChatCommandPack().registerCommands(into: registry)

        XCTAssertNotNil(registry.command(named: "chat"))
        let result = await runChat(["help", "read"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("chat read <path>"))
    }

    func testDefaultReadOutputsFullMarkdown() async throws {
        let result = await runChat(["read", sample("good/pure-chat.chat").path])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("# 对话归档\n"))
        XCTAssertTrue(result.stdout.contains("标题：未命名对话"))
        XCTAssertTrue(result.stdout.contains("路径：\(sample("good/pure-chat.chat").path)"))
        XCTAssertTrue(result.stdout.contains("## 回合 1"))
        XCTAssertTrue(result.stdout.contains("### 用户\n\nExplain what this conversation is for."))
        XCTAssertTrue(result.stdout.contains("### AI\n\nThis package is a minimal portable .chat conversation."))
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
    }

    func testRecentScopeDefaultsToFiveTurnsAndProvidesCursor() async throws {
        let packageURL = try makeMultiTurnPackage(turnCount: 7)
        let result = await runChat(["read", packageURL.path, "--scope", "recent"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("继续读取：--cursor recent-before:turn_3"))
        XCTAssertFalse(result.stdout.contains("user turn 1"))
        XCTAssertFalse(result.stdout.contains("user turn 2"))
        XCTAssertTrue(result.stdout.contains("user turn 3"))
        XCTAssertTrue(result.stdout.contains("assistant turn 7"))
    }

    func testCursorContinuesFullAndRecentReads() async throws {
        let packageURL = try makeMultiTurnPackage(turnCount: 7)
        let firstFull = await runChat(["read", packageURL.path, "--scope", "full", "--turn-limit", "3"])
        let continuedFull = await runChat(["read", packageURL.path, "--cursor", "full-after:turn_3", "--turn-limit", "2"])
        let continuedRecent = await runChat(["read", packageURL.path, "--cursor", "recent-before:turn_3"])

        XCTAssertEqual(firstFull.exitCode, 0, firstFull.stderr)
        XCTAssertTrue(firstFull.stdout.contains("继续读取：--cursor full-after:turn_3"))
        XCTAssertTrue(firstFull.stdout.contains("user turn 1"))
        XCTAssertTrue(firstFull.stdout.contains("user turn 3"))
        XCTAssertFalse(firstFull.stdout.contains("user turn 4"))

        XCTAssertEqual(continuedFull.exitCode, 0, continuedFull.stderr)
        XCTAssertFalse(continuedFull.stdout.contains("user turn 3"))
        XCTAssertTrue(continuedFull.stdout.contains("user turn 4"))
        XCTAssertTrue(continuedFull.stdout.contains("user turn 5"))

        XCTAssertEqual(continuedRecent.exitCode, 0, continuedRecent.stderr)
        XCTAssertTrue(continuedRecent.stdout.contains("user turn 1"))
        XCTAssertTrue(continuedRecent.stdout.contains("user turn 2"))
        XCTAssertFalse(continuedRecent.stdout.contains("user turn 3"))
    }

    func testRecentCursorUsesStableTurnAnchor() async throws {
        let packageURL = try makeMultiTurnPackage(turnCount: 7)
        let result = await runChat(["read", packageURL.path, "--cursor", "recent-before:turn_7", "--no-outputs"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("继续读取：--cursor recent-before:turn_2"))
        XCTAssertFalse(result.stdout.contains("user turn 1"))
        XCTAssertTrue(result.stdout.contains("user turn 2"))
        XCTAssertTrue(result.stdout.contains("assistant turn 6"))
        XCTAssertFalse(result.stdout.contains("user turn 7"))
    }

    func testLegacyIndexCursorsStillReadForCompatibility() async throws {
        let packageURL = try makeMultiTurnPackage(turnCount: 7)
        let continuedFull = await runChat(["read", packageURL.path, "--cursor", "full:3", "--turn-limit", "2"])
        let continuedRecent = await runChat(["read", packageURL.path, "--cursor", "recent-before:2"])

        XCTAssertEqual(continuedFull.exitCode, 0, continuedFull.stderr)
        XCTAssertTrue(continuedFull.stdout.contains("user turn 4"))
        XCTAssertTrue(continuedFull.stdout.contains("user turn 5"))

        XCTAssertEqual(continuedRecent.exitCode, 0, continuedRecent.stderr)
        XCTAssertTrue(continuedRecent.stdout.contains("user turn 1"))
        XCTAssertTrue(continuedRecent.stdout.contains("user turn 2"))
        XCTAssertFalse(continuedRecent.stdout.contains("user turn 3"))
    }

    func testNoOutputsSuppressesToolAndCommandOutputText() async throws {
        let result = await runChat(["read", uiFixture().path, "--no-outputs"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("### 工具结果"))
        XCTAssertTrue(result.stdout.contains("（无输出。）"))
        XCTAssertFalse(result.stdout.contains("format=msp.chat version=1"))
        XCTAssertFalse(result.stdout.contains("artifact status=external_only"))
        XCTAssertFalse(result.stdout.contains("```text\nok\n\n```"))
    }

    func testIncludeOutputsAndMaxOutputCharsPerItemTruncates() async throws {
        let result = await runChat([
            "read",
            sample("good/long-output-truncation.chat").path,
            "--include-outputs",
            "--max-output-chars-per-item",
            "10"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("（已截断，原始长度 35 字符。）"))
        XCTAssertTrue(result.stdout.contains("```text\nline 1\nlin\n```"))
        XCTAssertFalse(result.stdout.contains("line 4"))
    }

    func testCamelCaseReadAliasesAreAccepted() async throws {
        let result = await runChat([
            "read",
            sample("good/long-output-truncation.chat").path,
            "--scope=full",
            "--turnLimit=1",
            "--includeOutputs=false",
            "--maxOutputCharsPerItem=3"
        ])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("generate-long-output"))
        XCTAssertFalse(result.stdout.contains("line 1"))
    }

    func testInvalidOptionsReturnUsageFailures() async throws {
        let packagePath = sample("good/pure-chat.chat").path
        let cases: [([String], String)] = [
            (["read", packagePath, "--scope", "middle"], "--scope must be full or recent"),
            (["read", packagePath, "--turn-limit", "0"], "--turn-limit must be a positive integer"),
            (["read", packagePath, "--max-output-chars-per-item", "-1"], "--max-output-chars-per-item must be a non-negative integer"),
            (["read", packagePath, "--cursor", "bad"], "bad: invalid conversation cursor"),
            (["read", packagePath, "--unknown"], "unsupported option --unknown")
        ]

        for (arguments, expected) in cases {
            let result = await runChat(arguments)
            XCTAssertEqual(result.exitCode, 2, "Expected usage failure for \(arguments)")
            XCTAssertTrue(result.stderr.contains(expected), "stderr should contain \(expected), got:\n\(result.stderr)")
        }
    }

    func testTimelineEventsRenderInCanonicalSeqOrder() async throws {
        let result = await runChat(["read", uiFixture().path])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        assertOrder(
            in: result.stdout,
            [
                "### 用户\n\nInspect this package",
                "### AI（中间回复）\n\nI will show",
                "工具：metadata.read",
                "format=msp.chat version=1",
                "```sh\nprintf ok && printf warn >&2\n```",
                "流：stdout",
                "stdout arrived before stderr",
                "工具：attachment.inspect",
                "artifact status=external_only",
                "流：stderr",
                "结果：成功，退出码 0",
                "### 错误",
                "### 附件",
                "### 事件",
                "### AI\n\nThe timeline preserved"
            ]
        )
    }

    func testJSONIsOptInAndDoesNotChangeMarkdownDefault() async throws {
        let packagePath = sample("good/pure-chat.chat").path
        let markdown = await runChat(["read", packagePath])
        let json = await runChat(["read", packagePath, "--json"])

        XCTAssertEqual(markdown.exitCode, 0, markdown.stderr)
        XCTAssertTrue(markdown.stdout.hasPrefix("# 对话归档"))

        XCTAssertEqual(json.exitCode, 0, json.stderr)
        XCTAssertTrue(json.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
        XCTAssertTrue(json.stdout.contains("\"schemaVersion\""))
        XCTAssertTrue(json.stdout.contains("\"conversation\""))
        XCTAssertFalse(json.stdout.contains("\"thread\""))
        XCTAssertTrue(json.stdout.contains("\"page\""))
        XCTAssertTrue(json.stdout.contains("\"turns\""))
        XCTAssertTrue(json.stdout.contains("\"items\""))
        XCTAssertTrue(json.stdout.contains("\"type\" : \"userMessage\""))
        XCTAssertTrue(json.stdout.contains("\"type\" : \"agentMessage\""))
        XCTAssertFalse(json.stdout.hasPrefix("# 对话归档"))
    }

    func testJSONReadProjectionIncludesPageAndStableCursor() async throws {
        let packageURL = try makeMultiTurnPackage(turnCount: 7)
        let json = await runChat(["read", packageURL.path, "--scope", "recent", "--json"])

        XCTAssertEqual(json.exitCode, 0, json.stderr)
        XCTAssertTrue(json.stdout.contains("\"order\" : \"oldest_first\""))
        XCTAssertTrue(json.stdout.contains("\"scope\" : \"recent\""))
        XCTAssertTrue(json.stdout.contains("\"limit\" : 5"))
        XCTAssertTrue(json.stdout.contains("\"hasMore\" : true"))
        XCTAssertTrue(json.stdout.contains("\"nextCursor\" : \"recent-before:turn_3\""))
        XCTAssertTrue(json.stdout.contains("\"itemsView\" : \"full\""))
        XCTAssertTrue(json.stdout.contains("\"includeOutputs\" : true"))
        XCTAssertTrue(json.stdout.contains("\"id\" : \"turn_3\""))
        XCTAssertTrue(json.stdout.contains("\"startedAt\""))
        XCTAssertTrue(json.stdout.contains("\"completedAt\""))
        XCTAssertTrue(json.stdout.contains("\"durationMs\""))
    }

    private func runChat(_ arguments: [String]) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPChatCommandPack().registerCommands(into: registry)
        return await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "chat", arguments: arguments),
            context: MSPCommandContext(currentDirectory: repositoryRoot().path)
        )
    }

    private func sample(_ relativePath: String) -> URL {
        repositoryRoot()
            .appendingPathComponent("Spec/Chat/Samples")
            .appendingPathComponent(relativePath)
    }

    private func uiFixture() -> URL {
        repositoryRoot()
            .appendingPathComponent("Spec/Chat/Demos/LightweightReader/fixtures/ui-conformance.chat")
    }

    private func makeMultiTurnPackage(turnCount: Int) throws -> URL {
        let packageURL = try makeTemporaryPackageURL(named: "multi-turn.chat")
        var events: [MSPChatTimelineEvent] = []
        for turn in 1...turnCount {
            events.append(MSPChatTimelineEvent.message(
                id: "evt_multi_\(turn)_user",
                seq: events.count + 1,
                createdAt: "2026-07-03T00:00:\(String(format: "%02d", events.count))Z",
                role: "user",
                content: "user turn \(turn)",
                turnID: "turn_\(turn)"
            ))
            events.append(MSPChatTimelineEvent.message(
                id: "evt_multi_\(turn)_assistant",
                seq: events.count + 1,
                createdAt: "2026-07-03T00:00:\(String(format: "%02d", events.count))Z",
                role: "assistant",
                content: "assistant turn \(turn)",
                phase: "final",
                turnID: "turn_\(turn)"
            ))
        }
        try MSPChatCoreWriter().createMinimalPackage(
            at: packageURL,
            packageID: "chatpkg_test_multi_turn",
            createdAt: "2026-07-03T00:00:00Z",
            initialEvents: events
        )
        return packageURL
    }

    private func makeTemporaryPackageURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSPChatCommandsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func repositoryRoot() -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("Spec/Chat")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        XCTFail("Could not locate repository root from \(#filePath)")
        return URL(fileURLWithPath: "/")
    }

    private func assertOrder(
        in text: String,
        _ needles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = text.startIndex
        for needle in needles {
            guard let range = text.range(of: needle, range: lowerBound..<text.endIndex) else {
                XCTFail("Could not find \(needle) after previous marker.", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}

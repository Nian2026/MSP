import Foundation
@testable import MSPAgentBridge
import XCTest

final class MSPChatNamingCoordinatorTests: XCTestCase {
    func testGenerationPreparesRequestNormalizesCustomOutputAndUsesAtomicWrite() async throws {
        let store = MSPChatNamingMemoryStore()
        let events = MSPChatNamingEventLog()
        let generator = MSPChatTitleRequestRecorder(suggestion: MSPChatTitleSuggestion(
            title: "  " + String(repeating: "T", count: 40) + "\nextra  ",
            searchDescription: "  " + String(repeating: "D", count: 120) + "  "
        ))
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store,
            configuration: .codexCompatible(model: "cheap-title-model"),
            onEvent: { await events.append($0) }
        )

        let outcome = try await coordinator.generateTitleIfNeeded(
            MSPChatNamingRequest(
                chatID: "chat-1",
                text: "prefix\n## My request for Codex: 修复标题生成",
                pastedTextExcerpts: ["pasted"]
            )
        )

        guard case .updated(let metadata) = outcome else {
            return XCTFail("Expected title update")
        }
        XCTAssertEqual(metadata.title?.count, 36)
        XCTAssertEqual(metadata.searchDescription?.count, 100)
        XCTAssertEqual(metadata.record?.source, .model)

        let requests = await generator.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].prompt, "修复标题生成\n\npasted")
        XCTAssertEqual(requests[0].model, "cheap-title-model")
        XCTAssertEqual(requests[0].titleMaximumCharacters, 36)
        XCTAssertEqual(requests[0].descriptionMaximumCharacters, 100)
        let conditions = await store.conditions()
        XCTAssertEqual(conditions, [.onlyIfUntitled])

        let emitted = await events.snapshot()
        XCTAssertEqual(emitted.count, 2)
        guard case .titleGenerationStarted = emitted[0],
              case .titleUpdated = emitted[1] else {
            return XCTFail("Expected naming-only start and update events")
        }
    }

    func testConcurrentRequestsShareOneGenerationFlight() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingChatTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "One title")
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        let request = MSPChatNamingRequest(chatID: "chat", text: "request")

        let first = Task { try await coordinator.generateTitleIfNeeded(request) }
        let second = Task { try await coordinator.generateTitleIfNeeded(request) }
        await generator.waitUntilStarted()
        await generator.release()

        _ = try await first.value
        _ = try await second.value
        let requestCount = await generator.requestCount()
        let stored = await store.snapshot(for: "chat")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(stored.title, "One title")
    }

    func testCustomGeneratorUsesTheSameTitleSanitizerAsResponsesGenerator() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPChatTitleRequestRecorder(
            suggestion: MSPChatTitleSuggestion(
                title: "  \"Title: Fix SDK title.\"  ",
                searchDescription: "  searchable\n  metadata  "
            )
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )

        let outcome = try await coordinator.generateTitleIfNeeded(
            MSPChatNamingRequest(chatID: "chat", text: "request")
        )

        XCTAssertEqual(outcome.metadata.title, "Title: Fix SDK title")
        XCTAssertEqual(outcome.metadata.searchDescription, "searchable metadata")
    }

    func testManualTitleWrittenDuringGenerationWinsSecondCheck() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingChatTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "Late model title")
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        let generation = Task {
            try await coordinator.generateTitleIfNeeded(
                MSPChatNamingRequest(chatID: "chat", text: "request")
            )
        }
        await generator.waitUntilStarted()

        _ = try await store.writeTitle(
            MSPChatTitleRecord(
                chatID: "chat",
                title: "Manual title",
                source: .manual,
                updatedAt: Date()
            ),
            condition: .always
        )
        await generator.release()

        let outcome = try await generation.value
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("Expected delayed model title to be skipped")
        }
        XCTAssertEqual(reason, .titleChangedDuringGeneration)
        let final = await store.snapshot(for: "chat")
        XCTAssertEqual(final.title, "Manual title")
        XCTAssertEqual(final.record?.source, .manual)
    }

    func testInvalidManualTitleDoesNotCancelValidAutomaticGeneration() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingChatTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "Automatic title")
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        let generation = Task {
            try await coordinator.generateTitleIfNeeded(
                MSPChatNamingRequest(chatID: "chat", text: "request")
            )
        }
        await generator.waitUntilStarted()

        do {
            _ = try await coordinator.setManualTitle(
                chatID: "chat",
                title: "   "
            )
            XCTFail("Expected an empty manual title error")
        } catch let error as MSPChatNamingError {
            XCTAssertEqual(error, .emptyManualTitle)
        }

        await generator.release()
        let outcome = try await generation.value
        XCTAssertEqual(outcome.metadata.title, "Automatic title")
    }

    func testFailureAndTimeoutUseBoundedPlainTextFallback() async throws {
        for generator in [
            anyTitleGenerator(MSPThrowingChatTitleGenerator()),
            anyTitleGenerator(MSPSlowChatTitleGenerator())
        ] {
            let store = MSPChatNamingMemoryStore()
            let events = MSPChatNamingEventLog()
            let coordinator = MSPChatNamingCoordinator(
                titleGenerator: generator,
                persistence: store,
                configuration: MSPChatNamingConfiguration(
                    timeoutNanoseconds: 1_000_000
                ),
                onEvent: { await events.append($0) }
            )
            let longText = "# " + String(repeating: "fallback ", count: 20)

            let outcome = try await coordinator.generateTitleIfNeeded(
                MSPChatNamingRequest(chatID: UUID().uuidString, text: longText)
            )
            guard case .updated(let metadata) = outcome else {
                return XCTFail("Expected fallback update")
            }
            XCTAssertEqual(metadata.record?.source, .fallback)
            XCTAssertLessThanOrEqual(metadata.title?.count ?? 0, 60)
            XCTAssertTrue(metadata.title?.hasSuffix("…") == true)
            let failures = await events.snapshot().filter {
                if case .titleGenerationFailed = $0 { return true }
                return false
            }
            XCTAssertEqual(failures.count, 1)
        }
    }

    func testHistoricalPolicyAndCrossSessionForkInheritanceAreExpressible() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPChatTitleRequestRecorder(
            suggestion: MSPChatTitleSuggestion(title: "Should not run")
        )
        var policy = MSPChatNamingPolicy.codexCompatible
        policy.backfillHistoricalUntitledChats = false
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store,
            configuration: MSPChatNamingConfiguration(policy: policy)
        )

        let backfill = try await coordinator.backfillTitleIfNeeded(
            chatID: "history",
            preview: MSPChatNamingInput(text: "old preview")
        )
        guard case .skipped(let reason, _) = backfill else {
            return XCTFail("Expected backfill policy skip")
        }
        XCTAssertEqual(reason, .policyDisabled)
        let requests = await generator.snapshot()
        XCTAssertEqual(requests.count, 0)

        let parent = MSPChatTitleRecord(
            chatID: "parent",
            title: "Inherited title",
            searchDescription: "Inherited search description",
            source: .manual,
            updatedAt: Date()
        )
        let inherited = try await coordinator.inheritTitle(
            from: parent,
            to: "child"
        )
        guard case .updated(let child) = inherited else {
            return XCTFail("Expected inherited child title")
        }
        XCTAssertEqual(child.title, "Inherited title")
        XCTAssertEqual(child.searchDescription, "Inherited search description")
        XCTAssertEqual(child.record?.source, .inherited)
    }

    func testUntitledParentDoesNotCancelChildAutomaticGeneration() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingChatTitleGenerator(
            suggestion: MSPChatTitleSuggestion(title: "Child automatic title")
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        let generation = Task {
            try await coordinator.generateTitleIfNeeded(
                MSPChatNamingRequest(chatID: "child", text: "request")
            )
        }
        await generator.waitUntilStarted()

        let inheritance = try await coordinator.inheritTitle(
            from: .untitled(),
            to: "child"
        )
        guard case .skipped(let reason, _) = inheritance else {
            return XCTFail("Expected untitled-parent skip")
        }
        XCTAssertEqual(reason, .parentUntitled)

        await generator.release()
        let generated = try await generation.value
        XCTAssertEqual(generated.metadata.title, "Child automatic title")
    }

    func testLateDescriptionCannotOverwriteNewManualRename() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingSearchDescriptionGenerator(
            description: "Late description"
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        _ = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "First title"
        )

        let refresh = Task {
            try await coordinator.refreshSearchDescription(
                chatID: "chat",
                input: MSPChatNamingInput(text: "request")
            )
        }
        await generator.waitUntilDescriptionStarted()
        _ = try await store.writeTitle(
            MSPChatTitleRecord(
                chatID: "chat",
                title: "New manual title",
                searchDescription: "New description",
                source: .manual,
                updatedAt: Date()
            ),
            condition: .always
        )
        await generator.releaseDescription()

        let outcome = try await refresh.value
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("Expected late description skip")
        }
        XCTAssertEqual(reason, .titleChangedDuringGeneration)
        let final = await store.snapshot(for: "chat")
        XCTAssertEqual(final.title, "New manual title")
        XCTAssertEqual(final.searchDescription, "New description")
    }

    func testLateDescriptionCannotOverwriteSameTitleAtNewerRevision() async throws {
        let store = MSPChatNamingMemoryStore()
        let generator = MSPBlockingSearchDescriptionGenerator(
            description: "Late description"
        )
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: generator,
            persistence: store
        )
        _ = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "Stable title",
            searchDescription: .replace("Original description")
        )

        let refresh = Task {
            try await coordinator.refreshSearchDescription(
                chatID: "chat",
                input: MSPChatNamingInput(text: "request")
            )
        }
        await generator.waitUntilDescriptionStarted()
        _ = try await store.writeTitle(
            MSPChatTitleRecord(
                chatID: "chat",
                title: "Stable title",
                searchDescription: "Newer description",
                source: .manual,
                updatedAt: Date()
            ),
            condition: .always
        )
        await generator.releaseDescription()

        let outcome = try await refresh.value
        guard case .skipped(let reason, _) = outcome else {
            return XCTFail("Expected late description skip")
        }
        XCTAssertEqual(reason, .writeConditionNotMet)
        let final = await store.snapshot(for: "chat")
        XCTAssertEqual(final.title, "Stable title")
        XCTAssertEqual(final.searchDescription, "Newer description")
    }

    func testManualTitleCanPreserveReplaceAndClearSearchDescription() async throws {
        let store = MSPChatNamingMemoryStore()
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: MSPImmediateCombinedNamingGenerator(),
            persistence: store
        )
        _ = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "First title",
            searchDescription: .replace("Keep me")
        )
        let preserved = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "Second title"
        )
        XCTAssertEqual(preserved.searchDescription, "Keep me")

        let cleared = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "Third title",
            searchDescription: .replace(nil)
        )
        XCTAssertNil(cleared.searchDescription)
    }

    func testManualTitlePreserveRetriesAgainstConcurrentDescriptionWrite() async throws {
        let store = MSPChatNamingPreserveRaceStore()
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: MSPImmediateCombinedNamingGenerator(),
            persistence: store
        )

        let renamed = try await coordinator.setManualTitle(
            chatID: "chat",
            title: "Manual title"
        )

        XCTAssertEqual(renamed.title, "Manual title")
        XCTAssertEqual(
            renamed.searchDescription,
            "Newest concurrent description"
        )
        let conditions = await store.conditions()
        XCTAssertEqual(conditions, [
            .ifRevision("1"),
            .ifRevision("2")
        ])
    }

    func testOneCallManualRenameAutomaticallyReusesCombinedGenerator() async throws {
        let store = MSPChatNamingMemoryStore()
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: MSPImmediateCombinedNamingGenerator(),
            persistence: store
        )

        let metadata = try await coordinator
            .setManualTitleAndRefreshSearchDescription(
                chatID: "chat",
                title: "Developer title",
                input: MSPChatNamingInput(text: "initial request")
            )

        XCTAssertEqual(metadata.title, "Developer title")
        XCTAssertEqual(
            metadata.searchDescription,
            "Refreshed searchable description"
        )
        XCTAssertEqual(metadata.record?.source, .manual)
    }

    func testPersistenceFailureEmitsOneObservableFailureEvent() async {
        let store = MSPChatNamingMemoryStore()
        await store.failReads(with: MSPChatNamingTestError.failed)
        let events = MSPChatNamingEventLog()
        let coordinator = MSPChatNamingCoordinator(
            titleGenerator: MSPImmediateCombinedNamingGenerator(),
            persistence: store,
            onEvent: { await events.append($0) }
        )

        do {
            _ = try await coordinator.generateTitleIfNeeded(
                MSPChatNamingRequest(chatID: "chat", text: "request")
            )
            XCTFail("Expected persistence error")
        } catch {
            // The caller still receives the original persistence failure.
        }

        let failures = await events.snapshot().filter {
            if case .titleGenerationFailed = $0 { return true }
            return false
        }
        XCTAssertEqual(failures.count, 1)
    }
}

private func anyTitleGenerator<G: MSPChatTitleGenerating>(
    _ generator: G
) -> any MSPChatTitleGenerating {
    generator
}

import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest

final class MSPModelCatalogTests: XCTestCase {
    func testReasoningEffortAcceptsFutureValuesAndRejectsEmptyJSON() throws {
        let future = try XCTUnwrap(MSPReasoningEffort(rawValue: "future"))
        XCTAssertEqual(future.rawValue, "future")

        XCTAssertThrowsError(
            try JSONDecoder().decode(MSPReasoningEffort.self, from: Data("\"\"".utf8))
        )
    }

    func testResolvedProfileCalculatesCodexWindowAndAutoCompactLimits() throws {
        let capabilities = MSPModelCapabilities(
            slug: "gpt-5.6-sol",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .medium, .high, .xhigh, .max, .ultra].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            effectiveContextWindowPercent: 95,
            compHash: "3000"
        )

        let profile = MSPResolvedModelProfile(
            modelID: "gpt-5.6-sol",
            matchedModelID: capabilities.slug,
            capabilities: capabilities,
            metadataSource: .bundled
        )

        XCTAssertEqual(profile.contextWindowTokens, 372_000)
        XCTAssertEqual(profile.effectiveContextWindowTokens, 353_400)
        XCTAssertEqual(profile.autoCompactTokenLimit, 334_800)
        XCTAssertEqual(profile.compHash, "3000")
        XCTAssertEqual(profile.effectiveReasoningEffort(for: MSPReasoningEffort.modelDefault), .low)
    }

    func testBundledCatalogIncludesCurrentGPT56Family() throws {
        let snapshot = MSPModelCatalogManager.bundledSnapshot

        XCTAssertEqual(
            snapshot.visibleModels.map(\.slug),
            [
                "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2"
            ]
        )
        XCTAssertEqual(snapshot.models.first { $0.slug == "gpt-5.2" }?.priority, 29)

        let luna = snapshot.resolvedProfile(for: "gpt-5.6-luna")
        XCTAssertEqual(luna.displayName, "GPT-5.6-Luna")
        XCTAssertEqual(luna.defaultReasoningEffort, .medium)
        XCTAssertEqual(luna.supportedReasoningEfforts.map(\.effort), [
            .low, .medium, .high, .xhigh, .max
        ])
        XCTAssertEqual(luna.contextWindowTokens, 372_000)
        XCTAssertEqual(luna.effectiveContextWindowTokens, 353_400)
        XCTAssertEqual(luna.autoCompactTokenLimit, 334_800)
        XCTAssertEqual(luna.compHash, "3000")
    }

    func testEffectiveWindowDrivesFullWindowProtection() async throws {
        let harness = try RequestCaptureHarness(streams: [])
        let conversation = harness.makeConversation(model: "gpt-5.6-sol")
        _ = try await conversation.resolveModelProfileForCurrentTurn()

        let status = await conversation.projectedPreTurnTokenStatus(
            currentUsage: nil,
            projectedInputTokenCount: 353_400
        )
        XCTAssertEqual(status?.contextWindowTokens, 353_400)

        let belowEffectiveWindow = MSPAgentJSONValue.string(
            String(repeating: "x", count: 353_399 * 4)
        )
        try await conversation.assertProjectedInputFitsContextWindow([
            belowEffectiveWindow
        ])

        let atEffectiveWindow = MSPAgentJSONValue.string(
            String(repeating: "x", count: 353_400 * 4)
        )
        do {
            try await conversation.assertProjectedInputFitsContextWindow([
                atEffectiveWindow
            ])
            XCTFail("expected effective context-window protection")
        } catch let MSPAgentModelClientError.contextWindowExceeded(message) {
            XCTAssertTrue(message.contains("353400-token effective context window"))
        }
    }

    func testContextWindowPrefersContextOverMaxAndClampsOverrides() {
        let capabilities = MSPModelCapabilities(
            slug: "gpt-5.4",
            contextWindow: 272_000,
            maxContextWindow: 1_000_000,
            effectiveContextWindowPercent: 95
        )

        let normal = MSPResolvedModelProfile(
            modelID: capabilities.slug,
            matchedModelID: capabilities.slug,
            capabilities: capabilities,
            metadataSource: .bundled
        )
        let expanded = MSPResolvedModelProfile(
            modelID: capabilities.slug,
            matchedModelID: capabilities.slug,
            capabilities: capabilities,
            metadataSource: .provided,
            contextWindowOverride: 500_000
        )
        let clamped = MSPResolvedModelProfile(
            modelID: capabilities.slug,
            matchedModelID: capabilities.slug,
            capabilities: capabilities,
            metadataSource: .provided,
            contextWindowOverride: 2_000_000
        )

        XCTAssertEqual(normal.contextWindowTokens, 272_000)
        XCTAssertEqual(expanded.contextWindowTokens, 500_000)
        XCTAssertEqual(expanded.effectiveContextWindowTokens, 475_000)
        XCTAssertEqual(expanded.autoCompactTokenLimit, 450_000)
        XCTAssertEqual(clamped.contextWindowTokens, 1_000_000)
        XCTAssertEqual(clamped.autoCompactTokenLimit, 900_000)
    }

    func testExplicitAutoCompactLimitCannotExceedNinetyPercent() {
        let base = MSPModelCapabilities(
            slug: "model",
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            explicitAutoCompactTokenLimit: 360_000
        )
        let clamped = MSPResolvedModelProfile(
            modelID: base.slug,
            matchedModelID: base.slug,
            capabilities: base,
            metadataSource: .provided
        )

        var lowerCapabilities = base
        lowerCapabilities.explicitAutoCompactTokenLimit = 300_000
        let lower = MSPResolvedModelProfile(
            modelID: lowerCapabilities.slug,
            matchedModelID: lowerCapabilities.slug,
            capabilities: lowerCapabilities,
            metadataSource: .provided
        )

        XCTAssertEqual(clamped.autoCompactTokenLimit, 334_800)
        XCTAssertEqual(lower.autoCompactTokenLimit, 300_000)
    }

    func testSnapshotUsesLongestPrefixAndSingleNamespaceSuffix() throws {
        let snapshot = MSPModelCatalogSnapshot(
            models: [
                MSPModelCapabilities(slug: "gpt-5", contextWindow: 100_000),
                MSPModelCapabilities(slug: "gpt-5.6", contextWindow: 200_000),
                MSPModelCapabilities(slug: "gpt-5.6-sol", contextWindow: 372_000)
            ],
            metadataSource: .provided
        )

        let dated = snapshot.resolvedProfile(for: "gpt-5.6-sol-2026-07")
        let namespaced = snapshot.resolvedProfile(for: "acme/gpt-5.6-sol")
        let multiNamespace = snapshot.resolvedProfile(for: "a/b/gpt-5.6-sol")

        XCTAssertEqual(dated.matchedModelID, "gpt-5.6-sol")
        XCTAssertEqual(dated.modelID, "gpt-5.6-sol-2026-07")
        XCTAssertEqual(dated.contextWindowTokens, 372_000)
        XCTAssertEqual(namespaced.matchedModelID, "gpt-5.6-sol")
        XCTAssertTrue(multiNamespace.usedFallbackMetadata)
        XCTAssertEqual(multiNamespace.contextWindowTokens, 272_000)
    }

    func testStandardModelsEntryDecodesAsBasicMetadata() throws {
        let data = Data(#"{"id":"gpt-5.6-sol","object":"model","created":1,"owned_by":"openai"}"#.utf8)
        let decoded = try JSONDecoder().decode(MSPModelCapabilities.self, from: data)

        XCTAssertEqual(decoded.slug, "gpt-5.6-sol")
        XCTAssertEqual(decoded.entryKind, .basic)
        XCTAssertNil(decoded.contextWindow)
        XCTAssertTrue(decoded.supportedReasoningEfforts.isEmpty)
    }

    func testVisibleModelsExcludeUnknownBasicInventoryEntries() {
        let rich = MSPModelCapabilities(slug: "responses-model", contextWindow: 200_000)
        let basic = MSPModelCapabilities(slug: "embedding-model", entryKind: .basic)
        let snapshot = MSPModelCatalogSnapshot(
            models: [basic, rich],
            metadataSource: .provided
        )

        XCTAssertEqual(snapshot.models.map(\.slug), ["embedding-model", "responses-model"])
        XCTAssertEqual(snapshot.visibleModels.map(\.slug), ["responses-model"])
    }

    func testModelsEndpointAddsClientVersionToProviderOwnedCatalogRequests() throws {
        let standardConfiguration = MSPResponsesModelsEndpoint.Configuration(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            clientVersion: "1.2.3"
        )
        let standardURL = try MSPResponsesModelsEndpoint.modelsURL(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            clientVersion: standardConfiguration.request().clientVersion
        )
        let codexURL = try MSPResponsesModelsEndpoint.modelsURL(
            baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
            clientVersion: "1.2.3"
        )

        XCTAssertTrue(standardConfiguration.request().includesClientVersionQuery)
        XCTAssertEqual(
            standardURL.absoluteString,
            "https://api.openai.com/v1/models?client_version=1.2.3"
        )
        XCTAssertEqual(
            codexURL.absoluteString,
            "https://chatgpt.com/backend-api/codex/models?client_version=1.2.3"
        )
        XCTAssertEqual(MSPModelCatalogClientVersion.current.split(separator: ".").count, 3)
    }

    func testConversationDefaultsToAutomaticCompactionAndModelReasoningDefault() {
        let automatic = MSPAgentConversationConfiguration(model: "gpt-5.6-sol")
        let disabled = MSPAgentConversationConfiguration(
            model: "gpt-5.6-sol",
            compactionPolicy: .disabled
        )

        XCTAssertTrue(automatic.compactionPolicy.enabled)
        XCTAssertEqual(automatic.reasoningEffort, MSPReasoningEffort.modelDefaultValue)
        XCTAssertFalse(disabled.compactionPolicy.enabled)
    }

    func testDefaultRequestBuildDoesNotSendReasoningForUnresolvedModel() {
        let body = MSPAgentRequestBuilder().build(
            context: MSPAgentRequestBuildContext(
                model: "unknown-model",
                prompt: "hello"
            )
        )

        XCTAssertNil(body.reasoning)
    }

    func testInterruptDuringCatalogResolutionStopsBeforeModelRequest() async throws {
        let catalog = CancellationSwallowingModelCatalog()
        let client = ModelCatalogCountingClient()
        let runtime = MSPAgentRuntime(
            modelClientFactory: { _ in client },
            execCommandBridge: MSPExecCommandBridge(runCommand: { _ in
                .success(stdout: "")
            }),
            modelCatalog: catalog
        )
        let conversation = runtime.makeConversation(
            configuration: MSPAgentConversationConfiguration(model: "gpt-5.6-sol")
        )

        let sendTask = Task {
            try await conversation.send("hello")
        }
        await catalog.waitUntilResolveStarted()
        let pendingHandle = try await conversation.interruptActiveTurn()
        let handle = try XCTUnwrap(pendingHandle)
        _ = try await handle.terminalResponse()
        let result = try await sendTask.value
        let requestCount = await client.requestCount()

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(requestCount, 0)
    }

    func testRequestReasoningUsesResolvedModelDefaultAndSupportsUltra() throws {
        let profile = MSPModelCatalogManager.bundledSnapshot
            .resolvedProfile(for: "gpt-5.6-sol")
        let defaultConfiguration = MSPAgentConversationConfiguration(model: "gpt-5.6-sol")
        let ultraConfiguration = MSPAgentConversationConfiguration(
            model: "gpt-5.6-sol",
            reasoningEffort: "ultra"
        )

        let defaultBody = MSPAgentRequestBuilder().build(
            context: defaultConfiguration.requestContext(
                prompt: "hello",
                modelProfile: profile
            )
        )
        let ultraBody = MSPAgentRequestBuilder().build(
            context: ultraConfiguration.requestContext(
                prompt: "hello",
                modelProfile: profile
            )
        )

        XCTAssertEqual(defaultBody.reasoning?.effort, "low")
        XCTAssertEqual(ultraBody.reasoning?.effort, "ultra")
    }

    func testAdvertisedFutureReasoningEffortPassesThrough() throws {
        let future = try XCTUnwrap(MSPReasoningEffort(rawValue: "future"))
        let capabilities = MSPModelCapabilities(
            slug: "future-model",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [
                MSPReasoningEffortPreset(effort: .low, description: "low"),
                MSPReasoningEffortPreset(effort: future, description: "future")
            ],
            contextWindow: 400_000
        )
        let profile = MSPResolvedModelProfile(
            modelID: capabilities.slug,
            matchedModelID: capabilities.slug,
            capabilities: capabilities,
            metadataSource: .remote
        )

        XCTAssertEqual(profile.effectiveReasoningEffort(for: "future"), future)
    }

    func testSparseRemoteDisplayMetadataKeepsBundledCapabilities() async throws {
        let bundled = MSPModelCapabilities(
            slug: "gpt-5.6-sol",
            displayName: "Bundled Sol",
            description: "Bundled description",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .medium, .high, .xhigh, .max, .ultra].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            priority: 1,
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "3000"
        )
        let sparse = try JSONDecoder().decode(
            MSPModelCapabilities.self,
            from: Data(
                #"{"id":"gpt-5.6-sol","name":"Remote Sol","description":"Remote description","visibility":"list","supported_in_api":false,"priority":20}"#.utf8
            )
        )
        XCTAssertEqual(sparse.entryKind, .basic)

        let fetcher = ModelCatalogTestFetcher(models: [sparse])
        let manager = MSPModelCatalogManager(
            providerID: "openai|https://api.openai.com/v1",
            cacheTTL: 300,
            bundledModels: [bundled],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://api.openai.com/v1")!
            )
        )

        let snapshot = await manager.snapshot(refreshPolicy: .online)
        let profile = snapshot.resolvedProfile(for: bundled.slug)

        XCTAssertEqual(profile.displayName, "Remote Sol")
        XCTAssertEqual(profile.description, "Remote description")
        XCTAssertEqual(profile.priority, 1)
        XCTAssertFalse(profile.supportedInAPI)
        XCTAssertEqual(profile.contextWindowTokens, 372_000)
        XCTAssertEqual(profile.autoCompactTokenLimit, 334_800)
        XCTAssertEqual(profile.supportedReasoningEfforts.map(\.effort), [
            .low, .medium, .high, .xhigh, .max, .ultra
        ])
        XCTAssertFalse(profile.usedFallbackMetadata)
    }

    func testBasicAliasesDoNotShadowRichFamilyCapabilities() {
        let rich = MSPModelCapabilities(
            slug: "gpt-5.6-sol",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .medium, .high, .xhigh, .max, .ultra].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "3000"
        )
        let snapshot = MSPModelCatalogSnapshot(
            models: [
                rich,
                MSPModelCapabilities(
                    slug: "gpt-5.6-sol-2026-07",
                    entryKind: .basic
                ),
                MSPModelCapabilities(
                    slug: "acme/gpt-5.6-sol",
                    entryKind: .basic
                )
            ],
            metadataSource: .provided
        )

        for modelID in ["gpt-5.6-sol-2026-07", "acme/gpt-5.6-sol"] {
            let profile = snapshot.resolvedProfile(for: modelID)
            XCTAssertEqual(profile.matchedModelID, rich.slug)
            XCTAssertEqual(profile.contextWindowTokens, 372_000)
            XCTAssertEqual(profile.supportedReasoningEfforts.map(\.effort), [
                .low, .medium, .high, .xhigh, .max, .ultra
            ])
            XCTAssertFalse(profile.usedFallbackMetadata)
        }
    }

    func testRichRemoteModelReplacesBundledCapabilities() async {
        let bundled = MSPModelCapabilities(
            slug: "shared-model",
            displayName: "Bundled",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high].map {
                MSPReasoningEffortPreset(effort: $0, description: $0.rawValue)
            },
            priority: 1,
            contextWindow: 372_000,
            maxContextWindow: 372_000,
            compHash: "bundled-hash"
        )
        let remote = MSPModelCapabilities(
            slug: bundled.slug,
            displayName: "Remote",
            priority: 20,
            entryKind: .rich
        )
        let manager = MSPModelCatalogManager(
            providerID: "custom|https://example.test/v1",
            bundledModels: [bundled],
            remoteFetcher: ModelCatalogTestFetcher(models: [remote]),
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://example.test/v1")!
            )
        )

        let snapshot = await manager.snapshot(refreshPolicy: .online)
        let profile = snapshot.resolvedProfile(for: bundled.slug)

        XCTAssertEqual(profile.displayName, "Remote")
        XCTAssertEqual(profile.metadataSource, .remote)
        XCTAssertNil(profile.defaultReasoningEffort)
        XCTAssertTrue(profile.supportedReasoningEfforts.isEmpty)
        XCTAssertNil(profile.contextWindowTokens)
        XCTAssertNil(profile.autoCompactTokenLimit)
        XCTAssertNil(profile.compHash)
        XCTAssertFalse(profile.usedFallbackMetadata)
    }

    func testChatGPTVisibleRemoteCatalogIsAuthoritative() async {
        let bundled = MSPModelCapabilities(slug: "bundled", contextWindow: 272_000)
        let remote = MSPModelCapabilities(slug: "remote", priority: 1, contextWindow: 372_000)
        let fetcher = ModelCatalogTestFetcher(models: [remote])
        let manager = MSPModelCatalogManager(
            providerID: "codex|https://chatgpt.com/backend-api/codex",
            accountID: "account-1",
            usesChatGPTAuthentication: true,
            bundledModels: [bundled],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!
            )
        )

        let snapshot = await manager.snapshot(refreshPolicy: .online)

        XCTAssertEqual(snapshot.models.map(\.slug), ["remote"])
        XCTAssertEqual(snapshot.defaultModelID, "remote")
    }

    func testFreshProviderScopedDiskCacheAvoidsSecondNetworkFetch() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let remote = MSPModelCapabilities(slug: "remote", priority: 1, contextWindow: 372_000)
        let firstFetcher = ModelCatalogTestFetcher(models: [remote])
        let firstManager = MSPModelCatalogManager(
            providerID: "provider|https://example.test/v1",
            clientVersion: "test-1",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: firstFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://example.test/v1")!,
                clientVersion: "test-1"
            )
        )
        _ = await firstManager.snapshot(refreshPolicy: .onlineIfUncached)
        let firstFetchCount = await firstFetcher.fetchCount()
        XCTAssertEqual(firstFetchCount, 1)

        let secondFetcher = ModelCatalogTestFetcher(models: [])
        let secondManager = MSPModelCatalogManager(
            providerID: "provider|https://example.test/v1",
            clientVersion: "test-1",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: secondFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://example.test/v1")!,
                clientVersion: "test-1"
            )
        )

        let cached = await secondManager.snapshot(refreshPolicy: .onlineIfUncached)

        XCTAssertEqual(cached.models.map(\.slug), ["remote"])
        XCTAssertEqual(cached.metadataSource, .diskCache)
        let secondFetchCount = await secondFetcher.fetchCount()
        XCTAssertEqual(secondFetchCount, 0)
    }

    func testNotModifiedRenewsMemoryOnlyRemoteCatalog() async throws {
        let blockedCacheParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-304-memory-\(UUID().uuidString)")
        try Data().write(to: blockedCacheParent)
        defer { try? FileManager.default.removeItem(at: blockedCacheParent) }
        let cacheURL = blockedCacheParent.appendingPathComponent("models.json")
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let renewedDate = Date(timeIntervalSince1970: 2_000)
        let remote = MSPModelCapabilities(slug: "memory-remote", contextWindow: 372_000)
        let fetcher = ModelCatalogScriptedFetcher(outcomes: [
            .response(MSPModelCatalogRemoteResponse(
                models: [remote],
                etag: "memory-etag",
                receivedAt: initialDate
            )),
            .response(MSPModelCatalogRemoteResponse(
                models: [],
                etag: "memory-etag",
                notModified: true,
                receivedAt: renewedDate
            ))
        ])
        let manager = MSPModelCatalogManager(
            providerID: "memory-304-provider",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://memory-304.example.test/v1")!
            )
        )

        let initial = try await manager.refreshThrowing(refreshPolicy: .online)
        let renewed = try await manager.refreshThrowing(refreshPolicy: .online)
        let requests = await fetcher.recordedRequests()

        XCTAssertEqual(initial.models.map(\.slug), ["memory-remote"])
        XCTAssertEqual(initial.fetchedAt, initialDate)
        XCTAssertEqual(renewed.models.map(\.slug), ["memory-remote"])
        XCTAssertEqual(renewed.metadataSource, .remote)
        XCTAssertEqual(renewed.etag, "memory-etag")
        XCTAssertEqual(renewed.fetchedAt, renewedDate)
        XCTAssertNil(requests.first?.ifNoneMatch)
        XCTAssertEqual(requests.last?.ifNoneMatch, "memory-etag")
    }

    func testNotModifiedRenewsStaleDiskCatalog() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-304-disk-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let staleDate = Date(timeIntervalSinceNow: -600)
        let renewedDate = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let remote = MSPModelCapabilities(slug: "disk-remote", contextWindow: 372_000)
        let initialFetcher = ModelCatalogScriptedFetcher(outcomes: [
            .response(MSPModelCatalogRemoteResponse(
                models: [remote],
                etag: "disk-etag",
                receivedAt: staleDate
            ))
        ])
        let initialManager = MSPModelCatalogManager(
            providerID: "disk-304-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [],
            remoteFetcher: initialFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://disk-304.example.test/v1")!
            )
        )
        _ = try await initialManager.refreshThrowing(refreshPolicy: .online)

        let renewingFetcher = ModelCatalogScriptedFetcher(outcomes: [
            .response(MSPModelCatalogRemoteResponse(
                models: [],
                etag: nil,
                notModified: true,
                receivedAt: renewedDate
            ))
        ])
        let renewingManager = MSPModelCatalogManager(
            providerID: "disk-304-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [],
            remoteFetcher: renewingFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://disk-304.example.test/v1")!
            )
        )

        let renewed = try await renewingManager.refreshThrowing(
            refreshPolicy: .onlineIfUncached
        )
        let renewalRequests = await renewingFetcher.recordedRequests()

        XCTAssertEqual(renewed.models.map(\.slug), ["disk-remote"])
        XCTAssertEqual(renewed.metadataSource, .remote)
        XCTAssertEqual(renewed.etag, "disk-etag")
        XCTAssertEqual(renewed.fetchedAt, renewedDate)
        XCTAssertEqual(renewalRequests.map(\.ifNoneMatch), ["disk-etag"])

        let verificationFetcher = ModelCatalogTestFetcher(models: [])
        let verificationManager = MSPModelCatalogManager(
            providerID: "disk-304-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [],
            remoteFetcher: verificationFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://disk-304.example.test/v1")!
            )
        )
        let cachedRenewal = await verificationManager.snapshot(
            refreshPolicy: .onlineIfUncached
        )
        let verificationFetchCount = await verificationFetcher.fetchCount()

        XCTAssertEqual(cachedRenewal.models.map(\.slug), ["disk-remote"])
        XCTAssertEqual(cachedRenewal.metadataSource, .diskCache)
        XCTAssertEqual(cachedRenewal.fetchedAt, renewedDate)
        XCTAssertEqual(verificationFetchCount, 0)
    }

    func testNotModifiedWithoutRemoteOrDiskCatalogThrows() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-304-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let fetcher = ModelCatalogScriptedFetcher(outcomes: [
            .response(MSPModelCatalogRemoteResponse(
                models: [],
                etag: "orphan-etag",
                notModified: true
            ))
        ])
        let manager = MSPModelCatalogManager(
            providerID: "empty-304-provider",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://empty-304.example.test/v1")!
            )
        )

        do {
            _ = try await manager.refreshThrowing(refreshPolicy: .online)
            XCTFail("Expected a 304 without a remote catalog to fail")
        } catch let error as MSPModelCatalogManagerError {
            XCTAssertEqual(error, .notModifiedWithoutCachedCatalog)
        }
        let requests = await fetcher.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].ifNoneMatch)
    }

    func testDiskCacheScopeIncludesRemoteBaseURL() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let firstFetcher = ModelCatalogTestFetcher(models: [
            MSPModelCapabilities(slug: "remote-a", contextWindow: 100_000)
        ])
        let firstManager = MSPModelCatalogManager(
            providerID: "shared-provider",
            clientVersion: "1.0.0",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: firstFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://a.example.test/v1")!,
                clientVersion: "1.0.0"
            )
        )
        _ = await firstManager.snapshot(refreshPolicy: .onlineIfUncached)

        let secondFetcher = ModelCatalogTestFetcher(models: [
            MSPModelCapabilities(slug: "remote-b", contextWindow: 200_000)
        ])
        let secondManager = MSPModelCatalogManager(
            providerID: "shared-provider",
            clientVersion: "1.0.0",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: secondFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://b.example.test/v1")!,
                clientVersion: "1.0.0"
            )
        )

        let secondSnapshot = await secondManager.snapshot(refreshPolicy: .onlineIfUncached)
        let secondFetchCount = await secondFetcher.fetchCount()

        XCTAssertEqual(secondSnapshot.models.map(\.slug), ["remote-b"])
        XCTAssertEqual(secondFetchCount, 1)
    }

    func testOnlineIfUncachedBacksOffAfterFailureButOnlineForcesRefresh() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-backoff-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let remote = MSPModelCapabilities(slug: "remote", contextWindow: 372_000)
        let fetcher = ModelCatalogScriptedFetcher(outcomes: [
            .failure,
            .response(MSPModelCatalogRemoteResponse(models: [remote]))
        ])
        let bundled = MSPModelCapabilities(slug: "bundled", contextWindow: 272_000)
        let manager = MSPModelCatalogManager(
            providerID: "backoff-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [bundled],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://backoff.example.test/v1")!
            )
        )

        let first = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let backedOff = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let countAfterBackoff = await fetcher.fetchCount()
        let forced = await manager.snapshot(refreshPolicy: .online)
        let countAfterForcedRefresh = await fetcher.fetchCount()

        XCTAssertEqual(first.models.map(\.slug), ["bundled"])
        XCTAssertEqual(backedOff.models.map(\.slug), ["bundled"])
        XCTAssertEqual(countAfterBackoff, 1)
        XCTAssertEqual(forced.models.map(\.slug), ["bundled", "remote"])
        XCTAssertEqual(countAfterForcedRefresh, 2)
    }

    func testCancellationDoesNotEnterFailureBackoff() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-cancel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let remote = MSPModelCapabilities(slug: "remote", contextWindow: 372_000)
        let fetcher = ModelCatalogScriptedFetcher(outcomes: [
            .cancellation,
            .response(MSPModelCatalogRemoteResponse(models: [remote]))
        ])
        let manager = MSPModelCatalogManager(
            providerID: "cancellation-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://cancel.example.test/v1")!
            )
        )

        _ = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let refreshed = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let fetchCount = await fetcher.fetchCount()

        XCTAssertEqual(refreshed.models.map(\.slug), ["remote"])
        XCTAssertEqual(fetchCount, 2)
    }

    func testCredentialCacheScopeUsesEffectiveCaseInsensitiveHeaders() throws {
        let firstScope = try XCTUnwrap(
            MSPModelCatalogManager.credentialCacheScopeID(
                for: "sk-ignored-first",
                additionalHTTPHeaders: [
                    " Authorization ": " Bearer override-secret ",
                    "X-API-Key": " custom-secret ",
                    "X-Tenant": " tenant-a "
                ]
            )
        )
        let equivalentScope = try XCTUnwrap(
            MSPModelCatalogManager.credentialCacheScopeID(
                for: "sk-ignored-second",
                additionalHTTPHeaders: [
                    "authorization": "Bearer override-secret",
                    "x-api-key": "custom-secret",
                    "x-tenant": "tenant-a"
                ]
            )
        )
        let changedCustomCredentialScope = try XCTUnwrap(
            MSPModelCatalogManager.credentialCacheScopeID(
                for: "sk-ignored-first",
                additionalHTTPHeaders: [
                    "Authorization": "Bearer override-secret",
                    "X-API-Key": "different-custom-secret",
                    "X-Tenant": "tenant-a"
                ]
            )
        )

        XCTAssertEqual(firstScope, equivalentScope)
        XCTAssertNotEqual(firstScope, changedCustomCredentialScope)
        XCTAssertEqual(firstScope.count, 64)
        XCTAssertFalse(firstScope.contains("sk-ignored-first"))
        XCTAssertFalse(firstScope.contains("override-secret"))
        XCTAssertFalse(firstScope.contains("custom-secret"))
    }

    func testResponsesCredentialScopePreservesChatGPTAccountAcrossTokenRotation() throws {
        let chatGPTURL = try XCTUnwrap(
            URL(string: "https://chatgpt.com/backend-api/codex/responses")
        )
        let firstConfiguration = MSPAgentModelConfiguration(
            baseURL: chatGPTURL,
            apiKey: "oauth-token-first",
            model: "gpt-test",
            additionalHTTPHeaders: ["ChatGPT-Account-ID": "account-1"]
        )
        let rotatedConfiguration = MSPAgentModelConfiguration(
            baseURL: chatGPTURL,
            apiKey: "oauth-token-rotated",
            model: "gpt-test",
            additionalHTTPHeaders: ["chatgpt-account-id": "account-1"]
        )

        XCTAssertNil(MSPModelCatalogManager.credentialCacheScopeID(for: firstConfiguration))
        XCTAssertNil(MSPModelCatalogManager.credentialCacheScopeID(for: rotatedConfiguration))

        let genericURL = try XCTUnwrap(URL(string: "https://provider.example.test/v1"))
        let firstGenericConfiguration = MSPAgentModelConfiguration(
            baseURL: genericURL,
            apiKey: "provider-key-first",
            model: "gpt-test",
            additionalHTTPHeaders: ["X-Account-ID": "account-1"]
        )
        let secondGenericConfiguration = MSPAgentModelConfiguration(
            baseURL: genericURL,
            apiKey: "provider-key-second",
            model: "gpt-test",
            additionalHTTPHeaders: ["x-account-id": "account-1"]
        )

        XCTAssertNotEqual(
            MSPModelCatalogManager.credentialCacheScopeID(for: firstGenericConfiguration),
            MSPModelCatalogManager.credentialCacheScopeID(for: secondGenericConfiguration)
        )
    }

    func testDiskCacheScopeSeparatesAnonymousAPICredentials() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-credential-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let firstCredential = "sk-test-first"
        let secondCredential = "sk-test-second"
        let firstScope = try XCTUnwrap(
            MSPModelCatalogManager.credentialCacheScopeID(for: firstCredential)
        )
        let secondScope = try XCTUnwrap(
            MSPModelCatalogManager.credentialCacheScopeID(for: secondCredential)
        )
        XCTAssertNotEqual(firstScope, secondScope)
        XCTAssertFalse(firstScope.contains(firstCredential))
        XCTAssertFalse(secondScope.contains(secondCredential))

        let firstFetcher = ModelCatalogTestFetcher(models: [
            MSPModelCapabilities(slug: "credential-a", contextWindow: 100_000)
        ])
        let firstManager = MSPModelCatalogManager(
            providerID: "shared-provider",
            credentialScopeID: firstScope,
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: firstFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://shared.example.test/v1")!
            )
        )
        _ = await firstManager.snapshot(refreshPolicy: .onlineIfUncached)

        let secondFetcher = ModelCatalogTestFetcher(models: [
            MSPModelCapabilities(slug: "credential-b", contextWindow: 200_000)
        ])
        let secondManager = MSPModelCatalogManager(
            providerID: "shared-provider",
            credentialScopeID: secondScope,
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: secondFetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://shared.example.test/v1")!
            )
        )

        let secondSnapshot = await secondManager.snapshot(refreshPolicy: .onlineIfUncached)
        let secondFetchCount = await secondFetcher.fetchCount()

        XCTAssertEqual(secondSnapshot.models.map(\.slug), ["credential-b"])
        XCTAssertEqual(secondFetchCount, 1)
    }

    func testConcurrentOnlineRefreshesShareOneRemoteRequest() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-concurrent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fetcher = ModelCatalogControlledFetcher()
        let manager = MSPModelCatalogManager(
            providerID: "concurrent-provider",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://concurrent.example.test/v1")!
            )
        )
        let response = MSPModelCatalogRemoteResponse(
            models: [MSPModelCapabilities(slug: "shared", contextWindow: 372_000)],
            etag: "shared-etag"
        )

        let first = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        await fetcher.waitUntilFetchCount(1)
        let second = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let countBeforeRelease = await fetcher.fetchCount()

        await fetcher.release(index: 1, response: response)
        await fetcher.release(index: 2, response: response)
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        XCTAssertEqual(countBeforeRelease, 1)
        XCTAssertEqual(firstSnapshot.models.map(\.slug), ["shared"])
        XCTAssertEqual(secondSnapshot, firstSnapshot)
        XCTAssertEqual(secondSnapshot.etag, "shared-etag")
    }

    func testCancellingOneConcurrentWaiterKeepsSharedRemoteRefreshAlive() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-shared-cancel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let response = MSPModelCatalogRemoteResponse(
            models: [MSPModelCapabilities(slug: "shared", contextWindow: 372_000)],
            etag: "shared-etag"
        )
        let fetcher = ModelCatalogDelayedFetcher(
            response: response,
            delayNanoseconds: 800_000_000
        )
        let manager = MSPModelCatalogManager(
            providerID: "shared-cancel-provider",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://shared-cancel.example.test/v1")!
            )
        )

        let cancelled = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        await fetcher.waitUntilFetchCount(1)
        let survivor = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancellationStartedAt = Date()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("expected one shared refresh waiter to cancel")
        } catch is CancellationError {
            // Expected: the other waiter continues to own the shared request.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 0.3)

        let survivingSnapshot = try await survivor.value
        let fetchCount = await fetcher.fetchCount()
        XCTAssertEqual(survivingSnapshot.models.map(\.slug), ["shared"])
        XCTAssertEqual(survivingSnapshot.etag, "shared-etag")
        XCTAssertEqual(fetchCount, 1)
    }

    func testCancelledRefreshReturnsPromptlyAndLateResponseCannotOverwriteNewSnapshot() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-generation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fetcher = ModelCatalogControlledFetcher()
        let manager = MSPModelCatalogManager(
            providerID: "generation-provider",
            cacheURL: cacheURL,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://generation.example.test/v1")!
            )
        )
        let oldResponse = MSPModelCatalogRemoteResponse(
            models: [MSPModelCapabilities(slug: "old", contextWindow: 100_000)],
            etag: "old-etag"
        )
        let newResponse = MSPModelCatalogRemoteResponse(
            models: [MSPModelCapabilities(slug: "new", contextWindow: 372_000)],
            etag: "new-etag"
        )

        let cancelled = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        await fetcher.waitUntilFetchCount(1)
        let failSafeRelease = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            await fetcher.release(index: 1, response: oldResponse)
        }

        let cancellationStartedAt = Date()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("expected cancelled refresh waiter to throw")
        } catch is CancellationError {
            // Expected: waiter cancellation must not wait for the remote fetch.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 0.5)

        let replacement = Task {
            try await manager.refreshThrowing(refreshPolicy: .online)
        }
        await fetcher.waitUntilFetchCount(2)
        await fetcher.release(index: 2, response: newResponse)
        let replacementSnapshot = try await replacement.value
        XCTAssertEqual(replacementSnapshot.models.map(\.slug), ["new"])
        XCTAssertEqual(replacementSnapshot.etag, "new-etag")

        await fetcher.release(index: 1, response: oldResponse)
        failSafeRelease.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        let active = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let finalFetchCount = await fetcher.fetchCount()
        XCTAssertEqual(active.models.map(\.slug), ["new"])
        XCTAssertEqual(active.etag, "new-etag")
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testFreshRemoteSnapshotIsAnInMemoryCacheWhenDiskPersistenceFails() async throws {
        let blockedCacheParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("msp-model-catalog-blocked-\(UUID().uuidString)")
        try Data().write(to: blockedCacheParent)
        defer { try? FileManager.default.removeItem(at: blockedCacheParent) }
        let cacheURL = blockedCacheParent.appendingPathComponent("models.json")

        let fetcher = ModelCatalogTestFetcher(models: [
            MSPModelCapabilities(slug: "memory", contextWindow: 372_000)
        ], etag: "memory-etag")
        let manager = MSPModelCatalogManager(
            providerID: "memory-provider",
            cacheURL: cacheURL,
            cacheTTL: 300,
            bundledModels: [],
            remoteFetcher: fetcher,
            remoteRequest: MSPModelCatalogRemoteRequest(
                baseURL: URL(string: "https://memory.example.test/v1")!
            )
        )

        let first = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let second = await manager.snapshot(refreshPolicy: .onlineIfUncached)
        let countAfterCachedRead = await fetcher.fetchCount()
        _ = await manager.snapshot(refreshPolicy: .online)
        let countAfterForcedRefresh = await fetcher.fetchCount()

        XCTAssertEqual(first.models.map(\.slug), ["memory"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.metadataSource, .remote)
        XCTAssertEqual(countAfterCachedRead, 1)
        XCTAssertEqual(countAfterForcedRefresh, 2)
    }
}

private actor ModelCatalogTestFetcher: MSPModelCatalogRemoteFetching {
    private let response: MSPModelCatalogRemoteResponse
    private var count = 0

    init(models: [MSPModelCapabilities], etag: String? = nil) {
        response = MSPModelCatalogRemoteResponse(models: models, etag: etag)
    }

    func fetchModels(
        request _: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse {
        count += 1
        return response
    }

    func fetchCount() -> Int {
        count
    }
}

private actor ModelCatalogControlledFetcher: MSPModelCatalogRemoteFetching {
    private var count = 0
    private var pendingResponses: [
        Int: CheckedContinuation<MSPModelCatalogRemoteResponse, Error>
    ] = [:]
    private var releasedResponses: [
        Int: Result<MSPModelCatalogRemoteResponse, Error>
    ] = [:]
    private var fetchCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func fetchModels(
        request _: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse {
        count += 1
        let index = count
        let readyTargets = fetchCountWaiters.keys.filter { $0 <= count }
        for target in readyTargets {
            let waiters = fetchCountWaiters.removeValue(forKey: target) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let released = releasedResponses.removeValue(forKey: index) {
                continuation.resume(with: released)
            } else {
                pendingResponses[index] = continuation
            }
        }
    }

    func waitUntilFetchCount(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            fetchCountWaiters[target, default: []].append(continuation)
        }
    }

    func release(
        index: Int,
        response: MSPModelCatalogRemoteResponse
    ) {
        if let continuation = pendingResponses.removeValue(forKey: index) {
            continuation.resume(returning: response)
        } else {
            releasedResponses[index] = .success(response)
        }
    }

    func fetchCount() -> Int {
        count
    }
}

private actor ModelCatalogDelayedFetcher: MSPModelCatalogRemoteFetching {
    private let response: MSPModelCatalogRemoteResponse
    private let delayNanoseconds: UInt64
    private var count = 0
    private var fetchCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(
        response: MSPModelCatalogRemoteResponse,
        delayNanoseconds: UInt64
    ) {
        self.response = response
        self.delayNanoseconds = delayNanoseconds
    }

    func fetchModels(
        request _: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse {
        count += 1
        let readyTargets = fetchCountWaiters.keys.filter { $0 <= count }
        for target in readyTargets {
            let waiters = fetchCountWaiters.removeValue(forKey: target) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return response
    }

    func waitUntilFetchCount(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            fetchCountWaiters[target, default: []].append(continuation)
        }
    }

    func fetchCount() -> Int {
        count
    }
}

private enum ModelCatalogScriptedFetcherError: Error {
    case unavailable
}

private actor ModelCatalogScriptedFetcher: MSPModelCatalogRemoteFetching {
    enum Outcome: Sendable {
        case response(MSPModelCatalogRemoteResponse)
        case failure
        case cancellation
    }

    private var outcomes: [Outcome]
    private var count = 0
    private var requests: [MSPModelCatalogRemoteRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func fetchModels(
        request: MSPModelCatalogRemoteRequest
    ) async throws -> MSPModelCatalogRemoteResponse {
        count += 1
        requests.append(request)
        let outcome = outcomes.isEmpty ? .failure : outcomes.removeFirst()
        switch outcome {
        case .response(let response):
            return response
        case .failure:
            throw ModelCatalogScriptedFetcherError.unavailable
        case .cancellation:
            throw CancellationError()
        }
    }

    func fetchCount() -> Int {
        count
    }

    func recordedRequests() -> [MSPModelCatalogRemoteRequest] {
        requests
    }
}

private actor CancellationSwallowingModelCatalog: MSPModelCatalogResolving {
    private let catalog = MSPModelCatalogManager.bundledSnapshot
    private var resolveStarted = false
    private var resolveStartWaiters: [CheckedContinuation<Void, Never>] = []

    func snapshot(
        refreshPolicy _: MSPModelCatalogRefreshPolicy
    ) async -> MSPModelCatalogSnapshot {
        catalog
    }

    func resolve(
        modelID: String,
        refreshPolicy _: MSPModelCatalogRefreshPolicy
    ) async -> MSPResolvedModelProfile {
        resolveStarted = true
        let waiters = resolveStartWaiters
        resolveStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            // Deliberately mirror the production catalog's fallback behavior,
            // which converts a cancelled fetch into its active snapshot.
        }
        return catalog.resolvedProfile(for: modelID)
    }

    func waitUntilResolveStarted() async {
        if resolveStarted {
            return
        }
        await withCheckedContinuation { continuation in
            resolveStartWaiters.append(continuation)
        }
    }
}

private actor ModelCatalogCountingClient: MSPAgentModelTurnClient {
    private var count = 0

    func nextTurn(
        request _: MSPAgentRequestEnvelope,
        onDelta _: @escaping @Sendable (MSPAgentModelStreamDelta) async -> Void,
        onAssistantMessage _: @escaping @Sendable (String) async -> Void,
        onToolCallPreparing _: @escaping @Sendable (MSPAgentToolName) async -> Void
    ) async throws -> MSPAgentModelTurnOutput {
        count += 1
        return MSPAgentModelTurnOutput(finalAnswer: "unexpected")
    }

    func requestCount() -> Int {
        count
    }
}

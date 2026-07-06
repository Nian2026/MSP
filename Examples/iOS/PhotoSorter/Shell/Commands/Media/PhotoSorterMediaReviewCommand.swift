import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func runView(
        arguments: [String],
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media view: image reads require full Photos access mode\n")
        }
        guard let imageProvider else {
            return .failure(stderr: "media view: image reads are unavailable\n")
        }
        let sensitiveReadPolicy = sensitiveReadPolicyProvider.currentSensitiveReadPolicy()
        if sensitiveReadPolicy == .askEveryTime, mediaViewAuthorizer == nil {
            return .failure(stderr: "media view: sensitive read approval UI is unavailable\n")
        }

        let parsed: PhotoSorterMediaPathListArguments
        do {
            parsed = try Self.parsePathListArguments(
                arguments,
                commandName: "media view",
                defaultLimit: nil,
                allowsInlinePaths: true
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media view: \(error)")
        }
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media view",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media view: \(error)\n")
        }

        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let requestedPaths = Array(paths.prefix(Self.mediaViewLimit))
        let limitSkippedPaths = Array(paths.dropFirst(Self.mediaViewLimit))
        let loadedItems = await loadMediaViewItems(
            paths: requestedPaths,
            imageProvider: imageProvider
        )
        let items = loadedItems.compactMap(\.item)
        let failures = loadedItems.compactMap(\.failure)

        guard !items.isEmpty else {
            let stdout = Self.viewText(
                sentItems: [],
                deniedItems: [],
                limitSkippedPaths: limitSkippedPaths,
                failures: failures
            )
            return MSPCommandResult(
                stdout: stdout,
                stderr: "",
                exitCode: failures.isEmpty ? 0 : 1
            )
        }

        let allowedItemIDs: Set<UUID>
        switch sensitiveReadPolicy {
        case .alwaysAllow:
            allowedItemIDs = Set(items.map(\.id))
        case .askEveryTime:
            guard let mediaViewAuthorizer else {
                return .failure(stderr: "media view: sensitive read approval UI is unavailable\n")
            }
            let decision = await mediaViewAuthorizer.authorizeMediaView(
                PhotoSorterMediaViewAuthorizationRequest(
                    items: items,
                    limitSkippedPaths: limitSkippedPaths
                )
            )
            allowedItemIDs = decision.allowedItemIDs
        }

        let sentItems = items.filter { allowedItemIDs.contains($0.id) }
        let deniedItems = items.filter { !allowedItemIDs.contains($0.id) }
        let stdout = Self.viewText(
            sentItems: sentItems,
            deniedItems: deniedItems,
            limitSkippedPaths: limitSkippedPaths,
            failures: failures
        )
        let modelContentItems = sentItems.compactMap { item -> MSPCommandModelContentItem? in
            guard let image = item.image else {
                return nil
            }
            return MSPCommandModelContentItem.inputImage(
                data: image.data,
                mimeType: image.mimeType,
                detail: "high"
            )
        }
        let exitCode: Int32 = sentItems.isEmpty && !failures.isEmpty && deniedItems.isEmpty ? 1 : 0
        return MSPCommandResult(
            stdout: stdout,
            stderr: "",
            exitCode: exitCode,
            modelContentItems: modelContentItems
        )
    }

    func runAsk(
        arguments: [String],
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media ask: media review requires full Photos access mode\n")
        }
        guard reviewProvider != nil || imageProvider != nil else {
            return .failure(stderr: "media ask: media review is unavailable\n")
        }
        guard let mediaViewAuthorizer else {
            return .failure(stderr: "media ask: user review UI is unavailable\n")
        }

        let parsed: PhotoSorterMediaAskArguments
        do {
            parsed = try Self.parseAskArguments(
                arguments,
                commandName: "media ask",
                defaultLimit: nil,
                allowsInlinePaths: true
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media ask: \(error)")
        }
        let rawPaths: [String]
        let reasonsByPath: [String: PhotoSorterMediaAskReason]
        do {
            if let jsonlFile = parsed.jsonlFile {
                let jsonlInput = try readAskJSONL(
                    jsonlFile,
                    limit: parsed.limit,
                    commandName: "media ask",
                    context: context
                )
                rawPaths = jsonlInput.paths
                reasonsByPath = jsonlInput.reasonsByPath
            } else {
                rawPaths = try readCommandPaths(
                    parsed.rawPaths,
                    fromFile: parsed.pathListFile,
                    limit: parsed.limit,
                    commandName: "media ask",
                    context: context
                )
                reasonsByPath = [:]
            }
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media ask: \(error)\n")
        }

        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let requestedPaths = Array(paths.prefix(Self.mediaAskLimit))
        let limitSkippedPaths = Array(paths.dropFirst(Self.mediaAskLimit))
        Self.recordMediaAskDiagnostic("media_ask_request_prepared", fields: [
            "requested": "\(paths.count)",
            "preview_requested": "\(requestedPaths.count)",
            "limit_skipped": "\(limitSkippedPaths.count)"
        ])
        let timeoutNanoseconds = mediaPreviewLoadTimeoutNanoseconds
        let itemLoader = PhotoSorterMediaViewItemLoader { index, path in
            Self.recordMediaAskDiagnostic("media_ask_preview_item_start", fields: [
                "index": "\(index)",
                "path": path
            ])
            let result = await Self.loadMediaViewItem(
                index: index,
                path: path,
                reviewProvider: reviewProvider,
                imageProvider: imageProvider,
                timeoutNanoseconds: timeoutNanoseconds
            )
            var fields = [
                "index": "\(index)",
                "path": path,
                "loaded": "\(result.item != nil)"
            ]
            if let failure = result.failure {
                fields["failure"] = failure.message
            }
            Self.recordMediaAskDiagnostic("media_ask_preview_item_finish", fields: fields)
            return result
        }

        let decision = await mediaViewAuthorizer.authorizeMediaView(
            PhotoSorterMediaViewAuthorizationRequest(
                purpose: .askUser,
                message: parsed.message,
                items: [],
                pendingPaths: requestedPaths,
                reasonsByPath: reasonsByPath,
                itemLoader: itemLoader,
                limitSkippedPaths: limitSkippedPaths
            )
        )
        Self.recordMediaAskDiagnostic("media_ask_decision_received", fields: [
            "cancelled": "\(decision.cancelled)",
            "reviewed": "\(decision.reviewedItems.count)",
            "allowed": "\(decision.allowedItemIDs.count)",
            "skipped_failures": "\(decision.skippedFailures.count)"
        ])
        let items = decision.reviewedItems
        let failures = decision.skippedFailures
        let records = askRecords(for: items, reasonsByPath: reasonsByPath)
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.itemID, $0) })
        let selectedRecords = items
            .filter { !decision.cancelled && decision.allowedItemIDs.contains($0.id) }
            .compactMap { recordsByID[$0.id] }
        let excludedRecords = items
            .filter { decision.cancelled || !decision.allowedItemIDs.contains($0.id) }
            .compactMap { recordsByID[$0.id] }
        let skippedPaths = Self.askSkippedPaths(
            limitSkippedPaths: limitSkippedPaths,
            failures: failures
        )
        if !decision.cancelled {
            let excludedPaths = excludedRecords.map(\.path)
            if !excludedPaths.isEmpty {
                do {
                    try askExclusionTracker?.recordPhotoSorterMediaAskExclusionsByUser(at: excludedPaths)
                } catch {
                    Self.recordMediaAskDiagnostic("media_ask_exclusion_count_record_failed", fields: [
                        "count": "\(excludedPaths.count)",
                        "message": error.localizedDescription
                    ])
                }
            }
        }
        let writtenPathLists: [PhotoSorterMediaAskWriteResult]
        do {
            writtenPathLists = try writeAskPathLists(
                selectedPaths: selectedRecords.map(\.path),
                excludedPaths: excludedRecords.map(\.path),
                skippedPaths: skippedPaths,
                arguments: parsed,
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media ask: \(error)\n")
        }
        let stdout = Self.askText(
            cancelled: decision.cancelled,
            requestedCount: paths.count,
            userNote: decision.note,
            selectedRecords: selectedRecords,
            excludedRecords: excludedRecords,
            limitSkippedPaths: limitSkippedPaths,
            failures: failures,
            reasonsByPath: reasonsByPath,
            writtenPathLists: writtenPathLists
        )
        return MSPCommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    func loadMediaViewItems(
        paths: [String],
        imageProvider: any PhotoSorterMediaImageProviding
    ) async -> [PhotoSorterMediaViewLoadResult] {
        await withTaskGroup(of: PhotoSorterMediaViewLoadResult.self) { group in
            for (index, path) in paths.enumerated() {
                let timeoutNanoseconds = mediaPreviewLoadTimeoutNanoseconds
                group.addTask {
                    await Self.loadMediaViewItem(
                        index: index,
                        path: path,
                        reviewProvider: nil,
                        imageProvider: imageProvider,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                }
            }
            var results: [PhotoSorterMediaViewLoadResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    static func loadMediaViewItem(
        index: Int,
        path: String,
        reviewProvider: (any PhotoSorterMediaReviewProviding)?,
        imageProvider: any PhotoSorterMediaImageProviding,
        timeoutNanoseconds: UInt64
    ) async -> PhotoSorterMediaViewLoadResult {
        await loadMediaViewItem(
            index: index,
            path: path,
            itemProvider: { path in
                if let reviewProvider,
                   let item = try await reviewProvider.photoSorterReviewMedia(
                    for: path,
                    maxPixelDimension: Self.mediaViewPreferredMaximumPixelDimension
                   ) {
                    return item
                }
                guard let image = try await imageProvider.photoSorterModelImage(
                    for: path,
                    maxPixelDimension: Self.mediaViewPreferredMaximumPixelDimension
                ) else {
                    return nil
                }
                return PhotoSorterMediaViewItem(image: Self.modelImage(for: image))
            },
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    static func loadMediaViewItem(
        index: Int,
        path: String,
        reviewProvider: (any PhotoSorterMediaReviewProviding)?,
        imageProvider: (any PhotoSorterMediaImageProviding)?,
        timeoutNanoseconds: UInt64
    ) async -> PhotoSorterMediaViewLoadResult {
        await loadMediaViewItem(
            index: index,
            path: path,
            itemProvider: { path in
                if let reviewProvider {
                    return try await reviewProvider.photoSorterReviewMedia(
                        for: path,
                        maxPixelDimension: Self.mediaViewPreferredMaximumPixelDimension
                    )
                }
                guard let imageProvider,
                      let image = try await imageProvider.photoSorterModelImage(
                        for: path,
                        maxPixelDimension: Self.mediaViewPreferredMaximumPixelDimension
                      )
                else {
                    return nil
                }
                return PhotoSorterMediaViewItem(image: Self.modelImage(for: image))
            },
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    static func loadMediaViewItem(
        index: Int,
        path: String,
        itemProvider: @escaping @Sendable (String) async throws -> PhotoSorterMediaViewItem?,
        timeoutNanoseconds: UInt64
    ) async -> PhotoSorterMediaViewLoadResult {
        await withCheckedContinuation { continuation in
            let race = PhotoSorterMediaViewLoadRace(continuation: continuation)
            let loadTask = Task {
                let result = await Self.loadMediaViewItemWithoutOuterTimeout(
                    index: index,
                    path: path,
                    itemProvider: itemProvider
                )
                race.resume(result)
            }
            if race.setLoadTask(loadTask) {
                loadTask.cancel()
            }

            Task {
                try? await Task.sleep(nanoseconds: max(timeoutNanoseconds, 1))
                let result = PhotoSorterMediaViewLoadResult(
                    index: index,
                    item: nil,
                    failure: PhotoSorterMediaViewFailure(
                        path: path,
                        message: mediaPreviewTimeoutMessage(timeoutNanoseconds: timeoutNanoseconds)
                    )
                )
                if race.resume(result) {
                    loadTask.cancel()
                }
            }
        }
    }

    static func loadMediaViewItemWithoutOuterTimeout(
        index: Int,
        path: String,
        itemProvider: @escaping @Sendable (String) async throws -> PhotoSorterMediaViewItem?
    ) async -> PhotoSorterMediaViewLoadResult {
        do {
            guard let item = try await itemProvider(path) else {
                return PhotoSorterMediaViewLoadResult(
                    index: index,
                    item: nil,
                    failure: PhotoSorterMediaViewFailure(path: path, message: "media asset not found")
                )
            }
            return PhotoSorterMediaViewLoadResult(
                index: index,
                item: item,
                failure: nil
            )
        } catch {
            return PhotoSorterMediaViewLoadResult(
                index: index,
                item: nil,
                failure: PhotoSorterMediaViewFailure(path: path, message: error.localizedDescription)
            )
        }
    }

    static func mediaPreviewTimeoutMessage(timeoutNanoseconds: UInt64) -> String {
        let seconds = Double(timeoutNanoseconds) / 1_000_000_000
        if seconds >= 1, seconds.rounded() == seconds {
            return "preview timed out after \(Int(seconds))s"
        }
        return "preview timed out after \(String(format: "%.2f", seconds))s"
    }

    static func recordMediaAskDiagnostic(
        _ event: String,
        fields: [String: String] = [:]
    ) {
        Task {
            await PhotoSorterDiagnosticsLog.shared.record(event, fields: fields)
        }
    }

    func askRecords(
        for items: [PhotoSorterMediaViewItem],
        reasonsByPath: [String: PhotoSorterMediaAskReason]
    ) -> [PhotoSorterMediaAskRecord] {
        let paths = items.map(\.path)
        let metadataLookups = mediaProvider.photoSorterMediaMetadata(for: paths)
        let ocrCacheLookups = ocrProvider?.cachedPhotoSorterMediaOCRTexts(for: paths) ?? []
        let vlmCacheLookups = vlmProvider?.cachedPhotoSorterVLMSummaries(for: paths) ?? []

        return items.indices.map { index in
            let item = items[index]
            let metadataLookup = metadataLookups.indices.contains(index)
                ? metadataLookups[index]
                : .unavailable("metadata lookup failed")
            let dateText: String
            let dimensionsText: String
            switch metadataLookup {
            case .hit(let metadata):
                dateText = Self.createdText(for: metadata.creationDate)
                dimensionsText = "\(max(metadata.pixelWidth, 0))x\(max(metadata.pixelHeight, 0))"
            case .unavailable:
                dateText = "unknown"
                dimensionsText = "\(max(item.pixelWidth, 0))x\(max(item.pixelHeight, 0))"
            }
            return PhotoSorterMediaAskRecord(
                itemID: item.id,
                path: item.path,
                dateText: dateText,
                dimensionsText: dimensionsText,
                ocrCacheAvailable: ocrCacheAvailable(
                    ocrCacheLookups.indices.contains(index) ? ocrCacheLookups[index] : nil
                ),
                vlmCacheAvailable: vlmCacheAvailable(
                    vlmCacheLookups.indices.contains(index) ? vlmCacheLookups[index] : nil
                ),
                reason: reasonsByPath[item.path]
            )
        }
    }
}

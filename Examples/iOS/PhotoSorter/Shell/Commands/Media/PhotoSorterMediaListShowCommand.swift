import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func runList(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        let parsed: PhotoSorterMediaListArguments
        do {
            parsed = try Self.parseListArguments(arguments)
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media list: \(error)")
        }
        guard let mediaLister else {
            return .failure(stderr: "media list: media listing is unavailable\n")
        }
        let scope = normalizedPath(parsed.scopePath, from: context.currentDirectory)
        do {
            let page = try mediaLister.photoSorterMediaList(
                in: scope,
                offset: parsed.offset,
                limit: parsed.limit,
                sort: parsed.sort,
                order: parsed.order,
                mediaType: parsed.mediaType
            )
            let stdout = Self.listText(items: page.items, format: parsed.format)
            let remaining = max(0, page.totalCount - page.offset - page.items.count)
            let stderr = "media list: total \(page.totalCount), offset \(page.offset), returned \(page.items.count), remaining \(remaining), scope \(scope)\n"
            return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
        } catch {
            return .failure(stderr: "media list: \(scope): \(error)\n")
        }
    }

    func runShow(
        arguments: [String],
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard let firstArgument = arguments.first else {
            return usageFailure("media show: usage: media show <path>...\nTry 'media help show' for more information.")
        }
        if firstArgument == "--ocr" {
            return await runShowOCR(
                rawPaths: Array(arguments.dropFirst()),
                context: context
            )
        }
        if firstArgument == "--vlm" {
            return await runShowVLM(
                rawPaths: Array(arguments.dropFirst()),
                context: context
            )
        }
        let parsed: PhotoSorterMediaShowArguments
        do {
            parsed = try Self.parseShowArguments(arguments, commandName: "media show")
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media show: \(error)")
        }

        let accessMode = agentAccessModeProvider.currentAgentAccessMode()
        var sections: [String] = []
        var records: [PhotoSorterMediaShowRecord] = []
        var errors: [String] = []
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media show",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media show: \(error)\n")
        }
        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let metadataLookups = mediaProvider.photoSorterMediaMetadata(for: paths)
        let ocrCacheLookups = ocrProvider?.cachedPhotoSorterMediaOCRTexts(for: paths) ?? []
        let vlmCacheLookups = vlmProvider?.cachedPhotoSorterVLMSummaries(for: paths) ?? []
        let askExcludedCounts = askExclusionTracker?.photoSorterMediaAskExcludedCountsByUser(for: paths) ?? []

        for index in paths.indices {
            let path = paths[index]
            let metadataLookup = metadataLookups.indices.contains(index)
                ? metadataLookups[index]
                : .unavailable("metadata lookup failed")
            switch metadataLookup {
            case .hit(let metadata):
                let ocrCacheAvailable = ocrCacheAvailable(
                    ocrCacheLookups.indices.contains(index) ? ocrCacheLookups[index] : nil
                )
                let vlmCacheAvailable = vlmCacheAvailable(
                    vlmCacheLookups.indices.contains(index) ? vlmCacheLookups[index] : nil
                )
                let mediaAskExcludedCountByUser = askExcludedCounts.indices.contains(index)
                    ? max(askExcludedCounts[index], 0)
                    : 0
                records.append(PhotoSorterMediaShowRecord(
                    metadata: metadata,
                    ocrCacheAvailable: ocrCacheAvailable,
                    vlmCacheAvailable: vlmCacheAvailable,
                    mediaAskExcludedCountByUser: mediaAskExcludedCountByUser
                ))
                sections.append(Self.text(
                    for: metadata,
                    accessMode: accessMode,
                    ocrCacheAvailable: ocrCacheAvailable,
                    vlmCacheAvailable: vlmCacheAvailable,
                    mediaAskExcludedCountByUser: mediaAskExcludedCountByUser
                ))
            case .unavailable(let message):
                errors.append("media show: \(path): \(message)")
            }
        }

        let stdout = Self.showText(records: records, sections: sections, format: parsed.format)
        let stderr = errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n"
        let exitCode: Int32 = sections.isEmpty && !errors.isEmpty ? 1 : 0
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }


    func runShowOCR(
        rawPaths: [String],
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media show --ocr: OCR requires full Photos access mode\n")
        }
        guard let ocrProvider else {
            return .failure(stderr: "media show --ocr: OCR is unavailable\n")
        }
        let parsed: PhotoSorterMediaPathListArguments
        do {
            parsed = try Self.parsePathListArguments(
                rawPaths,
                commandName: "media show --ocr",
                defaultLimit: nil,
                allowsInlinePaths: true
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media show --ocr: \(error)")
        }
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media show --ocr",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media show --ocr: \(error)\n")
        }

        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let askExcludedCounts = askExclusionTracker?.photoSorterMediaAskExcludedCountsByUser(for: paths) ?? []
        let askExcludedCountsByPath = Self.positiveCountsByPath(paths: paths, counts: askExcludedCounts)
        var slots = Array<PhotoSorterMediaOCRResult?>(repeating: nil, count: paths.count)
        var uncachedIndexes: [Int] = []
        var errors: [String] = []
        var cachedCount = 0
        var liveProcessedCount = 0

        let cacheLookups = ocrProvider.cachedPhotoSorterMediaOCRTexts(for: paths)
        for index in paths.indices {
            let path = paths[index]
            let lookup = cacheLookups.indices.contains(index)
                ? cacheLookups[index]
                : .unavailable("OCR cache lookup failed")
            switch lookup {
            case .hit(let result):
                slots[index] = result
                cachedCount += 1
            case .miss:
                uncachedIndexes.append(index)
            case .unavailable(let message):
                errors.append("media show --ocr: \(path): \(message)")
            }
        }

        let liveCount = PhotoSorterMediaLiveOCRBudget.reserve(
            requestedCount: min(Self.liveOCRLimit, uncachedIndexes.count),
            fallbackLimit: Self.liveOCRLimit
        )
        let liveIndexes = Array(uncachedIndexes.prefix(liveCount))
        for index in liveIndexes {
            let path = paths[index]
            liveProcessedCount += 1
            do {
                if let result = try await ocrProvider.recognizePhotoSorterMediaOCRText(for: path) {
                    slots[index] = result
                } else {
                    errors.append("media show --ocr: \(path): media asset not found")
                }
            } catch {
                errors.append("media show --ocr: \(path): \(error)")
            }
        }

        let skippedCount = max(0, uncachedIndexes.count - liveIndexes.count)
        let results = slots.compactMap(\.self)
        let stdout = Self.ocrText(
            for: results,
            requestedCount: paths.count,
            cachedCount: cachedCount,
            liveProcessedCount: liveProcessedCount,
            skippedCount: skippedCount,
            mediaAskExcludedCountsByPath: askExcludedCountsByPath
        )
        let stderr = errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n"
        let exitCode: Int32 = results.isEmpty && !errors.isEmpty ? 1 : 0
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    func runShowVLM(
        rawPaths: [String],
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media show --vlm: VLM requires full Photos access mode\n")
        }
        guard let vlmProvider else {
            return .failure(stderr: "media show --vlm: VLM is unavailable\n")
        }
        let parsed: PhotoSorterMediaPathListArguments
        do {
            parsed = try Self.parsePathListArguments(
                rawPaths,
                commandName: "media show --vlm",
                defaultLimit: nil,
                allowsInlinePaths: true
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media show --vlm: \(error)")
        }
        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsed.rawPaths,
                fromFile: parsed.pathListFile,
                limit: parsed.limit,
                commandName: "media show --vlm",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media show --vlm: \(error)\n")
        }

        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let askExcludedCounts = askExclusionTracker?.photoSorterMediaAskExcludedCountsByUser(for: paths) ?? []
        let askExcludedCountsByPath = Self.positiveCountsByPath(paths: paths, counts: askExcludedCounts)
        var slots = Array<PhotoSorterMediaVLMSummaryResult?>(repeating: nil, count: paths.count)
        var uncachedIndexes: [Int] = []
        var errors: [String] = []
        var cachedCount = 0
        var liveProcessedCount = 0

        let cacheLookups = vlmProvider.cachedPhotoSorterVLMSummaries(for: paths)
        for index in paths.indices {
            let path = paths[index]
            let lookup = cacheLookups.indices.contains(index)
                ? cacheLookups[index]
                : .unavailable("VLM cache lookup failed")
            switch lookup {
            case .hit(let result):
                slots[index] = result
                cachedCount += 1
            case .miss:
                uncachedIndexes.append(index)
            case .unavailable(let message):
                errors.append("media show --vlm: \(path): \(message)")
            }
        }

        let status = vlmProvider.photoSorterVLMStatus()
        let liveCount = status.primaryProvider.isLiveSummarizationAvailable
            ? PhotoSorterMediaLiveVLMBudget.reserve(
                requestedCount: min(Self.liveVLMLimit, uncachedIndexes.count),
                fallbackLimit: Self.liveVLMLimit
            )
            : 0
        let liveIndexes = Array(uncachedIndexes.prefix(liveCount))
        for index in liveIndexes {
            let path = paths[index]
            liveProcessedCount += 1
            do {
                if let result = try await vlmProvider.summarizePhotoSorterMediaVLM(for: path) {
                    slots[index] = result
                } else {
                    errors.append("media show --vlm: \(path): media asset not found")
                }
            } catch {
                errors.append("media show --vlm: \(path): \(error)")
            }
        }

        let skippedCount = max(0, uncachedIndexes.count - liveIndexes.count)
        let results = slots.compactMap(\.self)
        let stdout = Self.vlmText(
            for: results,
            requestedCount: paths.count,
            cachedCount: cachedCount,
            liveProcessedCount: liveProcessedCount,
            skippedCount: skippedCount,
            mediaAskExcludedCountsByPath: askExcludedCountsByPath,
            liveUnavailableReason: liveCount == 0 && !uncachedIndexes.isEmpty
                ? status.primaryProvider.reason
                : nil
        )
        let stderr = errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n"
        let exitCode: Int32 = results.isEmpty && !errors.isEmpty ? 1 : 0
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    func ocrCacheAvailable(_ lookup: PhotoSorterMediaOCRCacheLookup?) -> Bool? {
        guard ocrProvider != nil else {
            return nil
        }
        guard let lookup else {
            return false
        }
        switch lookup {
        case .hit:
            return true
        case .miss, .unavailable:
            return false
        }
    }

    func vlmCacheAvailable(_ lookup: PhotoSorterMediaVLMCacheLookup?) -> Bool? {
        guard vlmProvider != nil else {
            return nil
        }
        guard let lookup else {
            return false
        }
        switch lookup {
        case .hit:
            return true
        case .miss, .unavailable:
            return false
        }
    }
}

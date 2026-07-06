import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func runSearch(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        guard let target = arguments.first else {
            return usageFailure("media search: usage: media search --ocr <keyword> <path>... | media search --ocr --regex <pattern> <path>... | media search --vlm <keyword> <path>... | media search --vlm --regex <pattern> <path>...\nTry 'media help search --ocr' or 'media help search --vlm' for more information.")
        }
        switch target {
        case "--ocr":
            return runSearchOCR(
                arguments: Array(arguments.dropFirst()),
                context: context
            )
        case "--vlm":
            return runSearchVLM(
                arguments: Array(arguments.dropFirst()),
                context: context
            )
        default:
            return usageFailure("media search: usage: media search --ocr <keyword> <path>... | media search --ocr --regex <pattern> <path>... | media search --vlm <keyword> <path>... | media search --vlm --regex <pattern> <path>...\nTry 'media help search --ocr' or 'media help search --vlm' for more information.")
        }
    }

    func runSearchOCR(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media search --ocr: OCR search requires full Photos access mode\n")
        }
        guard let ocrProvider else {
            return .failure(stderr: "media search --ocr: OCR is unavailable\n")
        }
        let parsedArguments: PhotoSorterMediaSearchArguments
        do {
            parsedArguments = try Self.parseSearchArguments(
                arguments,
                commandName: "media search --ocr"
            )
        } catch let error as PhotoSorterMediaSearchUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media search --ocr: \(error)")
        }

        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsedArguments.rawPaths,
                fromFile: parsedArguments.pathListFile,
                limit: parsedArguments.limit,
                commandName: "media search --ocr",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media search --ocr: \(error)\n")
        }
        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let cacheLookups = ocrProvider.cachedPhotoSorterMediaOCRTexts(for: paths)
        var matches: [PhotoSorterMediaSearchMatch] = []
        var cachedCount = 0
        var uncachedCount = 0
        var unavailableSamples: [PhotoSorterMediaUnavailableSample] = []
        var unavailableCount = 0

        for index in paths.indices {
            let path = paths[index]
            let lookup = cacheLookups.indices.contains(index)
                ? cacheLookups[index]
                : .unavailable("OCR cache lookup failed")
            switch lookup {
            case .hit(let result):
                cachedCount += 1
                let searchableText = Self.collapsedSearchText(result.text)
                guard let matchRange = parsedArguments.mode.firstMatchRange(in: searchableText) else {
                    continue
                }
                matches.append(PhotoSorterMediaSearchMatch(
                    path: path,
                    source: "ocr",
                    queryKind: parsedArguments.mode.jsonQueryKind,
                    query: parsedArguments.mode.queryText,
                    match: Self.mediaSearchMatchedText(in: searchableText, matchRange: matchRange),
                    snippet: Self.mediaSearchSnippet(
                        in: searchableText,
                        matchRange: matchRange,
                        maximumLength: Self.mediaSearchSnippetMaximumLength
                    )
                ))
            case .miss:
                uncachedCount += 1
            case .unavailable(let message):
                unavailableCount += 1
                if unavailableSamples.count < Self.mediaSearchUnavailableSampleLimit {
                    unavailableSamples.append(PhotoSorterMediaUnavailableSample(
                        path: path,
                        message: message
                    ))
                }
            }
        }

        return Self.mediaSearchResult(
            title: "OCR search",
            format: parsedArguments.format,
            mode: parsedArguments.mode,
            requestedCount: paths.count,
            cachedCount: cachedCount,
            uncachedCount: uncachedCount,
            unavailableCount: unavailableCount,
            matches: matches,
            unavailableSamples: unavailableSamples
        )
    }

    func runSearchVLM(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        guard agentAccessModeProvider.currentAgentAccessMode() == .full else {
            return .failure(stderr: "media search --vlm: VLM search requires full Photos access mode\n")
        }
        guard let vlmProvider else {
            return .failure(stderr: "media search --vlm: VLM is unavailable\n")
        }
        let parsedArguments: PhotoSorterMediaSearchArguments
        do {
            parsedArguments = try Self.parseSearchArguments(
                arguments,
                commandName: "media search --vlm"
            )
        } catch let error as PhotoSorterMediaSearchUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media search --vlm: \(error)")
        }

        let rawPaths: [String]
        do {
            rawPaths = try readCommandPaths(
                parsedArguments.rawPaths,
                fromFile: parsedArguments.pathListFile,
                limit: parsedArguments.limit,
                commandName: "media search --vlm",
                context: context
            )
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return .failure(stderr: "media search --vlm: \(error)\n")
        }
        let paths = rawPaths.map { normalizedPath($0, from: context.currentDirectory) }
        let cacheLookups = vlmProvider.cachedPhotoSorterVLMSummaries(for: paths)
        var matches: [PhotoSorterMediaSearchMatch] = []
        var cachedCount = 0
        var uncachedCount = 0
        var unavailableSamples: [PhotoSorterMediaUnavailableSample] = []
        var unavailableCount = 0

        for index in paths.indices {
            let path = paths[index]
            let lookup = cacheLookups.indices.contains(index)
                ? cacheLookups[index]
                : .unavailable("VLM cache lookup failed")
            switch lookup {
            case .hit(let result):
                cachedCount += 1
                let searchableText = Self.collapsedSearchText(result.summary)
                guard let matchRange = parsedArguments.mode.firstMatchRange(in: searchableText) else {
                    continue
                }
                matches.append(PhotoSorterMediaSearchMatch(
                    path: path,
                    source: "vlm",
                    queryKind: parsedArguments.mode.jsonQueryKind,
                    query: parsedArguments.mode.queryText,
                    match: Self.mediaSearchMatchedText(in: searchableText, matchRange: matchRange),
                    snippet: Self.mediaSearchSnippet(
                        in: searchableText,
                        matchRange: matchRange,
                        maximumLength: Self.mediaSearchSnippetMaximumLength
                    )
                ))
            case .miss:
                uncachedCount += 1
            case .unavailable(let message):
                unavailableCount += 1
                if unavailableSamples.count < Self.mediaSearchUnavailableSampleLimit {
                    unavailableSamples.append(PhotoSorterMediaUnavailableSample(
                        path: path,
                        message: message
                    ))
                }
            }
        }

        return Self.mediaSearchResult(
            title: "VLM search",
            format: parsedArguments.format,
            mode: parsedArguments.mode,
            requestedCount: paths.count,
            cachedCount: cachedCount,
            uncachedCount: uncachedCount,
            unavailableCount: unavailableCount,
            matches: matches,
            unavailableSamples: unavailableSamples
        )
    }
}

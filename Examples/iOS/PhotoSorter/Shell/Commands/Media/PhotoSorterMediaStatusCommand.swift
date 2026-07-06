import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    func runVLM(arguments: [String]) -> MSPCommandResult {
        guard arguments.isEmpty || arguments == ["status"] else {
            return usageFailure("media vlm: usage: media vlm status\nTry 'media help vlm' for more information.")
        }
        let status = vlmProvider?.photoSorterVLMStatus() ?? .unavailable
        return MSPCommandResult(stdout: Self.vlmStatusText(status), stderr: "", exitCode: 0)
    }

    func runStatus(arguments: [String]) -> MSPCommandResult {
        guard arguments.isEmpty else {
            return usageFailure("media status: usage: media status\nTry 'media help status' for more information.")
        }
        let indexStatus = cacheStatusProvider?.photoSorterMediaIndexStatus
        let ocrStatus = cacheStatusProvider?.photoSorterMediaOCRCacheStatus ?? .idle
        let vlmStatus = vlmProvider?.photoSorterVLMStatus() ?? .unavailable
        let placeStatus = cacheStatusProvider?.photoSorterMediaPlaceCacheStatus ?? .idle
        return .success(stdout: Self.statusText(
            indexStatus: indexStatus,
            ocrStatus: ocrStatus,
            vlmStatus: vlmStatus,
            placeStatus: placeStatus
        ))
    }

    func runCache(arguments: [String]) -> MSPCommandResult {
        guard arguments.first == "status" else {
            return usageFailure("media cache: usage: media cache status [ocr|vlm|place]\nTry 'media help cache status' for more information.")
        }
        let target = arguments.dropFirst().first
        guard arguments.count <= 2,
              target == nil || target == "ocr" || target == "vlm" || target == "place"
        else {
            return usageFailure("media cache status: usage: media cache status [ocr|vlm|place]\nTry 'media help cache status' for more information.")
        }
        let ocrStatus = cacheStatusProvider?.photoSorterMediaOCRCacheStatus ?? .idle
        let vlmStatus = vlmProvider?.photoSorterVLMStatus() ?? .unavailable
        let placeStatus = cacheStatusProvider?.photoSorterMediaPlaceCacheStatus ?? .idle
        return .success(stdout: Self.cacheStatusText(
            target: target,
            ocrStatus: ocrStatus,
            vlmStatus: vlmStatus,
            placeStatus: placeStatus
        ))
    }

    func runStats(
        arguments: [String],
        context: MSPCommandContext
    ) -> MSPCommandResult {
        let parsed: PhotoSorterMediaStatsArguments
        do {
            parsed = try Self.parseStatsArguments(arguments)
        } catch let error as PhotoSorterMediaUsageError {
            return usageFailure(error.message)
        } catch {
            return usageFailure("media stats: \(error)")
        }
        guard let mediaStatsProvider else {
            return .failure(stderr: "media stats: media stats are unavailable\n")
        }
        let scope = normalizedPath(parsed.scopePath, from: context.currentDirectory)
        do {
            let buckets = try mediaStatsProvider.photoSorterMediaStats(
                in: scope,
                groupBy: parsed.groupBy,
                dateField: parsed.dateField,
                mediaType: parsed.mediaType
            )
            return .success(stdout: Self.statsText(
                buckets: buckets,
                format: parsed.format
            ))
        } catch {
            return .failure(stderr: "media stats: \(scope): \(error)\n")
        }
    }
}

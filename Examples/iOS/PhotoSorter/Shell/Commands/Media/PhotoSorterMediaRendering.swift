import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    static func text(
        for metadata: PhotoSorterMediaMetadata,
        accessMode: PhotoSorterAgentAccessMode = .standard,
        ocrCacheAvailable: Bool? = nil,
        vlmCacheAvailable: Bool? = nil,
        mediaAskExcludedCountByUser: Int = 0
    ) -> String {
        var lines = [
            "Path: \(metadata.path)",
            "Size: \(max(metadata.pixelWidth, 0))x\(max(metadata.pixelHeight, 0))",
            "Created: \(createdText(for: metadata.creationDate))"
        ]
        if let ocrCacheAvailable {
            lines.append("OCR: \(ocrCacheAvailable ? "true" : "false")")
        }
        if let vlmCacheAvailable {
            lines.append("VLM: \(vlmCacheAvailable ? "true" : "false")")
        }
        if accessMode == .full,
           let place = metadata.cachedPlace?.trimmingCharacters(in: .whitespacesAndNewlines),
           !place.isEmpty {
            lines.append("地点: \(place)")
        }
        if mediaAskExcludedCountByUser > 0 {
            lines.append("media ask excluded count by user: \(mediaAskExcludedCountByUser)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func ocrText(
        for results: [PhotoSorterMediaOCRResult],
        requestedCount: Int,
        cachedCount: Int,
        liveProcessedCount: Int,
        skippedCount: Int,
        mediaAskExcludedCountsByPath: [String: Int] = [:]
    ) -> String {
        var sections: [String]
        if requestedCount == 1, let result = results.first, skippedCount == 0 {
            sections = [result.text]
        } else {
            sections = results.map { result in
                mediaEvidenceSection(
                    path: result.path,
                    body: result.text,
                    mediaAskExcludedCountsByPath: mediaAskExcludedCountsByPath
                )
            }
        }

        if skippedCount > 0 {
            sections.append(
                "OCR limit: requested \(requestedCount), returned \(results.count), cached \(cachedCount), processed \(liveProcessedCount), skipped \(skippedCount). Re-run with the remaining paths."
            )
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func vlmText(
        for results: [PhotoSorterMediaVLMSummaryResult],
        requestedCount: Int,
        cachedCount: Int,
        liveProcessedCount: Int,
        skippedCount: Int,
        mediaAskExcludedCountsByPath: [String: Int] = [:],
        liveUnavailableReason: String?
    ) -> String {
        var sections: [String]
        if requestedCount == 1, let result = results.first, skippedCount == 0 {
            sections = [result.summary]
        } else {
            sections = results.map { result in
                mediaEvidenceSection(
                    path: result.path,
                    body: result.summary,
                    mediaAskExcludedCountsByPath: mediaAskExcludedCountsByPath
                )
            }
        }

        if skippedCount > 0 {
            var limitText = "VLM limit: requested \(requestedCount), returned \(results.count), cached \(cachedCount), processed \(liveProcessedCount), skipped \(skippedCount). Re-run with the remaining paths."
            if let liveUnavailableReason, !liveUnavailableReason.isEmpty {
                limitText += " Live VLM unavailable: \(liveUnavailableReason)."
            }
            sections.append(limitText)
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func positiveCountsByPath(paths: [String], counts: [Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, path) in paths.enumerated() where counts.indices.contains(index) {
            let count = max(counts[index], 0)
            guard count > 0 else {
                continue
            }
            result[path] = count
        }
        return result
    }

    static func mediaEvidenceSection(
        path: String,
        body: String,
        mediaAskExcludedCountsByPath: [String: Int]
    ) -> String {
        var lines = ["\(path):"]
        if let count = mediaAskExcludedCountsByPath[path], count > 0 {
            lines.append("media ask excluded count by user: \(count)")
        }
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    static func mediaSearchText(
        title: String,
        mode: PhotoSorterMediaSearchMode,
        requestedCount: Int,
        cachedCount: Int,
        uncachedCount: Int,
        unavailableCount: Int,
        matches: [PhotoSorterMediaSearchMatch],
        unavailableSamples: [PhotoSorterMediaUnavailableSample]
    ) -> String {
        var sections = [
            "\(title): requested \(requestedCount), cached \(cachedCount), matched \(matches.count), uncached \(uncachedCount), unavailable \(unavailableCount).",
            mode.descriptionLine
        ]
        if !matches.isEmpty {
            sections.append(
                matches.map { match in
                    "\(match.path):\n\(match.snippet)"
                }
                .joined(separator: "\n\n")
            )
        }
        if !unavailableSamples.isEmpty {
            sections.append(
                (["Unavailable cache samples:"] + unavailableSamples.map { sample in
                    "- \(sample.path): \(sample.message)"
                })
                .joined(separator: "\n")
            )
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func vlmStatusText(_ status: PhotoSorterMediaVLMStatus) -> String {
        let provider = status.primaryProvider
        let systemProvider = status.systemProvider
        var lines = [
            "VLM: \(provider.modelState.rawValue)",
            "Backend: \(provider.backend)",
            "Model: \(provider.modelID) \(provider.modelVersion)",
            "Model status: \(provider.modelState.rawValue)",
            "System provider: \(systemProvider.modelState.rawValue)"
                + (systemProvider.reason.map { " (\($0))" } ?? ""),
            "Cache: \(status.cachedCount)/\(status.totalCount)",
            "Processed current batch: \(status.processedInCurrentBatch)/\(status.batchLimit)",
            "Failed/skipped current batch: \(status.failedInCurrentBatch)/\(status.skippedInCurrentBatch)",
            "Prompt: \(status.promptVersion)",
            "Language: \(status.language)",
            "Summary schema: \(status.summarySchemaVersion)",
            "Processor: \(provider.processorConfigFingerprint)"
        ]
        if let reason = provider.reason, !reason.isEmpty {
            lines.append("Reason: \(reason)")
        }
        if let message = status.message, !message.isEmpty {
            lines.append("Message: \(message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func listText(
        items: [PhotoSorterMediaListItem],
        format: PhotoSorterMediaListFormat
    ) -> String {
        switch format {
        case .paths:
            return items.map(\.path).joined(separator: "\n") + (items.isEmpty ? "" : "\n")
        case .tsv:
            let rows = ["path\ttype\twidth\theight\tcreated\tmodified"] + items.map { item in
                [
                    item.path,
                    item.mediaType.rawValue,
                    String(max(item.pixelWidth, 0)),
                    String(max(item.pixelHeight, 0)),
                    createdText(for: item.creationDate),
                    createdText(for: item.modificationDate)
                ].map(tsvField).joined(separator: "\t")
            }
            return rows.joined(separator: "\n") + "\n"
        case .jsonl:
            return items.map { item in
                jsonObjectLine([
                    "path": item.path,
                    "type": item.mediaType.rawValue,
                    "width": max(item.pixelWidth, 0),
                    "height": max(item.pixelHeight, 0),
                    "created": createdText(for: item.creationDate),
                    "modified": createdText(for: item.modificationDate)
                ])
            }.joined(separator: "\n") + (items.isEmpty ? "" : "\n")
        }
    }

    static func showText(
        records: [PhotoSorterMediaShowRecord],
        sections: [String],
        format: PhotoSorterMediaShowFormat
    ) -> String {
        switch format {
        case .text:
            return sections.joined(separator: "\n")
        case .tsv:
            let rows = ["path\ttype\twidth\theight\tcreated\tmodified\tocr\tvlm"] + records.map { record in
                let metadata = record.metadata
                return [
                    metadata.path,
                    metadata.mediaType.rawValue,
                    String(max(metadata.pixelWidth, 0)),
                    String(max(metadata.pixelHeight, 0)),
                    createdText(for: metadata.creationDate),
                    createdText(for: metadata.modificationDate),
                    boolText(record.ocrCacheAvailable),
                    boolText(record.vlmCacheAvailable)
                ].map(tsvField).joined(separator: "\t")
            }
            return rows.joined(separator: "\n") + "\n"
        case .jsonl:
            return records.map { record in
                let metadata = record.metadata
                return jsonObjectLine([
                    "path": metadata.path,
                    "type": metadata.mediaType.rawValue,
                    "width": max(metadata.pixelWidth, 0),
                    "height": max(metadata.pixelHeight, 0),
                    "created": createdText(for: metadata.creationDate),
                    "modified": createdText(for: metadata.modificationDate),
                    "ocr": boolText(record.ocrCacheAvailable),
                    "vlm": boolText(record.vlmCacheAvailable)
                ])
            }.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
        }
    }

    static func mediaSearchResult(
        title: String,
        format: PhotoSorterMediaSearchFormat,
        mode: PhotoSorterMediaSearchMode,
        requestedCount: Int,
        cachedCount: Int,
        uncachedCount: Int,
        unavailableCount: Int,
        matches: [PhotoSorterMediaSearchMatch],
        unavailableSamples: [PhotoSorterMediaUnavailableSample]
    ) -> MSPCommandResult {
        switch format {
        case .snippets:
            return MSPCommandResult(
                stdout: mediaSearchText(
                    title: title,
                    mode: mode,
                    requestedCount: requestedCount,
                    cachedCount: cachedCount,
                    uncachedCount: uncachedCount,
                    unavailableCount: unavailableCount,
                    matches: matches,
                    unavailableSamples: unavailableSamples
                ),
                stderr: "",
                exitCode: 0
            )
        case .paths:
            return MSPCommandResult(
                stdout: matches.map(\.path).joined(separator: "\n") + (matches.isEmpty ? "" : "\n"),
                stderr: "\(title): requested \(requestedCount), cached \(cachedCount), matched \(matches.count), uncached \(uncachedCount), unavailable \(unavailableCount).\n",
                exitCode: 0
            )
        case .jsonl:
            let stdout = matches.map { match in
                var object: [String: Any] = [
                    "path": match.path,
                    "source": match.source,
                    "query_kind": match.queryKind,
                    "query": match.query,
                    "match": match.match,
                    "snippet": match.snippet
                ]
                if match.queryKind == "keyword" {
                    object["term"] = match.query
                } else if match.queryKind == "regex" {
                    object["pattern"] = match.query
                }
                return jsonObjectLine(object)
            }.joined(separator: "\n") + (matches.isEmpty ? "" : "\n")
            return MSPCommandResult(
                stdout: stdout,
                stderr: "\(title): requested \(requestedCount), cached \(cachedCount), matched \(matches.count), uncached \(uncachedCount), unavailable \(unavailableCount).\n",
                exitCode: 0
            )
        }
    }

    static func statusText(
        indexStatus: PhotoLibraryIndexStatus?,
        ocrStatus: PhotoSorterMediaOCRCacheStatus,
        vlmStatus: PhotoSorterMediaVLMStatus,
        placeStatus: PhotoSorterMediaPlaceCacheStatus
    ) -> String {
        var lines: [String] = []
        if let indexStatus {
            lines.append("Index: \(indexStatus.phase.rawValue), version \(indexStatus.version), processed \(indexStatus.processed)\(indexStatus.total.map { "/\($0)" } ?? "")")
        } else {
            lines.append("Index: unavailable")
        }
        lines.append(contentsOf: cacheStatusLines(target: nil, ocrStatus: ocrStatus, vlmStatus: vlmStatus, placeStatus: placeStatus))
        return lines.joined(separator: "\n") + "\n"
    }

    static func cacheStatusText(
        target: String?,
        ocrStatus: PhotoSorterMediaOCRCacheStatus,
        vlmStatus: PhotoSorterMediaVLMStatus,
        placeStatus: PhotoSorterMediaPlaceCacheStatus
    ) -> String {
        cacheStatusLines(
            target: target,
            ocrStatus: ocrStatus,
            vlmStatus: vlmStatus,
            placeStatus: placeStatus
        ).joined(separator: "\n") + "\n"
    }

    static func cacheStatusLines(
        target: String?,
        ocrStatus: PhotoSorterMediaOCRCacheStatus,
        vlmStatus: PhotoSorterMediaVLMStatus,
        placeStatus: PhotoSorterMediaPlaceCacheStatus
    ) -> [String] {
        var lines: [String] = []
        if target == nil || target == "ocr" {
            lines.append("OCR cache: \(ocrStatus.cachedCount)/\(ocrStatus.totalCount), preheating \(ocrStatus.isPreheating), paused \(ocrStatus.isPaused), batch \(ocrStatus.processedInCurrentBatch)/\(ocrStatus.batchLimit)")
            if let message = ocrStatus.message, !message.isEmpty {
                lines.append("OCR message: \(message)")
            }
        }
        if target == nil || target == "vlm" {
            lines.append("VLM cache: \(vlmStatus.cachedCount)/\(vlmStatus.totalCount), preheating \(vlmStatus.isPreheating), paused \(vlmStatus.isPaused), batch \(vlmStatus.processedInCurrentBatch)/\(vlmStatus.batchLimit), model \(vlmStatus.primaryProvider.modelState.rawValue)")
            if let message = vlmStatus.message, !message.isEmpty {
                lines.append("VLM message: \(message)")
            }
        }
        if target == nil || target == "place" {
            lines.append("Place cache: \(placeStatus.cachedCount)/\(placeStatus.totalCount), preheating \(placeStatus.isPreheating), paused \(placeStatus.isPaused), batch \(placeStatus.processedInCurrentBatch)/\(placeStatus.batchLimit)")
            if let message = placeStatus.message, !message.isEmpty {
                lines.append("Place message: \(message)")
            }
        }
        return lines
    }

    static func statsText(
        buckets: [PhotoSorterMediaStatsBucket],
        format: PhotoSorterMediaStatsFormat
    ) -> String {
        switch format {
        case .tsv:
            return (["key\tcount"] + buckets.map { "\($0.key)\t\($0.count)" }).joined(separator: "\n") + "\n"
        case .jsonl:
            return buckets.map { jsonObjectLine(["key": $0.key, "count": $0.count]) }.joined(separator: "\n") + (buckets.isEmpty ? "" : "\n")
        }
    }

    static func collapsedSearchText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func mediaSearchSnippet(
        in text: String,
        matchRange: NSRange,
        maximumLength: Int
    ) -> String {
        let nsText = text as NSString
        let maximumLength = max(1, maximumLength)
        guard nsText.length > maximumLength else {
            return text
        }
        let contextBefore = max(0, (maximumLength - matchRange.length) / 2)
        let start = max(0, matchRange.location - contextBefore)
        let end = min(nsText.length, start + maximumLength)
        let adjustedStart = max(0, min(start, end - maximumLength))
        let range = NSRange(location: adjustedStart, length: end - adjustedStart)
        var snippet = nsText.substring(with: range)
        if adjustedStart > 0 {
            snippet = "..." + snippet
        }
        if NSMaxRange(range) < nsText.length {
            snippet += "..."
        }
        return snippet
    }

    static func mediaSearchMatchedText(in text: String, matchRange: NSRange) -> String {
        let nsText = text as NSString
        guard matchRange.location != NSNotFound,
              matchRange.location >= 0,
              matchRange.length >= 0,
              NSMaxRange(matchRange) <= nsText.length else {
            return ""
        }
        return nsText.substring(with: matchRange)
    }

    static func viewText(
        sentItems: [PhotoSorterMediaViewItem],
        deniedItems: [PhotoSorterMediaViewItem],
        limitSkippedPaths: [String],
        failures: [PhotoSorterMediaViewFailure]
    ) -> String {
        var sections: [String] = []

        if !sentItems.isEmpty {
            sections.append(
                (["Sent \(sentItems.count) image(s) to model:"] + sentItems.map { "- \($0.path)" })
                    .joined(separator: "\n")
            )
        }
        if !deniedItems.isEmpty {
            sections.append(
                (["Denied by user (\(deniedItems.count)):"] + deniedItems.map { "- \($0.path)" })
                    .joined(separator: "\n")
            )
        }
        if !limitSkippedPaths.isEmpty {
            sections.append(
                (["Skipped by media view limit (\(limitSkippedPaths.count)):"] + limitSkippedPaths.map { "- \($0)" } + [
                    "Re-run `media view` with the remaining paths."
                ])
                .joined(separator: "\n")
            )
        }
        if !failures.isEmpty {
            sections.append(
                (["Failed (\(failures.count)):"] + failures.map { "- \($0.path): \($0.message)" })
                    .joined(separator: "\n")
            )
        }

        if sections.isEmpty {
            sections.append("No images sent to model.")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func askText(
        cancelled: Bool,
        requestedCount: Int,
        userNote: String,
        selectedRecords: [PhotoSorterMediaAskRecord],
        excludedRecords: [PhotoSorterMediaAskRecord],
        limitSkippedPaths: [String],
        failures: [PhotoSorterMediaViewFailure],
        reasonsByPath: [String: PhotoSorterMediaAskReason],
        writtenPathLists: [PhotoSorterMediaAskWriteResult] = []
    ) -> String {
        let shownCount = selectedRecords.count + excludedRecords.count
        var header = [
            "media ask: \(cancelled ? "cancelled" : "confirmed")",
            "requested \(requestedCount)",
            "shown \(shownCount)",
            "user note:"
        ]
        let trimmedNote = userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            header.append(trimmedNote)
        }

        var sections = [
            header.joined(separator: "\n"),
            askRecordSection(title: "selected", records: selectedRecords),
            askRecordSection(title: "excluded", records: excludedRecords)
        ]

        if !limitSkippedPaths.isEmpty {
            sections.append(
                askPathSection(
                    title: "skipped by media ask limit",
                    paths: limitSkippedPaths,
                    reasonsByPath: reasonsByPath
                )
            )
        }
        if !failures.isEmpty {
            sections.append(
                askFailureSection(failures: failures, reasonsByPath: reasonsByPath)
            )
        }
        if !writtenPathLists.isEmpty {
            sections.append(askWrittenPathListSection(writtenPathLists))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func askSkippedPaths(
        limitSkippedPaths: [String],
        failures: [PhotoSorterMediaViewFailure]
    ) -> [String] {
        limitSkippedPaths + failures.map(\.path)
    }

    static func askPathSection(
        title: String,
        paths: [String],
        reasonsByPath: [String: PhotoSorterMediaAskReason]
    ) -> String {
        guard !paths.isEmpty else {
            return "\(title) 0"
        }
        let lines = paths.flatMap { path in
            [path] + askReasonLines(for: reasonsByPath[path])
        }
        return ([ "\(title) \(paths.count)" ] + lines).joined(separator: "\n")
    }

    static func askFailureSection(
        failures: [PhotoSorterMediaViewFailure],
        reasonsByPath: [String: PhotoSorterMediaAskReason]
    ) -> String {
        guard !failures.isEmpty else {
            return "skipped 0"
        }
        let lines = failures.flatMap { failure in
            ["\(failure.path): \(failure.message)"] + askReasonLines(for: reasonsByPath[failure.path])
        }
        return ([ "skipped \(failures.count)" ] + lines).joined(separator: "\n")
    }

    static func askWrittenPathListSection(_ results: [PhotoSorterMediaAskWriteResult]) -> String {
        let lines = results.map { result in
            "\(result.label) \(result.count) -> \(result.path)"
        }
        return (["written path lists"] + lines).joined(separator: "\n")
    }

    static func askReasonLines(for reason: PhotoSorterMediaAskReason?) -> [String] {
        guard let reason else {
            return []
        }
        var lines: [String] = []
        if let title = reason.title {
            lines.append("  title: \(title)")
        }
        if let confidence = reason.confidence {
            lines.append("  confidence: \(confidence)")
        }
        if !reason.basis.isEmpty {
            lines.append("  basis: \(reason.basis.joined(separator: ", "))")
        }
        if !reason.matchedTerms.isEmpty {
            lines.append("  matched_terms: \(reason.matchedTerms.joined(separator: ", "))")
        }
        if let risk = reason.risk {
            lines.append("  risk: \(risk)")
        }
        if let detail = reason.detail {
            lines.append("  detail: \(detail)")
        }
        return lines
    }

    static func askRecordSection(
        title: String,
        records: [PhotoSorterMediaAskRecord]
    ) -> String {
        guard !records.isEmpty else {
            return "\(title) 0"
        }
        let lines = records.flatMap { record in
            [
                record.path,
                "  date: \(record.dateText)",
                "  dimensions: \(record.dimensionsText)",
                "  OCR: \(boolText(record.ocrCacheAvailable))",
                "  VLM: \(boolText(record.vlmCacheAvailable))"
            ] + askReasonLines(for: record.reason)
        }
        return ([ "\(title) \(records.count)" ] + lines).joined(separator: "\n")
    }

    static func tsvField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func boolText(_ value: Bool?) -> String {
        guard let value else {
            return "unknown"
        }
        return value ? "true" : "false"
    }

    static func jsonObjectLine(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func monthText(for date: Date?) -> String {
        guard let date else {
            return "unknown"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    static func createdText(for date: Date?) -> String {
        guard let date else {
            return "unknown"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

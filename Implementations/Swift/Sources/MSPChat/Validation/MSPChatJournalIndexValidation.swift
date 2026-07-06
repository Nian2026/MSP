import Foundation

extension MSPChatValidationRun {
    mutating func validateJournal() {
        let journalURL = packageURL.appendingPathComponent("journal.ndjson")
        guard fileManager.fileExists(atPath: journalURL.path) else {
            return
        }

        let records = parseNDJSONObjects(at: journalURL)
        for (line, object) in records {
            journalEntryCount += 1
            let hasTimelineLink = string(object["timeline_event_id"]) != nil
                || string(object["event_id"]) != nil
                || int(object["commit_seq"]) != nil
                || int(object["log_offset"]) != nil
            if !hasTimelineLink {
                error("journal-linkage", "Journal entry must link to timeline_event_id, event_id, commit_seq, or log_offset.", path: relativePath(journalURL), line: line)
            }
            if let timelineID = string(object["timeline_event_id"]), !eventIDs.contains(timelineID) {
                error("journal-missing-timeline-event", "Journal entry references an unknown timeline_event_id.", path: relativePath(journalURL), line: line)
            }
        }
    }

    mutating func validateIndexes() {
        let indexesURL = packageURL.appendingPathComponent("indexes")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: indexesURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: indexesURL, includingPropertiesForKeys: nil)
                .filter { ["json", "ndjson"].contains($0.pathExtension) }
                .sorted { $0.path < $1.path }
        } catch {
            self.error("index-list", "Could not list indexes directory: \(error.localizedDescription)", path: relativePath(indexesURL))
            return
        }

        for file in files {
            let records: [(Int, [String: Any])]
            if file.pathExtension == "ndjson" {
                records = parseNDJSONObjects(at: file)
            } else if let object = parseJSONObject(at: file) {
                records = [(1, object)]
            } else {
                records = []
            }

            for (line, object) in records {
                indexRecordCount += 1
                requireDictionaryField("source_event_range", in: object, code: "index-source-range", path: relativePath(file), line: line)
                requireStringField("source_fingerprint", in: object, code: "index-source-fingerprint", path: relativePath(file), line: line)
                requireDictionaryField("generator", in: object, code: "index-generator", path: relativePath(file), line: line)
                if object["stale_if"] == nil {
                    error("index-stale-if", "Index record requires stale_if.", path: relativePath(file), line: line)
                }
                if let range = dictionary(object["source_event_range"]) {
                    validateIndexRange(range, path: relativePath(file), line: line)
                }
            }
        }
    }

    mutating func validateIndexRange(_ range: [String: Any], path: String, line: Int) {
        guard let fromSeq = int(range["from_seq"]), let toSeq = int(range["to_seq"]) else {
            error("index-range-seq", "source_event_range requires from_seq and to_seq.", path: path, line: line)
            return
        }
        if fromSeq > toSeq {
            error("index-range-order", "source_event_range.from_seq must be <= to_seq.", path: path, line: line)
        }
        if toSeq > maxTimelineSeq {
            error("index-range-beyond-timeline", "Index source range extends beyond canonical timeline.", path: path, line: line)
        }
    }
}

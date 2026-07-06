import Foundation

extension MSPChatValidationRun {
    mutating func validateProjectionFiles() {
        let projectionsURL = packageURL.appendingPathComponent("projections")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectionsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: projectionsURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "ndjson" }
                .sorted { $0.path < $1.path }
        } catch {
            self.error("projection-list", "Could not list projections directory: \(error.localizedDescription)", path: relativePath(projectionsURL))
            return
        }

        var sawMachineProjection = false
        var sawMarkdownProjection = false

        for file in files {
            let records = parseNDJSONObjects(at: file)
            for (line, object) in records {
                projectionRecordCount += 1
                let projectionID = string(object["projection_id"])
                guard projectionID != nil else {
                    error("projection-id", "Projection record requires projection_id.", path: relativePath(file), line: line)
                    continue
                }

                guard let kind = string(object["projection_kind"]) else {
                    error("projection-kind", "Projection record requires projection_kind.", path: relativePath(file), line: line)
                    continue
                }

                if kind == "chat-read.machine" {
                    sawMachineProjection = true
                }
                if kind == "chat-read.markdown" {
                    sawMarkdownProjection = true
                }
                if !knownProjectionKinds.contains(kind) {
                    warning("unknown-projection-kind", "Unknown projection kind \"\(kind)\".", path: relativePath(file), line: line)
                }

                requireStringField("projection_format", in: object, code: "projection-format", path: relativePath(file), line: line)
                requireDictionaryField("source_event_range", in: object, code: "projection-source-range", path: relativePath(file), line: line)
                requireStringField("source_fingerprint", in: object, code: "projection-source-fingerprint", path: relativePath(file), line: line)
                requireDictionaryField("generator", in: object, code: "projection-generator", path: relativePath(file), line: line)
                requireStringField("generated_at", in: object, code: "projection-generated-at", path: relativePath(file), line: line)

                if bool(object["lossy"]) == nil || bool(object["redacted"]) == nil || bool(object["truncated"]) == nil {
                    error("projection-loss-flags", "Projection record requires boolean lossy, redacted, and truncated flags.", path: relativePath(file), line: line)
                }
                if object["stale_if"] == nil {
                    error("projection-stale-if", "Projection record requires stale_if.", path: relativePath(file), line: line)
                }

                if let range = dictionary(object["source_event_range"]) {
                    validateProjectionRange(range, path: relativePath(file), line: line)
                }

                if bool(object["truncated"]) == true, object["loss_matrix"] == nil {
                    error("projection-truncation-loss-matrix", "Truncated projection must include loss_matrix and canonical refs.", path: relativePath(file), line: line)
                }

                if bool(object["lossy"]) == true || bool(object["redacted"]) == true {
                    if object["loss_matrix"] == nil {
                        error("projection-loss-matrix", "Lossy or redacted projection records require loss_matrix.", path: relativePath(file), line: line)
                    }
                }

                if let cursor = dictionary(object["cursor"]) {
                    if string(cursor["projection_kind"]) == nil || string(cursor["scope"]) == nil || cursor["source_event_boundary"] == nil {
                        error("projection-cursor-self-description", "Projection cursor must include projection_kind, scope, and source_event_boundary.", path: relativePath(file), line: line)
                    }
                } else if object["cursor"] != nil {
                    error("projection-cursor-self-description", "Projection cursor must be self-describing object data or a complete continuation request.", path: relativePath(file), line: line)
                }

                if let syntheticItems = arrayOfDictionaries(object["synthetic_items"]) {
                    if kind == "model-context", object["call_output_balance_policy"] == nil {
                        error("projection-call-output-balance-policy", "model-context projections with synthetic_items must declare call_output_balance_policy.", path: relativePath(file), line: line)
                    }
                    for item in syntheticItems {
                        if bool(item["synthetic"]) != true || string(item["derived_from_output_event_id"]) == nil || bool(item["not_canonical"]) != true {
                            error("projection-synthetic-marker", "Synthetic model-context items must mark synthetic=true, derived_from_output_event_id, and not_canonical=true.", path: relativePath(file), line: line)
                        }
                    }
                }

                if let handle = dictionary(object["provider_continuation_handle"]) {
                    if bool(handle["invalidated"]) == true, string(handle["reason"]) == nil {
                        error("continuation-handle-invalidated-reason", "Invalidated provider continuation handles require a reason.", path: relativePath(file), line: line)
                    }
                    if string(handle["vendor"]) == nil || string(handle["runtime"]) == nil {
                        error("continuation-handle-scope", "Provider continuation handles require vendor and runtime.", path: relativePath(file), line: line)
                    }
                }
            }
        }

        if profiles.contains("projection-cache"), !files.isEmpty, !sawMachineProjection {
            error("markdown-only-projection", "projection-cache packages with materialized chat-read data must include a machine-readable projection.", path: relativePath(projectionsURL))
        }
        if sawMarkdownProjection, !sawMachineProjection {
            warning("markdown-projection-only", "Markdown projections are for humans and must not be the only machine path.", path: relativePath(projectionsURL))
        }
    }

    mutating func validateProjectionRange(_ range: [String: Any], path: String, line: Int) {
        guard let fromSeq = int(range["from_seq"]), let toSeq = int(range["to_seq"]) else {
            error("projection-range-seq", "source_event_range requires from_seq and to_seq.", path: path, line: line)
            return
        }
        if fromSeq > toSeq {
            error("projection-range-order", "source_event_range.from_seq must be <= to_seq.", path: path, line: line)
        }
        if toSeq > maxTimelineSeq {
            error("projection-range-beyond-timeline", "Projection source range extends beyond canonical timeline.", path: path, line: line)
        }
    }
}

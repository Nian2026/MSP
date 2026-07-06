import Foundation

extension MSPChatValidationRun {
    mutating func parseJSONObject(at url: URL) -> [String: Any]? {
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONSerialization.jsonObject(with: data)
            guard let object = value as? [String: Any] else {
                error("json-object", "Expected a JSON object.", path: relativePath(url))
                return nil
            }
            return object
        } catch {
            self.error("json-parse", "Could not parse JSON: \(error.localizedDescription)", path: relativePath(url))
            return nil
        }
    }

    mutating func parseNDJSONObjects(at url: URL) -> [(Int, [String: Any])] {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var output: [(Int, [String: Any])] = []
            for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
                let lineNumber = offset + 1
                var line = rawLine
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }
                guard let data = trimmed.data(using: .utf8) else {
                    error("ndjson-encoding", "Line is not valid UTF-8.", path: relativePath(url), line: lineNumber)
                    continue
                }
                do {
                    let value = try JSONSerialization.jsonObject(with: data)
                    guard let object = value as? [String: Any] else {
                        error("ndjson-object", "NDJSON line must be a JSON object.", path: relativePath(url), line: lineNumber)
                        continue
                    }
                    output.append((lineNumber, object))
                } catch {
                    self.error("ndjson-parse", "Could not parse NDJSON line: \(error.localizedDescription)", path: relativePath(url), line: lineNumber)
                }
            }
            return output
        } catch {
            self.error("ndjson-read", "Could not read NDJSON file: \(error.localizedDescription)", path: relativePath(url))
            return []
        }
    }
}

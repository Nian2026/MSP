import Foundation

actor PhotoSorterDiagnosticsLog {
    static let shared = PhotoSorterDiagnosticsLog()

    private struct Record: Encodable {
        var timestamp: String
        var event: String
        var fields: [String: String]
    }

    private static let defaultMaximumLogSizeBytes: UInt64 = 5 * 1024 * 1024

    private let url: URL
    private let rotatedURL: URL
    private let maximumLogSizeBytes: UInt64
    private let encoder: JSONEncoder
    private let timestampFormatter = ISO8601DateFormatter()

    init(
        url: URL? = nil,
        maximumLogSizeBytes: UInt64 = PhotoSorterDiagnosticsLog.defaultMaximumLogSizeBytes
    ) {
        let resolvedURL = url ?? Self.defaultLogURL()
        self.url = resolvedURL
        self.rotatedURL = resolvedURL
            .deletingPathExtension()
            .appendingPathExtension("previous.jsonl")
        self.maximumLogSizeBytes = maximumLogSizeBytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        prepareDirectoryIfNeeded()
        rotateIfNeeded()
        appendRecord(event, fields: fields)
    }

    func exportURL() throws -> URL {
        prepareDirectoryIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            appendRecord("diagnostics_log_created_for_export", fields: [:])
        }
        appendRecord("diagnostics_log_exported", fields: [:])

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photosorter-diagnostics-\(Self.exportTimestamp()).jsonl")
        if FileManager.default.fileExists(atPath: exportURL.path) {
            try FileManager.default.removeItem(at: exportURL)
        }
        try FileManager.default.copyItem(at: url, to: exportURL)
        return exportURL
    }

    private func appendRecord(_ event: String, fields: [String: String]) {
        let sanitizedEvent = sanitizedEventName(event)
        let sanitizedFields = sanitizedFields(fields)
        PhotoSorterDiagnosticsSystemLog.record(sanitizedEvent, fields: sanitizedFields)
        let record = Record(
            timestamp: timestampFormatter.string(from: Date()),
            event: sanitizedEvent,
            fields: sanitizedFields
        )
        guard let data = try? encoder.encode(record) else {
            return
        }
        append(data + Data([0x0A]))
    }

    private func append(_ data: Data) {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return
            }
            defer {
                try? handle.close()
            }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maximumLogSizeBytes else {
            return
        }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }

    private func prepareDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func sanitizedEventName(_ event: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = event.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return name.isEmpty ? "event" : name
    }

    private func sanitizedFields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return
            }
            result[key] = shouldRedactField(named: key) && !Self.isBooleanText(pair.value)
                ? "<redacted>"
                : Self.truncated(pair.value, limit: 2_000)
        }
    }

    private func shouldRedactField(named key: String) -> Bool {
        let normalized = key
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return [
            "api_key",
            "apikey",
            "authorization",
            "access_token",
            "refresh_token",
            "id_token",
            "token",
            "secret",
            "password",
            "bearer"
        ].contains { normalized.contains($0) }
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return "\(value.prefix(limit))…[truncated \(value.count - limit) chars]"
    }

    private static func isBooleanText(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "true" || normalized == "false"
    }

    private static func defaultLogURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("PhotoSorter", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("photosorter-diagnostics.jsonl")
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

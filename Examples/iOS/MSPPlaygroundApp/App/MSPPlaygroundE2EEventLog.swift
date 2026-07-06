import Foundation

struct MSPPlaygroundE2EEventLog {
    private struct Record: Encodable {
        var timestamp: String
        var event: String
        var fields: [String: String]
    }

    private let url: URL
    private let encoder: JSONEncoder

    static func configured(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MSPPlaygroundE2EEventLog? {
        let enabled = arguments.contains("--msp-e2e-log-events")
            || environment["MSP_PLAYGROUND_E2E_LOG_EVENTS"] == "1"
        guard enabled else {
            return nil
        }

        let url: URL
        if let rawPath = environment["MSP_PLAYGROUND_E2E_EVENT_LOG_PATH"],
           !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            url = URL(fileURLWithPath: rawPath)
        } else {
            let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            url = directory.appendingPathComponent("msp-playground-e2e-events.jsonl")
        }

        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: url)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return MSPPlaygroundE2EEventLog(url: url, encoder: encoder)
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        let record = Record(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            event: event,
            fields: fields
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
}

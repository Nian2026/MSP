public enum MSPChatDiagnosticSeverity: String, Codable, Equatable {
    case error
    case warning
    case note
}

public struct MSPChatDiagnostic: Codable, Equatable {
    public var severity: MSPChatDiagnosticSeverity
    public var code: String
    public var message: String
    public var path: String
    public var line: Int?
    public var eventID: String?

    public init(
        severity: MSPChatDiagnosticSeverity,
        code: String,
        message: String,
        path: String,
        line: Int? = nil,
        eventID: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
        self.line = line
        self.eventID = eventID
    }
}

public struct MSPChatValidationReport: Codable, Equatable {
    public var packagePath: String
    public var validatorVersion: String
    public var checkedProfiles: [String]
    public var checkedCapabilities: [String]
    public var timelineEventCount: Int
    public var projectionRecordCount: Int
    public var journalEntryCount: Int
    public var indexRecordCount: Int
    public var diagnostics: [MSPChatDiagnostic]

    public var isValid: Bool {
        !diagnostics.contains { $0.severity == .error }
    }

    public var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    public var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }

    public func renderedText() -> String {
        var lines: [String] = []
        lines.append("MSP .chat validation report")
        lines.append("package: \(packagePath)")
        lines.append("validator: \(validatorVersion)")
        lines.append("status: \(isValid ? "pass" : "fail")")
        lines.append("profiles: \(checkedProfiles.isEmpty ? "-" : checkedProfiles.joined(separator: ", "))")
        lines.append("capabilities: \(checkedCapabilities.isEmpty ? "-" : checkedCapabilities.joined(separator: ", "))")
        lines.append("timeline_events: \(timelineEventCount)")
        lines.append("projection_records: \(projectionRecordCount)")
        lines.append("journal_entries: \(journalEntryCount)")
        lines.append("index_records: \(indexRecordCount)")
        lines.append("errors: \(errorCount)")
        lines.append("warnings: \(warningCount)")

        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("diagnostics:")
            for diagnostic in diagnostics {
                var location = diagnostic.path
                if let line = diagnostic.line {
                    location += ":\(line)"
                }
                if let eventID = diagnostic.eventID {
                    location += " [\(eventID)]"
                }
                lines.append("- \(diagnostic.severity.rawValue.uppercased()) \(diagnostic.code) \(location): \(diagnostic.message)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

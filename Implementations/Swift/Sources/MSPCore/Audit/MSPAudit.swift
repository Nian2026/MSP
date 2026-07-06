import Foundation

public struct MSPCommandRunRecord: Sendable, Equatable {
    public var id: UUID
    public var commandLine: String
    public var commandName: String?
    public var arguments: [String]
    public var exitCode: Int32
    public var startedAt: Date
    public var endedAt: Date

    public init(
        id: UUID = UUID(),
        commandLine: String,
        commandName: String?,
        arguments: [String],
        exitCode: Int32,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = id
        self.commandLine = commandLine
        self.commandName = commandName
        self.arguments = arguments
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public protocol MSPAuditSink: Sendable {
    func record(_ run: MSPCommandRunRecord) async
}

public struct MSPNoopAuditSink: MSPAuditSink {
    public init() {}

    public func record(_ run: MSPCommandRunRecord) async {}
}

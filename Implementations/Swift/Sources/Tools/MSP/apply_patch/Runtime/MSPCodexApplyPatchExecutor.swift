import Foundation

public protocol MSPCodexApplyPatchBridge: Sendable {
    func applyPatch(requestJSON: String) async throws -> String
}

public struct MSPCodexApplyPatchBridgeRequest: Codable, Hashable, Sendable {
    public var patch: String
    public var cwd: String
    public var workspaceRoot: String
    public var hostPathRedactions: [String]

    public init(
        patch: String,
        cwd: String,
        workspaceRoot: String,
        hostPathRedactions: [String] = []
    ) {
        self.patch = patch
        self.cwd = cwd
        self.workspaceRoot = workspaceRoot
        self.hostPathRedactions = hostPathRedactions
    }
}

public struct MSPCodexApplyPatchBridgeResponse: Codable, Hashable, Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var output: String
    public var changedPaths: [String]
    public var exactDelta: Bool
    public var turnDiff: String?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var changes: [MSPCodexApplyPatchChangeRecord]?
    public var fileSnapshots: [MSPCodexApplyPatchFileSnapshot]?
    public var error: String?

    public init(
        exitCode: Int,
        stdout: String,
        stderr: String,
        output: String,
        changedPaths: [String],
        exactDelta: Bool,
        turnDiff: String? = nil,
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        changes: [MSPCodexApplyPatchChangeRecord]? = nil,
        fileSnapshots: [MSPCodexApplyPatchFileSnapshot]? = nil,
        error: String? = nil
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.output = output
        self.changedPaths = changedPaths
        self.exactDelta = exactDelta
        self.turnDiff = turnDiff
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.changes = changes
        self.fileSnapshots = fileSnapshots
        self.error = error
    }
}

public struct MSPCodexApplyPatchChangeRecord: Codable, Hashable, Sendable {
    public var path: String
    public var kind: String
    public var movePath: String?

    public init(path: String, kind: String, movePath: String? = nil) {
        self.path = path
        self.kind = kind
        self.movePath = movePath
    }
}

public struct MSPCodexApplyPatchFileSnapshot: Codable, Hashable, Sendable {
    public var path: String
    public var existedBefore: Bool
    public var existsAfter: Bool
    public var beforeText: String?
    public var afterText: String?

    public init(
        path: String,
        existedBefore: Bool,
        existsAfter: Bool,
        beforeText: String? = nil,
        afterText: String? = nil
    ) {
        self.path = path
        self.existedBefore = existedBefore
        self.existsAfter = existsAfter
        self.beforeText = beforeText
        self.afterText = afterText
    }
}

public struct MSPCodexApplyPatchExecutor: MSPApplyPatchExecuting {
    public var bridge: any MSPCodexApplyPatchBridge
    public var workspaceRoot: String
    public var cwd: String
    public var hostPathRedactions: [String]

    public init(
        bridge: any MSPCodexApplyPatchBridge,
        workspaceRoot: String,
        cwd: String = "/",
        hostPathRedactions: [String] = []
    ) {
        self.bridge = bridge
        self.workspaceRoot = workspaceRoot
        self.cwd = cwd
        self.hostPathRedactions = hostPathRedactions
    }

    public func execute(_ call: MSPApplyPatchCall) async -> MSPApplyPatchExecutionResult {
        let request = MSPCodexApplyPatchBridgeRequest(
            patch: call.patch,
            cwd: call.cwd ?? cwd,
            workspaceRoot: workspaceRoot,
            hostPathRedactions: hostPathRedactions
        )
        do {
            let requestData = try JSONEncoder().encode(request)
            guard let requestJSON = String(data: requestData, encoding: .utf8) else {
                return Self.failure("apply_patch bridge request is not valid UTF-8")
            }
            let responseJSON = try await bridge.applyPatch(requestJSON: requestJSON)
            guard let responseData = responseJSON.data(using: .utf8) else {
                return Self.failure("apply_patch bridge response is not valid UTF-8")
            }
            let response = try JSONDecoder().decode(MSPCodexApplyPatchBridgeResponse.self, from: responseData)
            let errorMessage = response.error?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MSPApplyPatchExecutionResult(
                ok: response.exitCode == 0,
                output: response.output,
                changedPaths: response.changedPaths,
                exactDelta: response.exactDelta,
                internalContent: .object(Self.internalContent(from: response)),
                errorMessage: errorMessage?.isEmpty == false ? errorMessage : nil
            )
        } catch {
            return Self.failure("apply_patch bridge failed: \(error.localizedDescription)")
        }
    }

    private static func failure(_ message: String) -> MSPApplyPatchExecutionResult {
        MSPApplyPatchExecutionResult(
            ok: false,
            output: message,
            errorMessage: message
        )
    }

    private static func internalContent(
        from response: MSPCodexApplyPatchBridgeResponse
    ) -> [String: MSPAgentJSONValue] {
        var content: [String: MSPAgentJSONValue] = [
            "exit_code": .number(Double(response.exitCode)),
            "stdout": .string(response.stdout),
            "stderr": .string(response.stderr)
        ]
        if let turnDiff = response.turnDiff {
            content["turn_diff"] = .string(turnDiff)
            content["diff"] = .string(turnDiff)
        }
        if let linesAdded = response.linesAdded {
            content["lines_added"] = .number(Double(linesAdded))
        }
        if let linesRemoved = response.linesRemoved {
            content["lines_removed"] = .number(Double(linesRemoved))
        }
        let changes = response.changes ?? []
        if !changes.isEmpty {
            content["changes"] = .array(changes.map(Self.changeRecordJSONValue))
        }
        let fileSnapshots = response.fileSnapshots ?? []
        if !fileSnapshots.isEmpty {
            content["file_snapshots"] = .array(fileSnapshots.map(Self.fileSnapshotJSONValue))
        }
        return content
    }

    private static func changeRecordJSONValue(
        _ record: MSPCodexApplyPatchChangeRecord
    ) -> MSPAgentJSONValue {
        var object: [String: MSPAgentJSONValue] = [
            "path": .string(record.path),
            "kind": .string(record.kind)
        ]
        if let movePath = record.movePath {
            object["move_path"] = .string(movePath)
        }
        return .object(object)
    }

    private static func fileSnapshotJSONValue(
        _ snapshot: MSPCodexApplyPatchFileSnapshot
    ) -> MSPAgentJSONValue {
        var object: [String: MSPAgentJSONValue] = [
            "path": .string(snapshot.path),
            "existed_before": .bool(snapshot.existedBefore),
            "exists_after": .bool(snapshot.existsAfter)
        ]
        if let beforeText = snapshot.beforeText {
            object["before_text"] = .string(beforeText)
        }
        if let afterText = snapshot.afterText {
            object["after_text"] = .string(afterText)
        }
        return .object(object)
    }
}

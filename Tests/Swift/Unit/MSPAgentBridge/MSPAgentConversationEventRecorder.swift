import Foundation
@testable import MSPAgentBridge
import MSPCore
import XCTest


actor RecordedAgentEvents {
    private var events: [MSPAgentEvent] = []

    func append(_ event: MSPAgentEvent) {
        events.append(event)
    }

    func toolSignatures() -> [String] {
        events.compactMap { event in
            switch event {
            case .toolStarted(let call, _, _):
                return "toolStarted:\(call.id)"
            case .toolOutputDelta(let callID, _, let stream, let text):
                return "toolOutputDelta:\(callID):\(stream.rawValue):\(text)"
            case .toolCompleted(let result, _):
                return "toolCompleted:\(result.callID):\(result.ok)"
            case .compactTurnStarted,
                 .turnStarted,
                 .turnAborted,
                 .contextCompactionStarted,
                 .contextCompactionCompleted,
                 .contextCompactionFailed,
                 .compactionWarning,
                 .modelRequestPreparing,
                 .assistantProgressSegmentStarted,
                 .assistantProgressDelta,
                 .assistantProgress,
                 .toolPreparing,
                 .finalAnswerStarted,
                 .finalAnswerDelta,
                 .finalAnswer,
                 .modelStreamRetrying,
                 .turnSteerAccepted,
                 .turnSteerApplied,
                 .threadGoalUpdated,
                 .threadGoalCleared,
                 .threadGoalAccounted,
                 .planProgressUpdated,
                 .contextUsageUpdated,
                 .planModeProposalDelta,
                 .planModeProposed,
                 .planModeApproved,
                 .planModeRejected,
                 .planModeModified,
                 .planModeHandoff,
                 .probe:
                return nil
            }
        }
    }

    func compactionLifecycle() -> (
        compactTurnStartedCount: Int,
        startedContextCompactionID: String?,
        completedContextCompactionID: String?,
        failedContextCompactionID: String?,
        failedMessage: String?,
        warningCount: Int
    ) {
        var compactTurnStartedCount = 0
        var startedContextCompactionID: String?
        var completedContextCompactionID: String?
        var failedContextCompactionID: String?
        var failedMessage: String?
        var warningCount = 0
        for event in events {
            switch event {
            case .compactTurnStarted:
                compactTurnStartedCount += 1
            case .contextCompactionStarted(let id):
                startedContextCompactionID = id
            case .contextCompactionCompleted(let id):
                completedContextCompactionID = id
            case .contextCompactionFailed(let id, message: let message):
                failedContextCompactionID = id
                failedMessage = message
            case .compactionWarning:
                warningCount += 1
            case .assistantProgressSegmentStarted,
                 .modelRequestPreparing,
                 .turnStarted,
                 .turnAborted,
                 .assistantProgressDelta,
                 .assistantProgress,
                 .toolPreparing,
                 .toolStarted,
                 .toolOutputDelta,
                 .toolCompleted,
                 .finalAnswerStarted,
                 .finalAnswerDelta,
                 .finalAnswer,
                 .modelStreamRetrying,
                 .turnSteerAccepted,
                 .turnSteerApplied,
                 .threadGoalUpdated,
                 .threadGoalCleared,
                 .threadGoalAccounted,
                 .planProgressUpdated,
                 .contextUsageUpdated,
                 .planModeProposalDelta,
                 .planModeProposed,
                 .planModeApproved,
                 .planModeRejected,
                 .planModeModified,
                 .planModeHandoff,
                 .probe:
                break
            }
        }
        return (
            compactTurnStartedCount,
            startedContextCompactionID,
            completedContextCompactionID,
            failedContextCompactionID,
            failedMessage,
            warningCount
        )
    }

    func turnLifecycleSignatures() -> [String] {
        events.compactMap { event in
            switch event {
            case .turnStarted(let event):
                return "turnStarted:\(event.turnID)"
            case .turnAborted(let event):
                return [
                    "turnAborted",
                    event.turnID ?? "",
                    event.reason.rawValue
                ].joined(separator: ":")
            case .compactTurnStarted,
                 .contextCompactionStarted,
                 .contextCompactionCompleted,
                 .contextCompactionFailed,
                 .compactionWarning,
                 .modelRequestPreparing,
                 .assistantProgressSegmentStarted,
                 .assistantProgressDelta,
                 .assistantProgress,
                 .toolPreparing,
                 .toolStarted,
                 .toolOutputDelta,
                 .toolCompleted,
                 .finalAnswerStarted,
                 .finalAnswerDelta,
                 .finalAnswer,
                 .modelStreamRetrying,
                 .turnSteerAccepted,
                 .turnSteerApplied,
                 .threadGoalUpdated,
                 .threadGoalCleared,
                 .threadGoalAccounted,
                 .planProgressUpdated,
                 .contextUsageUpdated,
                 .planModeProposalDelta,
                 .planModeProposed,
                 .planModeApproved,
                 .planModeRejected,
                 .planModeModified,
                 .planModeHandoff,
                 .probe:
                return nil
            }
        }
    }

    func lastContextUsage() -> MSPAgentContextUsageRecord? {
        events.compactMap { event in
            if case let .contextUsageUpdated(usage) = event {
                return usage
            }
            return nil
        }.last
    }

    func probeFields(named name: String) -> [[String: String]] {
        events.compactMap { event in
            guard case let .probe(probe) = event,
                  probe.name == name else {
                return nil
            }
            return probe.fields
        }
    }
}

actor RecordedCommands {
    private var commands: [String] = []

    func append(_ command: String) {
        commands.append(command)
    }

    func all() -> [String] {
        commands
    }
}

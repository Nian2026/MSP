import Foundation

enum MSPPlanProgressRuntime {
    static func executeTool(
        _ call: MSPAgentToolCall,
        capability: MSPPlanProgressCapability,
        threadID: String,
        turnID: UUID,
        planModeActive: Bool
    ) -> MSPPlanProgressToolExecutionOutcome? {
        guard call.name == .updatePlan else {
            return nil
        }
        guard capability.toolsVisible else {
            return nil
        }
        guard !planModeActive else {
            let message = "update_plan is a TODO/checklist tool and is not allowed in Plan mode"
            return MSPPlanProgressToolExecutionOutcome(
                result: MSPUpdatePlanRuntime.modelToolError(call: call, message: message),
                event: nil
            )
        }

        do {
            let update = try MSPUpdatePlanRuntime.parseArguments(
                rawArguments: call.rawArguments,
                decodedArguments: call.arguments
            )
            let event = MSPPlanProgressUpdatedEvent(
                eventID: "\(turnID.uuidString):plan-update:\(call.id)",
                threadID: threadID,
                turnID: turnID.uuidString,
                explanation: update.explanation,
                plan: update.plan
            )
            return MSPPlanProgressToolExecutionOutcome(
                result: MSPUpdatePlanRuntime.modelToolResult(call: call),
                event: event
            )
        } catch {
            return MSPPlanProgressToolExecutionOutcome(
                result: MSPUpdatePlanRuntime.modelToolError(
                    call: call,
                    message: "\(error)"
                ),
                event: nil
            )
        }
    }
}

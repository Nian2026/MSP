import MSPCore

enum ShellPipelineStatus {
    static func statusValues(_ stageExitCodes: [Int32]) -> [String] {
        stageExitCodes.map { String($0) }
    }

    static func environmentValue(from statusValues: [String]) -> String {
        statusValues.first ?? "0"
    }

    static func exitCode(
        _ stageExitCodes: [Int32],
        pipefailEnabled: Bool
    ) -> Int32 {
        guard pipefailEnabled else {
            return stageExitCodes.last ?? 0
        }
        return stageExitCodes.reversed().first { $0 != 0 } ?? 0
    }

    static func result(
        _ result: MSPCommandResult,
        isNegated: Bool
    ) -> MSPCommandResult {
        guard isNegated else {
            return result
        }
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderrData: result.stderrData,
            exitCode: result.exitCode == 0 ? 1 : 0,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }
}

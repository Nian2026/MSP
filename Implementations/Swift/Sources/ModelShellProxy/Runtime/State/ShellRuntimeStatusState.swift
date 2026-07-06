import MSPShell

extension ShellRuntime {
    func clearBashRematch() {
        state.shellArrays["BASH_REMATCH"] = MSPShellIndexedArray()
        configuration.environment["BASH_REMATCH"] = ""
    }

    func setBashRematch(_ array: MSPShellIndexedArray) {
        state.shellArrays["BASH_REMATCH"] = array
        state.shellAssociativeArrays.removeValue(forKey: "BASH_REMATCH")
        state.shellNamerefs.removeValue(forKey: "BASH_REMATCH")
        configuration.environment["BASH_REMATCH"] = array.first ?? ""
    }

    func updatePipelineStatuses(_ stageExitCodes: [Int32]) {
        let statusValues = ShellPipelineStatus.statusValues(stageExitCodes)
        state.shellArrays["PIPESTATUS"] = MSPShellIndexedArray(statusValues)
        state.shellAssociativeArrays.removeValue(forKey: "PIPESTATUS")
        state.shellNamerefs.removeValue(forKey: "PIPESTATUS")
        configuration.environment["PIPESTATUS"] = ShellPipelineStatus.environmentValue(from: statusValues)
    }

    func pipelineExitCode(_ stageExitCodes: [Int32]) -> Int32 {
        ShellPipelineStatus.exitCode(stageExitCodes, pipefailEnabled: state.isPipefailEnabled)
    }
}

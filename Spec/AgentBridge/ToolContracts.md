# AgentBridge Tool Contracts

AgentBridge exposes a small model-facing tool surface while preserving richer
runtime state internally.

Current code evidence:

- `Implementations/Swift/Sources/Tools/MSP/exec_command/Contract/MSPExecCommandToolSchema.swift`
  defines the `exec_command` schema.
- `Implementations/Swift/Sources/Tools/MSP/write_stdin/Contract/MSPWriteStdinToolSchema.swift`
  defines the `write_stdin` schema.
- `Implementations/Swift/Sources/Tools/MSP/apply_patch/Contract/MSPApplyPatchToolSchema.swift`
  defines the freeform `apply_patch` schema.
- `Implementations/Swift/Sources/Tools/MSP/update_plan/Contract/MSPUpdatePlanToolSchema.swift`
  defines the `update_plan` schema.
- `Implementations/Swift/Sources/MSPAgentBridge/Model/MSPAgentRuntimeTypes.swift`
  maps model-visible tool names to runtime types.
- `Tests/Swift/Unit/MSPAgentBridge/MSPExecCommandBridgeTests.swift`,
  `MSPApplyPatchToolTests.swift`, and `MSPUpdatePlanToolTests.swift` verify the
  current tool contract boundaries.

The core rule is that model-visible command output remains shell text. The
bridge may keep structured command data internally for SDK users, UI, audit,
diagnostics, and tests, but it should not wrap ordinary command output in a
model-visible JSON envelope.

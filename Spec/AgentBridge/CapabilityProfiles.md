# AgentBridge Capability Profiles

AgentBridge capabilities are optional runtime features that an SDK integrator
can enable independently of the base command bridge.

Current code evidence:

- `Implementations/Swift/Sources/MSPAgentBridge/Capabilities/PlanProgress/`
  owns the optional `update_plan` capability.
- `Implementations/Swift/Sources/MSPAgentBridge/Capabilities/Goal/` owns goal
  creation, status, accounting, and continuation behavior.
- `Implementations/Swift/Sources/MSPAgentBridge/Capabilities/PlanMode/` owns
  plan-mode request and state behavior.
- `Implementations/Swift/Sources/MSPAgentBridge/Capabilities/TurnInterrupt/`
  owns turn interruption.
- `Implementations/Swift/Sources/MSPAgentBridge/Capabilities/TurnSteer/` owns
  turn steering.
- `Tests/Swift/Unit/MSPAgentBridge/` contains focused tests for each capability
  being enabled, disabled, declared, and rejected when unavailable.

This folder should document which capabilities affect the model-visible tool
list, which are SDK-only control APIs, and which require persisted conversation
state.

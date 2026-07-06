# MSPPlayground Agent Layer

This is the iOS playground app's adapter layer around the public
`MSPAgentBridge` SDK.

The stateful model/tool loop now lives in `MSPAgentBridge`. This folder keeps
app-specific concerns close to the demo: model settings, OAuth/API-key
resolution, UI timeline projection, and iOS workspace wiring.

The app proves the full loop in a real iOS shape:

user message -> `MSPAgentConversation` -> request body -> model stream -> tool
call -> MSP shell -> plain-text tool result -> continued model stream ->
transcript timeline.

## Folders

- `ModelConfig`: provider, model, base URL, API key, reasoning, and verbosity.
- `ToolLoop`: demo adapter that owns one `MSPAgentConversation` per resolved
  model/credential signature.
- `Transcript`: timeline records for intermediate text, processed tool calls,
  tool results, and final assistant output.

## SDK Boundary

Keep generic agent-loop behavior in `MSPAgentBridge`. Keep iOS product behavior
in this example app. A change belongs in the SDK when any MSP app developer
would need it to preserve conversation context, request-body construction, model
stream parsing, or `exec_command` tool-loop semantics.

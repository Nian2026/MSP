# PhotoSorter Agent Layer

This is PhotoSorter's adapter layer around the public `MSPAgentBridge` SDK.

The stateful model/tool loop lives in `MSPAgentBridge`. This folder keeps
PhotoSorter-specific concerns close to the app: model settings, OAuth/API-key
resolution, UI timeline projection, photo-library access policy, media command
wiring, and the workspace mount that exposes gallery content as MSP paths.

PhotoSorter proves the full loop in a real iOS media workflow:

user message -> `MSPAgentConversation` -> request body -> model stream -> tool
call -> MSP shell/media command -> plain-text tool result -> continued model
stream -> transcript timeline.

## Folders

- `ModelConfig`: provider, model, base URL, API key, reasoning, and verbosity.
- `ToolLoop`: demo adapter that owns one `MSPAgentConversation` per resolved
  model/credential signature.
- `Transcript`: timeline records for intermediate text, processed tool calls,
  tool results, and final assistant output.

## SDK Boundary

Keep generic agent-loop behavior in `MSPAgentBridge`. Keep PhotoSorter product
behavior in this example app. A change belongs in the SDK when any MSP app
developer would need it to preserve conversation context, request-body
construction, model stream parsing, or `exec_command` tool-loop semantics.

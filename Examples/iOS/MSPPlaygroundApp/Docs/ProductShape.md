# Product Shape

## Primary Surface

The app opens directly into a ChatGPT-style conversation surface. There is no
landing page and no separate terminal-first screen.

The transcript is ordered by actual runtime time:

1. user message
2. assistant intermediate text
3. processed tool call block
4. tool result
5. assistant intermediate text
6. another processed tool call block if needed
7. final assistant answer

The composer accepts natural-language chat messages only. Shell commands are
never entered by the user-facing composer; commands are produced by the agent
loop and executed through the internal `exec_command` bridge.

## Workspace Drawer

The workspace filesystem is a full-screen surface hidden on the left side of
the conversation.

The gesture is:

```text
drag right from the left edge -> pull out the workspace
drag left on the workspace    -> hide the workspace
```

This is not a tab, not a navigation push, and not a command button in the
composer. The user pulls the workspace into view with the gesture and hides it
with the opposite gesture.

The workspace shows the MSP workspace root `/`, not host sandbox paths.

## Visual System

When the UI implementation starts, it should use Apple's official iOS 26 Liquid
Glass APIs. Do not approximate Liquid Glass with custom blur or translucent
cards unless the official API is unavailable in the local toolchain and the
fallback is explicitly marked as temporary.

## First Runnable Milestone

- create a sandbox workspace
- initialize `ModelShellProxy.iOS(workspaceURL:)`
- enable `.posixCore`
- send natural-language chat messages from the composer
- let the local agent layer call `exec_command` internally when workspace
  inspection is needed
- display model progress, tool calls, processed tool results, and final answers
  in transcript order
- pull out the full-screen workspace with a right drag
- show file changes caused by shell commands

## Second Milestone

- model configuration
- request body construction
- streaming parser
- `exec_command` tool-call loop
- processed tool-call timeline blocks
- final assistant answer

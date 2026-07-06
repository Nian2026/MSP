# Product Shape

## Primary Surface

PhotoSorter opens directly into a conversation surface backed by an MSP photo
workspace. There is no landing page and no separate terminal-first screen.

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
loop and executed through the internal `exec_command` bridge or PhotoSorter
media commands.

## Workspace Drawer

The workspace filesystem is a full-screen surface hidden on the left side of the
conversation. It shows MSP paths for the app workspace plus Photos-backed
virtual trees such as `/图库` and `/相册`.

The gesture is:

```text
drag right from the left edge -> pull out the workspace
drag left on the workspace    -> hide the workspace
```

This is not a tab, not a navigation push, and not a command button in the
composer. The user pulls the workspace into view with the gesture and hides it
with the opposite gesture.

The workspace shows MSP paths, not host sandbox paths or Photos framework
identifiers. Photo assets are exposed as safe virtual references so the agent can
inspect, sort, and explain media state without receiving raw device filesystem
access.

## Visual System

When the UI implementation starts, it should use Apple's official iOS 26 Liquid
Glass APIs. Do not approximate Liquid Glass with custom blur or translucent
cards unless the official API is unavailable in the local toolchain and the
fallback is explicitly marked as temporary.

## First Runnable Milestone

- create a sandbox workspace
- initialize `ModelShellProxy.iOS(workspaceURL:)`
- enable `.posixCore`
- mount the photo library as MSP workspace paths
- send natural-language chat messages from the composer
- let the local agent layer call `exec_command` internally when workspace
  inspection is needed
- display model progress, tool calls, processed tool results, and final answers
  in transcript order
- pull out the full-screen workspace with a right drag
- show file and photo-library view changes caused by commands

## Second Milestone

- model configuration
- request body construction
- streaming parser
- `exec_command` tool-call loop
- PhotoSorter media command loop
- processed tool-call timeline blocks
- final assistant answer

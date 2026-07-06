# Swift Agent Bridge

`MSPAgentBridge` is the SDK layer that connects a model turn loop to a
Model Shell Protocol command surface.

It has one job: keep the agent-facing interface simple while keeping the app
runtime structured and auditable.

## Shape

The model sees one command tool:

```text
exec_command({ "cmd": "ls -la /" })
```

The tool result sent back to the model is plain terminal text. It is not wrapped
as `stdout`, `stderr`, or `exit_code` JSON. SDK users can still keep those
structured fields internally through `MSPCommandResult`, audit sinks, and tests.

The model-visible prompt should describe the workspace behavior, not the SDK
architecture. It should say that the model is working in a Linux-like workspace
with `/` as the visible root; it should not explain MSP, host sandboxes, or app
internals.

## Minimal iOS Setup

```swift
import Foundation
import ModelShellProxy

let workspaceURL = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Workspace", isDirectory: true)

try FileManager.default.createDirectory(
    at: workspaceURL,
    withIntermediateDirectories: true
)

let shell = try ModelShellProxy
    .iOS(workspaceURL: workspaceURL)
    .enable(.posixCore)

let runtime = MSPAgentRuntime(
    modelConfiguration: MSPAgentModelConfiguration(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        apiKey: apiKey,
        model: "gpt-5"
    ),
    execCommandBridge: shell.execCommandBridge()
)

let conversation = runtime.makeConversation(
    configuration: MSPAgentConversationConfiguration(
        model: "gpt-5"
    )
)

let result = try await conversation.send("Show me the files in the workspace.")
```

`MSPAgentConversation` is stateful. Keep the same conversation instance for a
thread if the model should remember earlier user messages, intermediate
assistant messages, tool calls, tool outputs, and final answers.

## Custom App Commands

Apps can expose domain actions as shell commands without changing the model
tool schema:

```swift
try shell.register("pdf_extract", summary: "Extract text from a PDF") { context, arguments in
    guard let inputPath = arguments.first else {
        return .failure(exitCode: 2, stderr: "pdf_extract: missing input path\n")
    }

    // Resolve and authorize paths through the workspace before reading files.
    guard let workspace = context.workspace else {
        return .failure(exitCode: 125, stderr: "pdf_extract: workspace unavailable\n")
    }

    let data = try workspace.fileSystem.readFile(
        inputPath,
        from: context.currentDirectory
    )
    let text = extractPDFText(from: data)
    return .success(stdout: text)
}
```

From the model's point of view this is still just:

```text
exec_command({ "cmd": "pdf_extract /docs/report.pdf" })
```

That keeps the agent interface stable while letting each app define its own
capabilities.

## External Commands

MSP does not bundle third-party binaries such as `git` or `yt-dlp`. Apps provide
the runner and policy:

```swift
struct GitRunner: MSPExternalCommandRunner {
    func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        // Launch the app-provided git binary, apply policy, capture stdout,
        // stderr, exit code, and return MSPCommandResult.
    }
}

try shell.registerExternalCommand(
    "git",
    summary: "Run the app-provided git binary",
    runner: GitRunner()
)
```

## Request Continuity Contract

For each conversation, SDK requests must preserve model-visible history in
strict order:

```text
developer context
user message 1
assistant intermediate message
function_call
function_call_output
assistant final answer
user message 2
...
```

The SDK must not silently summarize, drop, or reorder earlier turns. If a future
implementation adds compaction, it needs an explicit policy and request-capture
tests proving the new model-visible order.

## Test Gate

The Swift test suite captures the actual HTTP request body emitted by
`MSPResponsesStreamingModelClient`. These tests are the compatibility gate for:

- multi-turn context continuity
- tool call and tool output ordering
- plain-text `exec_command` output
- failed command output
- tool budget exhaustion

Run:

```bash
swift test --filter MSPAgentBridgeTests
```

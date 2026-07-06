# Tests

MSP keeps tests outside platform implementation folders so the shared standard
and each runtime can grow without becoming one large test target.

Layout:

- `Swift/Unit`: narrow Swift module tests. Each target should depend only on
  the module under test and the smallest support modules it needs.
- `Swift/Integration`: cross-module Swift runtime tests. These may depend on
  the public `ModelShellProxy` facade.
- `Swift/Fixtures`: Swift-only reusable fixtures.
- `Swift/Golden`: Swift implementation golden outputs.
- `SpecConformance`: cross-platform fixtures and expected behavior for future
  MSP implementations.

Rule of thumb: if a test needs the full public facade, it belongs in
`Swift/Integration`; if it checks the MSP standard rather than one Swift module,
it belongs in `SpecConformance`.

Within a Swift target, keep files grouped by responsibility:

- `AgentContract`: model-visible input/output contracts such as `exec_command`
  plain-text behavior.
- `ShellLanguage`: parser, expansion, shell state, and script execution.
- `Pipelines` and `Redirection`: shared shell runtime composition behavior.
- `WorkspaceFS`: virtual-root path and filesystem parity behavior.
- `Conformance`: byte-level oracle runners and fixture safety checks.
- `Performance`: streaming, cancellation, early-close, and large-input tests.

Do not hide oracle, stress, or performance tests inside broad smoke files. MSP
is a shell standard; its tests are part of the standard surface.

`Swift/Unit/MSPAgentBridge` includes request-capture tests that inspect the real
HTTP body emitted by the streaming model client. Those tests are the guardrail
for model-visible timeline order across user messages, assistant intermediate
messages, tool calls, tool outputs, and final answers.

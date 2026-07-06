# MSP Spec

`Spec/` is the public contract layer for MSP. It should describe portable
runtime behavior and conformance boundaries, not local build artifacts or
product-private implementation notes.

The current root folders are evidence-backed by the Swift implementation,
examples, tests, or conformance fixtures:

- `AgentBridge/`: model-facing agent tools and optional agent capabilities.
- `Audit/`: audit records, sinks, diagnostics, and execution evidence.
- `Chat/`: Draft 0 `.chat` conversation package standard.
- `Commands/`: command protocol, command registry, command packs, and command
  conformance expectations.
- `Extensions/`: app-defined command packs that extend the same shell-like
  runtime as the core commands.
- `ExternalRunners/`: boundary for optional host or external process runners.
- `Profiles/`: named compatibility and release profiles.
- `Security/`: policy, workspace path rules, hidden-path behavior, and output
  sanitization.
- `WorkspaceFS/`: virtual workspace filesystem contract.

Source code belongs under `Implementations/`. Executable checks and retained
evidence belong under `Conformance/` and `Tests/`. Product-specific demos belong
under `Examples/`. Local construction and source-reading notes stay outside the
publishable spec surface unless they are promoted into product-neutral public
contract or conformance documentation.

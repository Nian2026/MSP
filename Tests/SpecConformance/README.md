# Spec Conformance

This folder is reserved for cross-platform MSP conformance assets. Use it for
spec-level fixtures and audit artifacts that should apply to Swift, future
Android, future Windows, and other implementations.

Keep Swift-only XCTest code under `Tests/Swift`. Keep captured Linux evidence,
VPS oracle fixtures, and capture scripts under `Conformance`.

Intended subdomains:

- `ExecCommandProfile`: agent-facing tool input/output contracts.
- `ShellParser`: shell grammar and executable-command extraction fixtures.
- `WorkspaceFS`: workspace root, path policy, and virtual path expectations.
- `POSIXCore`: command and option conformance expectations.
- `Policy`: permission, audit, and safety policy expectations.
- `Audit`: generated compatibility and coverage reports.

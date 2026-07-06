# MSP Audit

This directory is for execution evidence: audit records, diagnostic records,
and the public expectations for what an MSP runtime can retain after command
execution.

Current code evidence:

- `Implementations/Swift/Sources/MSPCore/Audit/MSPAudit.swift` defines audit
  records and audit sinks.
- `Implementations/Swift/Sources/ModelShellProxy/Runtime/Execution/ShellExecutionDiagnostics.swift`
  records shell execution diagnostics.
- `Tests/Swift/Integration/ModelShellProxy/Pipelines/ModelShellProxyPipelineTests.swift`
  uses pipeline audit capture to verify execution evidence.

Audit is a first-class part of MSP: execution should leave records that humans,
tests, and future agents can inspect.

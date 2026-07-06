# MSP Security

This directory is for the public security and policy contract: command
authorization, workspace visibility, hidden paths, output sanitization, and
safe virtual-path behavior.

Current code evidence:

- `Implementations/Swift/Sources/MSPCore/Policy/MSPPolicy.swift` defines policy
  requests, decisions, and policy engines.
- `Implementations/Swift/Sources/MSPCore/Workspace/MSPWorkspaceFileSystemPolicy.swift`
  defines workspace filesystem visibility and ordering policy.
- `Implementations/Swift/Sources/MSPCore/Execution/MSPOutputPathSanitizer.swift`
  prevents host-only paths from leaking into model-visible output.
- `Tests/Swift/Unit/MSPApple/MSPAppleWorkspaceTests.swift` verifies Apple
  workspace path behavior.
- `Tests/Swift/Integration/ModelShellProxy/Pipelines/ModelShellProxyPipelineTests.swift`
  covers policy/audit pipeline behavior.

Security rules belong at the runtime boundary, not in individual UI screens.
The agent should see virtual paths and command decisions, while host-only
details remain under app and SDK control.

# MSP External Runners

This directory is for the optional boundary where MSP delegates a command to an
external process runner while preserving MSP workspace, policy, audit, and path
virtualization rules.

Current code evidence:

- `Implementations/Swift/Sources/MSPExternalRunner/Runner/MSPExternalRunner.swift`
  defines the runner protocol and request/result types.
- `Implementations/Swift/Sources/MSPExternalRunner/Runner/MSPHostProcessExternalRunner.swift`
  implements a host-process runner.
- `Tests/Swift/Unit/MSPExternalRunner/MSPExternalRunnerTests.swift` verifies
  virtual path mapping, environment virtualization, and host-path sanitization.

This profile does not turn MSP into a wrapper around the system shell. External
runners are optional backends behind an MSP-owned command boundary.

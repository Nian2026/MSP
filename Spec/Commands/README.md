# MSP Commands

This directory is for the public command-layer contract: command registration,
command-pack composition, shell-facing behavior, and command conformance
expectations.

Current code evidence:

- `Implementations/Swift/Sources/MSPCore/Command/MSPCommand.swift` defines the
  `MSPCommand` execution interface and command context.
- `Implementations/Swift/Sources/MSPCore/Command/MSPCommandRegistry.swift`
  defines `MSPCommandRegistry` and `MSPCommandPack`.
- `Implementations/Swift/Sources/MSPPOSIXCore/Registry/MSPPOSIXCoreCommandPack.swift`
  registers the POSIX-like core command pack.
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json` names
  the required command surface for the Linux command layer profile.
- `Tests/Swift/Unit/MSPPOSIXCore/Registry/MSPPOSIXCoreCommandPackTests.swift`
  verifies command-pack registration behavior.

This is not a generic tool-schema folder. MSP commands are shell-like runtime
primitives: they can participate in parsing, expansion, pipes, redirection,
exit-status rules, WorkspaceFS path resolution, policy checks, audit, and
conformance.

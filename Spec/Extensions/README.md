# MSP Extensions

This directory is for extension rules around app-defined command packs.

The extension mechanism already exists in code: apps register additional
`MSPCommandPack` values into the same runtime used by the core command pack.

Current code evidence:

- `Implementations/Swift/Sources/ModelShellProxy/ModelShellProxy.swift` exposes
  `enable(_ commandPack:)`.
- `Examples/iOS/PhotoSorter/Shell/PhotoSorterCommandPack.swift` implements a
  product command pack.
- `Examples/iOS/PhotoSorter/Shell/MSPPlaygroundShellRuntime.swift` enables the
  POSIX core pack, `.chat` commands, and `PhotoSorterCommandPack`.
- `Examples/iOS/PhotoSorter/Tests/PhotoSorterTests/PhotoSorterMediaCommandTests.swift`
  verifies PhotoSorter media commands through the runtime.

An extension command should behave like a command, not like an isolated tool
endpoint. It should have predictable stdin/stdout/stderr behavior where
applicable, virtual-path semantics, exit statuses, policy behavior, and audit
records.

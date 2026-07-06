# Artifacts

Generated native artifacts for Codex `apply_patch` belong here.

This directory is excluded from normal SwiftPM builds. Developers opt into the
Codex runtime by building and linking an artifact from
`Source/msp-codex-apply-patch-bridge`.

Typical build commands:

```bash
# Host/macOS artifact
Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-rust-bridge.sh

# iOS device artifact
MSP_CODEX_APPLY_PATCH_TARGET=aarch64-apple-ios \
  Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-rust-bridge.sh

# iOS simulator artifact
MSP_CODEX_APPLY_PATCH_TARGET=aarch64-apple-ios-sim \
  Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-rust-bridge.sh

# iOS XCFramework
Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-xcframework.sh
```

The long-lived packaging target is an XCFramework or equivalent in-process
native library. macOS may also wrap the same bridge in a helper process, but
iOS must link the bridge in-process.

Build products are generated from the source crates under `../Source`; ordinary
SwiftPM builds keep `Tools/Vendor` excluded. `build-xcframework.sh` strips DWARF
debug sections from the iOS static libraries and writes
`MSPCodexApplyPatchBridge.xcframework/BUILD_RECEIPT.txt` with the source
revision, path-remap policy, toolchain versions, file sizes, and SHA-256
checksums.

The open-source hygiene gate verifies that tracked binary artifacts have this
receipt, that the checksums match, that the receipt agrees with
`../Source/CODEX_SOURCE_PROVENANCE.txt`, and that the shipped static libraries
do not contain local machine paths or DWARF sections.

Swift apps that want the Codex runtime should depend on the optional
`MSPCodexApplyPatchRuntime` product. That product links
`MSPCodexApplyPatchBridge.xcframework` for iOS and leaves the default
`MSPAgentBridge` product independent of native artifacts.

In app code, prefer the explicit factory name:

```swift
let executor = try MSPCodexApplyPatchRuntime.makeLinkedExecutor(
    workspaceRoot: workspaceRoot,
    cwd: "/"
)
```

Expected artifact families:

- macOS host artifact for development and desktop SDK consumers.
- iOS simulator static library or XCFramework slice.
- iOS device static library or XCFramework slice.

SwiftPM builds must not require these artifacts unless the Codex runtime product
is explicitly selected by the developer.

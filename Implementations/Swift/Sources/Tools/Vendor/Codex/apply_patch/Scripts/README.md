# Scripts

Build, update, and verification scripts for the Codex `apply_patch` native
runtime live here.

- `sync-codex-source.sh`: copies `codex-rs` from the upstream checkout named by
  `MSP_CODEX_RS_SOURCE` into `../Source/codex-rs`, excluding build/cache
  directories, and writes scoped file-hash provenance for the apply_patch
  runtime/proof surface.
- `verify-codex-source.sh`: checks that the source snapshot still contains the
  Codex contract/runtime files MSP relies on.
- `test-rust-bridge.sh`: runs the bridge tests against the synchronized Codex
  source with the bridge lockfile.
- `build-rust-bridge.sh`: builds the Rust C ABI/staticlib/cdylib bridge for the
  selected target with the bridge lockfile.
- `build-xcframework.sh`: builds iOS device + simulator static libraries and
  assembles `Artifacts/MSPCodexApplyPatchBridge.xcframework`.

The scripts intentionally keep Vendor artifacts outside ordinary SwiftPM
targets. SDK users choose whether to build/link the Codex runtime.

Required script responsibilities:

- Verify the vendored Codex source revision.
- Build macOS and iOS artifacts from the same Codex-derived Rust source.
- Fail when license evidence is missing.
- Fail when the generated ABI header and Swift runtime adapter drift.
- Run Codex patch behavior fixtures against the produced artifact.

Scripts must not generate a Swift parser or silently fall back to a non-Codex
implementation.

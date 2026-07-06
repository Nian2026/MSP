# Codex apply_patch Vendor Boundary

This directory owns the Codex-sourced runtime for the MSP `apply_patch` tool.
The Swift SDK contract lives under `Tools/MSP/apply_patch`; this directory is
only for the vendored Codex implementation, bridge, build products, scripts, and
license evidence.

The apply_patch contract evidence must stay sourced from Codex:

- `core/src/tools/handlers/apply_patch_spec.rs`
- `core/src/tools/handlers/apply_patch.lark`
- `tools/src/tool_spec.rs`
- `tools/src/responses_api.rs`

The file-editing semantics must stay sourced from Codex:

- `apply-patch/src/lib.rs`
- `apply-patch/src/parser.rs`
- `apply-patch/src/streaming_parser.rs`
- `apply-patch/src/invocation.rs`
- `core/src/tools/runtimes/apply_patch.rs`

MSP must not ship a Swift reimplementation of hunk parsing or patch
application. Swift code may own SDK selection, request encoding, stream parsing,
workspace policy, and executor injection; the patch engine belongs here.

Platform rule:

- macOS may use an out-of-process artifact only as a host-side packaging choice.
- iOS must use an in-process native artifact, such as a static library or
  XCFramework exposed through a stable C ABI.

Current bridge source:

- `Source/msp-codex-apply-patch-bridge`
- `Source/codex-apply-patch-runtime`
- `Source/codex-exec-server-compat`
- `Source/codex-utils-absolute-path-runtime`

Required source snapshot:

- `Source/codex-rs`

Create or refresh the source snapshot with:

```bash
MSP_CODEX_RS_SOURCE=/path/to/codex/codex-rs \
  Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/sync-codex-source.sh
```

The source path must be the `codex-rs` directory inside a clean Git checkout.
Set `MSP_CODEX_REPOSITORY_PROVENANCE` when the checkout comes from a public fork
or mirror rather than `https://github.com/openai/codex`.
`Source/CODEX_SOURCE_PROVENANCE.txt` records the runtime/proof files used by
this bridge. `Source/codex-rs` must stay limited to the files listed in that
manifest; do not publish a full Codex workspace snapshot here.

The bridge crate calls `codex_apply_patch::apply_patch` directly. The
`codex-apply-patch-runtime` crate points its library entry at
`Source/codex-rs/apply-patch/src/lib.rs`, so parser and hunk application logic
comes from the synchronized Codex source files.

The `codex-exec-server-compat` crate is a packaging shim for embedded SDK
artifacts. Codex `apply-patch` only needs file-system trait/types from
`codex-exec-server`; linking the full exec server would pull host networking,
server, protocol, and process dependencies that are not appropriate for iOS
artifacts. The shim provides the same type surface needed by `apply-patch` and
supplies a local `LOCAL_FS` for Codex source paths that reference it. It must
not implement patch parsing or hunk application.

The `codex-utils-absolute-path-runtime` crate is a packaging shim around the
scoped Codex `utils/absolute-path` source files. It keeps the upstream source
files unchanged while avoiding a dependency on the full upstream workspace
manifest.

MSP-owned bridge code only owns JSON/C ABI boundaries, virtual workspace path
mapping, host path redaction, and artifact packaging. It must not parse or
apply patch hunks.

Validation and builds:

```bash
Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/test-rust-bridge.sh
Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Scripts/build-rust-bridge.sh
```

Set `MSP_CODEX_APPLY_PATCH_TARGET` for platform artifacts, for example
`aarch64-apple-darwin`, `aarch64-apple-ios`, or
`aarch64-apple-ios-sim`.

Completion requires the source snapshot, license evidence, built artifacts for
the selected platforms, and tests proving the Swift executor output comes from
the Codex engine rather than a Swift parser.

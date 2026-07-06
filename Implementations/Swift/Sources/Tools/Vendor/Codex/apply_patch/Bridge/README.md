# Bridge

The bridge exposes Codex `apply_patch` to Swift without changing the patch
format or patch semantics. The current bridge source is:

```text
../Source/msp-codex-apply-patch-bridge
```

Required bridge shape:

- Accept raw freeform patch text as UTF-8.
- Accept an SDK-controlled workspace root and cwd.
- Return stdout, stderr, aggregate output, exit code, changed paths, and exact
  delta metadata.
- Never expose host-only paths in model-visible output.
- Avoid `Process` or helper-process assumptions for iOS.

The bridge uses JSON across the C ABI between Swift and native Rust. The
model-facing tool input remains raw freeform patch text. JSON is only a Swift
to native-runtime transport detail.

Exported ABI:

- `msp_codex_apply_patch_json(input_ptr, input_len, output_ptr, output_len) -> int32_t`
- `msp_codex_apply_patch_stdin_json(output_ptr, output_len) -> int32_t`
- `msp_codex_apply_patch_free(ptr, len)`

The C header and Swift-importable module map live under:

```text
include/
```

The JSON request/response shape matches the Swift
`MSPCodexApplyPatchBridgeRequest` and `MSPCodexApplyPatchBridgeResponse`
adapter under `Tools/MSP/apply_patch/Runtime`.

Runtime behavior is provided by `codex_apply_patch::apply_patch`; the bridge
does not parse patch hunks.

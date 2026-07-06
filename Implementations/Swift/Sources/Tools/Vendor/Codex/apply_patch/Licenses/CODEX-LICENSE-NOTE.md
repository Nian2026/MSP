# Codex License Evidence

The upstream Codex Rust workspace declares `license = "Apache-2.0"` in:

```text
codex-rs/Cargo.toml
```

The checked-in `Source/codex-rs` snapshot is intentionally scoped to the
apply_patch runtime/proof files listed in `Source/CODEX_SOURCE_PROVENANCE.txt`,
rather than a full upstream workspace copy. The bridge crate is also declared as
Apache-2.0. The Apache-2.0 license text is kept in `APACHE-2.0.txt`; keep it
with generated source provenance, third-party Cargo license evidence, and binary
artifacts.

Before distributing artifacts, run `Scripts/sync-codex-source.sh` and keep the
generated `Source/CODEX_SOURCE_PROVENANCE.txt` with the scoped source snapshot
used to build the artifact.

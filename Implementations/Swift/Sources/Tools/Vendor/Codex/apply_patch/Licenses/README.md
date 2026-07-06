# Licenses

License evidence for the vendored Codex `apply_patch` runtime belongs here.

The upstream Codex Rust workspace declares Apache-2.0 in `codex-rs/Cargo.toml`;
the local bridge crate declares the same license. The checked-in
`Source/codex-rs` directory is a scoped source snapshot, not a full workspace.
Keep `APACHE-2.0.txt`, `CODEX-LICENSE-NOTE.md`,
`THIRD-PARTY-CARGO-LICENSES.json`, and the generated source provenance with any
distributed artifact.

The referenced Codex Rust workspace declares `Apache-2.0` in its workspace
manifest. When source or binary artifacts are added, this folder must contain:

- the applicable license text, currently `APACHE-2.0.txt`,
- the source revision or provenance note,
- third-party dependency license evidence for the produced artifact, currently
  generated from `cargo metadata --locked --format-version 1` into
  `THIRD-PARTY-CARGO-LICENSES.json`.

The SDK must not publish a Codex runtime artifact without this evidence.

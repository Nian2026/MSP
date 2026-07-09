# Markstream Runtime

The Default renderer depends on a markstream runtime for smooth markdown
streaming and Codex-style text fade animation.

Reference source:

```text
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/readex-markstream-sdk.js
References/AIReadingReadexModeSnapshot/Tools/ReadexMarkstreamRenderer/
```

Known reference package versions from `Tools/ReadexMarkstreamRenderer/package.json`:

| Package | Version |
| --- | --- |
| `markstream-vue` | `1.0.3-beta.2` |
| `stream-markdown` | `^0.0.16` |
| `stream-monaco` | `^0.0.45` |
| `vue` | `3.5.25` |
| `esbuild` | `0.28.1` |

Current migrated bundle:

```text
../assets/Math/readex-markstream-sdk.js
```

Before public release:

1. Replace Readex-facing globals with an MSP-facing wrapper.
2. Preserve the default `markstream-readex-fade` behavior.
3. Keep `readex-markstream-readex-codex-animation` behavior under an MSP-facing name or compatibility alias.
4. Document bundled third-party licenses.
5. Verify streaming source update and finalization with fixtures.

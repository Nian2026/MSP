# Default Renderer Vendor Manifest

This renderer packages browser assets under `runtime/assets/` so iOS/macOS
WKWebView, Windows WebView2, Android WebView, and browser hosts can load the
same UI runtime.

## Provenance

The first migrated asset set is sourced from the local ignored reference
snapshot:

```text
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/KnowledgeMap/
```

The source loading order is preserved through:

```text
runtime/assets/Math/chat-transcript-document-assets.json
```

## Included Notices

The migrated asset tree includes upstream notice files already present in the
reference resources:

| Asset family | Notice file |
| --- | --- |
| diff2html | `runtime/assets/Math/diff2html-LICENSE.md` |
| highlight.js | `runtime/assets/Math/highlightjs-LICENSE.txt` |
| Prettier | `runtime/assets/Math/prettier-LICENSE.txt` |
| d3 | `runtime/assets/KnowledgeMap/d3-LICENSE.txt` |
| markmap-view | `runtime/assets/KnowledgeMap/markmap-view-LICENSE.txt` |

## Markstream Bundle

`runtime/assets/Math/readex-markstream-sdk.js` is the bundled markstream runtime
used by the Default renderer. The reference source project records these direct
dependencies:

| Package | Version |
| --- | --- |
| `markstream-vue` | `1.0.3-beta.2` |
| `stream-markdown` | `^0.0.16` |
| `stream-monaco` | `^0.0.45` |
| `vue` | `3.5.25` |
| `esbuild` | `0.28.1` |

The release gate audits the bundled Markstream runtime through
`Conformance/fixtures/markstream-bundle-license-audit.json`. That fixture is
publishable SDK data: it records the bundle hash, package versions, and license
families derived from the ignored extraction source package-lock.

# ReadexMode Extraction Map

This map tracks the ReadexMode chat UI extraction into the MSPChatUI Default
renderer. It is intentionally source-backed: every publishable asset must trace
back to the local reference snapshot, then pass provenance and license review
before it moves into `Renderers/Default/`.

## Local Reference Snapshot

Snapshot path:

```text
References/AIReadingReadexModeSnapshot/
```

The snapshot is ignored by Git through `References/.gitignore`. It is for local
comparison only and must not be published as SDK source.

Copied source roots:

| Snapshot root | Purpose |
| --- | --- |
| `Sources/AIReading/Resources/Math/` | Browser runtime, CSS, markdown engines, markstream bundle, KaTeX/highlight/diff assets, fonts, and asset manifest. |
| `Sources/AIReading/Resources/KnowledgeMap/` | Template-level d3/markmap assets and license files used by mindmap/knowledge-map rendering. |
| `Sources/AIReading/Views/ChatTranscript*.swift` | Apple host, asset injection, WebView command execution, scroll/viewport support, and host diagnostics. |
| `Sources/AIReading/ReadexMode/App/ChatSurface/` | Readex transcript projection, appearance state, theme resolution, capabilities, and composer reference. |
| `Sources/AIReading/ReadexMode/App/ReadexModeViewState.swift` | Visual theme enum values, including markstream profile names. |
| `Tools/ReadexMarkstreamRenderer/` | Source project that builds `readex-markstream-sdk.js`; local `node_modules` is intentionally not kept. |
| `Tests/ChatTranscript/` | Existing Readex transcript tests to mine for fixtures and parity assertions. |

## Asset Manifest Owner

Readex loads the browser renderer from:

```text
Sources/AIReading/Resources/Math/chat-transcript-document-assets.json
```

This manifest is the dependency-order oracle for the MSP Default renderer. Do
not reorder scripts during extraction unless a browser replay fixture proves the
new order is equivalent.

### Document Shell

| Source file | Extraction action |
| --- | --- |
| `chat-transcript-document-template.html` | Convert into Default renderer HTML shell; remove app-specific `Math/` prefixing and make asset paths package-relative. |
| `chat-transcript-document-assets.json` | Convert into `Renderers/Default/renderer.manifest.json` after assets are curated. |
| `chat-transcript-document.css` | Split into theme variables, message layout, tool/activity blocks, markdown, selection/context-menu, and export/print support. |
| `../KnowledgeMap/d3.min.js`, `../KnowledgeMap/markmap-view.js` | Keep only if mindmap/knowledge-map markdown parity remains in Default; publish with their license files. |

### Markdown Dependency Order

The current Readex manifest loads:

```text
katex.min.js
mhchem.min.js
copy-tex.min.js
prettier-standalone.js
prettier-parser-html.js
prettier-parser-postcss.js
prettier-parser-babel.js
prettier-parser-typescript.js
ai-reading-unified-markdown.js
chat-markdown-renderer.js
readex-markstream-sdk.js
```

Extraction notes:

| Dependency | MSP action |
| --- | --- |
| `readex-markstream-sdk.js` | Required for Default. Move only after third-party review; it exposes `window.ReadexMarkstreamSDK` in the reference and should get an MSP-facing wrapper. |
| `ai-reading-unified-markdown.js` | Large generated legacy markdown renderer. Keep as fallback only if fixtures prove Default still needs it after markstream extraction. |
| `chat-markdown-renderer.js` | Adapter that selects markdown engine and render options. Extract as runtime glue, not as an app-specific host file. |
| KaTeX, mhchem, copy-tex | Required if Default supports math parity. Must carry license notices and fonts. |
| highlight.js, Prettier parsers, diff2html | Required only if parity matrix keeps code highlighting, formatting, and diff blocks in Default. Review licenses before publishing. |

### Transcript Runtime Order

The current Readex manifest loads these transcript runtime scripts in order:

```text
chat-transcript-renderer-components.js
chat-transcript-message-status-model.js
chat-transcript-message-block-model.js
chat-transcript-message-runtime-model.js
chat-transcript-host-bridge.js
chat-transcript-style-platform.js
chat-transcript-message-dom.js
chat-transcript-scroll-metrics.js
chat-transcript-anchor-platform.js
chat-transcript-dom-platform.js
chat-transcript-render-support.js
chat-transcript-visual-support.js
chat-transcript-presentation-controller.js
chat-transcript-scroll-coordinator.js
chat-transcript-conversation-controller.js
chat-transcript-interaction-state.js
chat-transcript-overlay-controller.js
chat-transcript-video-progress-renderer.js
diff2html.min.js
chat-transcript-message-block-support-renderer.js
chat-transcript-message-block-renderer.js
chat-transcript-message-ui-renderer.js
chat-transcript-message-article-renderer.js
chat-transcript-conversation-layout.js
chat-transcript-conversation-renderer.js
chat-transcript-render-pipeline.js
chat-transcript-render-coordinator.js
chat-transcript-payload-model.js
chat-transcript-payload-patcher.js
chat-transcript-payload-store.js
chat-transcript-runtime.js
chat-transcript-document-shell.js
chat-transcript-document-runtime.js
chat-transcript-explanation-anchors.js
chat-transcript-bootstrap-legacy-runtime-bindings.js
chat-transcript-command-bridge.js
chat-transcript-bootstrap-bindings.js
chat-transcript-bootstrap-foundation-stage.js
chat-transcript-bootstrap-interaction-stage.js
chat-transcript-bootstrap-document-stage.js
chat-transcript-bootstrap-render-stage.js
chat-transcript-bootstrap-runtime-stage.js
chat-transcript-bootstrap-stage-assembler.js
chat-transcript-bootstrap-composer.js
chat-transcript-bootstrap-support.js
chat-transcript-bootstrap-lifecycle.js
chat-transcript-bootstrap.js
chat-transcript-bootstrap-entry.js
chat-transcript-bootstrap-launch.js
chat-transcript-bootstrap-autostart.js
```

Extraction notes:

| Runtime area | Source-backed detail to preserve |
| --- | --- |
| Message UI | `chat-transcript-message-ui-renderer.js` owns action buttons, footer affordances, streaming status, and shimmer timing. |
| Tool/activity blocks | `chat-transcript-message-block-support-renderer.js` and `chat-transcript-message-block-renderer.js` own the high-detail Readex processing/tool UI. |
| Streaming patches | `chat-transcript-payload-patcher.js`, `chat-transcript-render-coordinator.js`, and `chat-transcript-render-pipeline.js` own incremental updates. |
| Stable visual helpers | `chat-transcript-visual-support.js` owns icons, palette helpers, and native-looking visual affordances. |
| Host bridge | `chat-transcript-host-bridge.js`, `chat-transcript-command-bridge.js`, and `chat-transcript-host-command-invocation.js` must become platform-neutral bridge contracts. |
| Scroll and layout | `chat-transcript-scroll-coordinator.js`, `chat-transcript-scroll-metrics.js`, and `chat-transcript-conversation-layout.js` must stay browser-core; native hosts only provide viewport signals. |

## Default Theme Source

The requested MSP Default theme corresponds to Readex's Codex-style transcript
using markstream with Codex animation:

| Source fact | Preserve in MSP Default |
| --- | --- |
| `ReadexTranscriptVisualTheme.markstreamReadexFade = "markstream-readex-fade"` | Default markdown profile should be the animated markstream profile. |
| `showsAssistantBubbleBackground: false` | Assistant/model replies render as open transcript content, not chat bubbles. |
| `showsUserBubbleBackground: true` | User messages render with a subtle gray bubble in MSP Default. |
| `userBubbleBackground: labelColor.opacity(0.055)` | Use a platform-neutral gray token instead of Apple `NSColor`. |
| `messageFontSize: 15.5`, `messageFontWeight: 430` | Carry as Default theme tokens. |
| `readex-markstream-readex-codex-animation` | Preserve Codex fade animation for streaming text. |

## Host Boundary

The cross-platform renderer must be browser-standard DOM/CSS/JS. These Apple
host files are reference material, not renderer-core source:

| Source file | Keep out of core because |
| --- | --- |
| `ChatTranscriptWebView.swift` | Owns WKWebView lifecycle, encoded command execution, AppKit/UIKit colors, and native host state. |
| `ChatTranscriptRendererShell.swift` | Builds Apple bundle HTML and injects asset paths; useful as manifest logic reference only. |
| `ChatTranscriptSingleOwnerHost.swift` | Apple retained-WebView ownership and lifecycle. |
| `ChatTranscriptHostCommandExecutor.swift` | WKWebView JavaScript command bridge implementation. |
| `ReadexModeChatTranscriptSurface.swift` | Swift projection and appearance computation; MSP should reimplement projection in `Projection/` with platform-neutral payloads. |

## Extraction Gate

A file can move from `References/` to `Renderers/Default/` only when:

1. It is needed by a parity checklist item or a renderer contract.
2. Apple-specific APIs are removed or isolated behind `Hosts/`.
3. The public MSP-facing names do not expose Readex branding.
4. The runtime still works from inside `MSPChatUI/` without reaching outside this folder.
5. Provenance and third-party notices are updated next to the moved asset.
6. A fixture or screenshot check covers the behavior that the file preserves.

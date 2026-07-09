# Default Renderer

Default is the built-in MSP chat renderer. It should preserve the requested
ReadexMode-style experience while presenting MSP-facing names and contracts.

Target behavior:

- user messages: subtle gray bubbles
- assistant messages: open markdown body, no bubble
- markdown: markstream profile with Codex fade animation
- tools: Readex-style processing/tool activity blocks, shimmer, stable accent colors, folded details, and streaming patch updates
- rich blocks: proposed plans, generated images, video progress, text selections, sources, attachments, and footer actions

The renderer must be self-contained inside `MSPChatUI/`. It must not import app
code, MSP core implementation sources, example apps, or local reference
snapshots.

Default must remain one renderer across platforms. Platform-specific code may
load assets and implement host callbacks, but it must not fork the message DOM,
tool block rendering, markstream behavior, shimmer animation, theme CSS, or
streaming patch logic.

## Runtime Layout

```text
renderer.manifest.json
runtime/
  assets/          Packaged browser runtime assets loaded by the manifest
  bridge/          MSP host bridge compatibility shims
  loader/          Cross-platform Web loader for the renderer manifest
  transcript/      Notes for transcript shell, render coordinator, patcher, blocks
  markstream/      Notes for curated markstream runtime and MSP-facing wrapper
themes/
  default/         Default visual tokens and CSS split from the Readex source
blocks/           Block schemas and renderer notes for tool/activity families
```

The first migrated runtime keeps the original `Math/` and `KnowledgeMap/` asset
subtrees under `runtime/assets/` so KaTeX fonts and document-template relative
paths continue to work. `renderer.manifest.json` is the MSP-facing manifest;
`runtime/assets/Math/chat-transcript-document-assets.json` remains the
source-order oracle for the copied transcript runtime.

## Public API Boundary

`runtime/api/default-renderer-api.js` exposes the renderer-facing API:

```text
MSPChatUIDefaultRenderer.renderTimeline(timeline)
MSPChatUIDefaultRenderer.updateTimeline(timeline)
MSPChatUIDefaultRenderer.applyOperation(operation)
```

Host apps should call that API with MSP canonical timelines. They should not call
`window.__chatTranscriptRuntimeBridge`, `window.__chatTranscriptCommandBridge`,
or any Readex-derived payload helper directly.

The Default renderer supports the MSP canonical block set documented in
`Contracts/README.md`. Internally it adapts those blocks to the copied
Readex-derived browser runtime, but that adaptation is private to this renderer.

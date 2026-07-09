# Default Renderer Parity Checklist

The Default renderer is accepted only when it matches the source-backed Readex
behavior for these cases. Each checked item must have a fixture or screenshot
reference before the renderer is considered publishable.

## Message Shape

- [x] User messages render as right-aligned subtle gray bubbles. Automated by `browser-smoke.cjs`.
- [x] Assistant messages render as open markdown content with no bubble. Automated by `browser-smoke.cjs`.
- [x] Assistant final answer follows tool/activity blocks with the same spacing as Readex. Automated by `browser-rich.cjs`.
- [x] Empty streaming assistant messages show the Readex-style thinking/status line. Automated by `browser-empty-streaming.cjs`.
- [x] Message footer actions preserve hover, tooltip, copy, regenerate, branch, and edit affordance slots where the host enables them. Automated by `browser-actions-windowing.cjs`.

## Markstream And Markdown

- [x] Default profile is `markstream-readex-fade`. Automated by `browser-smoke.cjs`.
- [x] Streaming text uses Codex fade animation and respects reduced-motion. Automated by `browser-rich.cjs` and `browser-reduced-motion.cjs`.
- [x] Live markdown updates use lightweight source updates where possible. Automated by `static-conformance.cjs` and `browser-smoke.cjs`.
- [x] Finalization does not reflow already-rendered long answers unnecessarily. Automated by `static-conformance.cjs` and `browser-patch-behavior.cjs`.
- [x] Headings, paragraphs, lists, nested lists, links, footnotes, blockquotes, and horizontal rules match the Readex spacing tokens. Automated by `browser-rich.cjs`.
- [x] Tables render under Markstream. Automated by `browser-smoke.cjs`.
- [x] Inline code and fenced code blocks render under Markstream. Automated by `browser-smoke.cjs`.
- [x] Code blocks keep copy/collapse/header behavior. Automated by `browser-rich.cjs`.
- [x] Inline math renders with KaTeX. Automated by `browser-smoke.cjs`.
- [x] Math blocks keep overflow behavior. Automated by `browser-rich.cjs`.
- [x] Unsafe link schemes stay blocked. Automated by `browser-rich.cjs`.

## Tool And Processing Blocks

- [x] `readex_processing` blocks render with folded/expanded details. Automated by `browser-rich.cjs` and `browser-patch-behavior.cjs`.
- [x] Processing continuation blocks do not duplicate chrome. Automated by `browser-rich.cjs`.
- [x] Tool activity batches render as Readex processing/activity blocks. Automated by `browser-smoke.cjs`.
- [x] Tool start/running/failure states render visible status/detail text. Automated by `browser-smoke.cjs`.
- [x] Tool icons are diverse and do not fall back to the CPU icon for the fixture tools. Automated by `browser-smoke.cjs`.
- [x] Shimmer text appears for active thinking/tool labels. Automated by `browser-smoke.cjs`.
- [x] Shimmer timing preserves the Readex cadence: initial delay, sweep duration, and repeated interval. Automated by `static-conformance.cjs`.
- [x] Stable random/accent colors remain stable across re-render and streaming patches. Automated by `browser-actions-windowing.cjs`.
- [x] Subagent/activity blocks, video progress blocks, support previews, and text-selection highlights either match Readex or are explicitly scoped out with a fixture. Automated by `browser-rich.cjs`.
- [x] Proposed plans and generated image placeholders render in the Default fixture. Automated by `browser-rich.cjs`.

## Streaming And Patch Behavior

- [x] Full conversation render works from a cold HTML shell. Automated by `browser-smoke.cjs`.
- [x] Incremental message patch updates existing DOM instead of replacing the whole transcript. Automated by `browser-patch-behavior.cjs`.
- [x] Streaming text patches preserve scroll position when not pinned to live edge. Automated by `browser-patch-behavior.cjs`.
- [x] Live-edge auto-scroll matches Readex thresholds. Automated by `browser-patch-behavior.cjs`.
- [x] Patch updates carry metadata such as memory citations, tool activity state, and message action policy. Automated by `static-conformance.cjs` and `browser-actions-windowing.cjs`.
- [x] Direct processing-block source updates work without a full render. Automated by `static-conformance.cjs` and `browser-patch-behavior.cjs`.
- [x] Long transcripts keep render performance acceptable through windowing/virtual behavior where applicable. Automated by `browser-actions-windowing.cjs`.

## Layout And Theme

- [x] Light theme tokens match the requested Default visual: assistant open content, gray user bubble, Codex-style typography. Automated by `browser-smoke.cjs`.
- [x] Dark theme applies dark root, color scheme, and app background tokens. Automated by `browser-smoke.cjs`.
- [x] Container-relative layout works on narrow mobile and desktop fixture widths. Automated by `browser-smoke.cjs`.
- [x] Container-relative layout works on tablet and wide desktop widths. Automated by `browser-responsive.cjs`.
- [x] Page padding, message gap, role/meta/support font sizes, and content width match Readex defaults. Automated by `static-conformance.cjs` and `browser-rich.cjs`.
- [x] Scroll bottom slack can be supplied by hosts without altering renderer semantics. Automated by `static-conformance.cjs` and `browser-rich.cjs`.
- [x] Native selection overlays and context menus do not overlap content. Automated by `browser-selection-overlay.cjs`; text-selection reference rendering is automated by `browser-rich.cjs`.

## Host Contract

- [x] Renderer runs in a plain browser page with static assets. Automated by `browser-smoke.cjs`.
- [x] The same `Renderers/Default` manifest and assets load in WKWebView, WebView2, Android WebView, and desktop browser hosts. Automated by `host-conformance.cjs`; Apple host also builds with `swift build`.
- [x] iOS, macOS, Windows, Android, and browser hosts do not carry platform-specific copies of DOM renderers, theme CSS, tool block renderers, markstream runtime, shimmer logic, or streaming patch logic. Automated by `host-conformance.cjs`.
- [x] Copy, open link, open reference, scroll, context menu, presentation probes, and command execution are bridge events, not hardcoded native calls. Automated by `host-conformance.cjs` and `browser-host-bridge.cjs`.
- [x] Direct `window.webkit` access is wrapped behind a host bridge fallback. Automated by `browser-host-bridge.cjs`.
- [x] The renderer does not import MSP core or example-app code. Automated by `release-hygiene.cjs`.
- [x] Cross-platform screenshots use the same fixture payloads and only allow documented WebView engine differences. Automated browser matrix by `browser-screenshot-matrix.cjs`; native host capture rules are documented in `ScreenshotMatrix.md`.

## Release Hygiene

- [x] `MSPChatUI/` can be copied alone and still contains all required Default renderer assets. Automated by `release-hygiene.cjs` and `renderer-contract.cjs`.
- [x] `References/` content is ignored by Git.
- [x] No copied `node_modules`, build caches, app snapshots, or private product paths are tracked. Automated by `release-hygiene.cjs`.
- [x] Runtime third-party licenses are documented. Automated by `license-audit.cjs`.
- [x] Markstream provenance is documented before `readex-markstream-sdk.js` or its successor is published. Automated by `license-audit.cjs`.

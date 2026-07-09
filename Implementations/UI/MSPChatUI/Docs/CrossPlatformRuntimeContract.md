# Cross-Platform Runtime Contract

MSPChatUI Default is one Web renderer shared by every host platform.

The migration is not complete until the same `Renderers/Default` assets can be
loaded by:

- browser DOM
- iOS/macOS WKWebView
- Windows WebView2
- Android WebView

## Single Renderer Rule

The following files and behaviors must have exactly one Default implementation:

| Area | Owner |
| --- | --- |
| HTML shell and asset manifest | `Renderers/Default/runtime/transcript/` |
| Message DOM | `Renderers/Default/runtime/transcript/` |
| Tool and processing blocks | `Renderers/Default/blocks/` plus transcript runtime |
| Markdown and markstream | `Renderers/Default/runtime/markstream/` |
| Theme CSS and tokens | `Renderers/Default/themes/default/` |
| Streaming patch behavior | `Renderers/Default/runtime/transcript/` |
| Shimmer and Codex animation | Default runtime and theme assets |

Hosts may not fork these files for platform parity.

## Host Responsibilities

Platform hosts may implement only:

- locating packaged renderer assets
- creating the native WebView or browser container
- sending initial payloads and patches into the renderer
- receiving host bridge events
- native copy, share, open-link, open-reference, and context-menu actions
- viewport, scroll, safe-area, and focus integration

## Forbidden Platform Forks

Do not create `iOS/Default`, `Windows/Default`, or `Android/Default` renderer
copies. If a platform needs a workaround, put the workaround behind a documented
host capability flag or a small platform bridge in `Hosts/`.

Forbidden forks include:

- different message bubble DOM per platform
- different assistant markdown renderer per platform
- different tool-call block renderer per platform
- platform-only CSS for the Default theme
- platform-only streaming renderer logic
- platform-only markstream bundles

## Acceptance Gate

A migration slice is accepted only when:

1. The browser fixture runner can load `Renderers/Default`.
2. WKWebView, WebView2, and Android WebView hosts load the same manifest.
3. Fixture payloads render with the same DOM markers across hosts.
4. Screenshot differences are limited to documented WebView engine differences.
5. No host imports Readex, MSP core implementation internals, or example-app UI.

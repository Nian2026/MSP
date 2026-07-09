# Hosts

Hosts are thin adapters that load a renderer and provide platform bridge
callbacks. They are not separate UI implementations.

Expected host families:

- browser DOM
- WKWebView
- WebView2
- Android WebView

The browser DOM host lives under `Web/` and is the first fixture runner for the
shared Default renderer. Native hosts should follow the same pattern: load
`Renderers/Default/renderer.manifest.json`, then provide host bridge callbacks.

All host families must load the same Default renderer manifest and assets.
Host-specific folders may contain bootstrapping, asset URL resolution, native
message bridge code, and viewport/scroll integration only.

Do not add platform-specific copies of:

- message DOM renderers
- markdown or markstream renderers
- tool/activity block renderers
- theme CSS
- shimmer or Codex animation logic
- streaming patch logic

Host adapters may implement file loading, native copy/share/open actions,
selection menus, viewport reporting, and scroll integration. Message DOM,
markdown rendering, tool blocks, shimmer, and Default theme behavior belong in
`Renderers/Default/`.

Selection menu payloads use the shared handler name
`__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__`. Hosts should route it
like any other bridge channel and keep menu presentation native.

# Native WebView Host Contract

MSPChatUI is a single Web renderer with thin native hosts.

Native hosts for WKWebView, WebView2, Android WebView, or a desktop browser may
only provide:

- asset location and loading
- bridge channels for copy, open-link, open-reference, menus, and probes
- the selection context-menu handler named `__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__`
- viewport, safe-area, focus, and scroll integration
- host capability flags

Native hosts must not fork:

- message DOM
- markdown or Markstream runtime
- tool block rendering
- theme CSS
- streaming patch behavior
- renderer-specific payload projection

If a platform needs a workaround, add a small host capability and keep the UI
behavior in `Renderers/`.

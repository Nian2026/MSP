# Apple Host

This host is a thin WKWebView wrapper for iOS and macOS. It loads the shared
Default Web renderer and forwards native bridge messages.

It must not contain renderer DOM, CSS, markdown, tool block, shimmer, or
streaming patch logic.

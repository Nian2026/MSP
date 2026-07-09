# Windows Host

This host is a thin WebView2 wrapper. It loads the shared Default Web renderer
and forwards host bridge events through `chrome.webview.postMessage`.

It must not contain renderer DOM, CSS, markdown, tool block, shimmer, or
streaming patch logic.

# Android Host

This host is a thin Android WebView wrapper. It loads the shared Default Web
renderer and forwards host bridge messages through `JavascriptInterface`.

It must not contain renderer DOM, CSS, markdown, tool block, shimmer, or
streaming patch logic.

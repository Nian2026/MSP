# Web Host

This host loads the same `Renderers/Default/renderer.manifest.json` that native
hosts should use. It is primarily a cross-platform fixture runner for the shared
Default Web renderer.

Run it from the `MSPChatUI` directory with a static HTTP server, then open:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

```text
http://127.0.0.1:8765/Hosts/Web/default.html
```

The page loads `Conformance/fixtures/default-basic.conversation.json` by
default. Pass `?fixture=<url>` to render another payload.

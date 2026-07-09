# MSPChatUI API

MSPChatUI exposes one public model: the MSP chat timeline.

```js
const { contracts, projection, registry, defaultRendererManifest } = require("@msp/chat-ui");
```

Public package exports:

- `.`: CommonJS SDK entrypoint.
- `./contracts`: TypeScript timeline/event/block types.
- `./renderers/default/manifest`: Default renderer manifest JSON.
- `./hosts/web/default.html`: Static Web host for the Default renderer.

## Canonical Input

Renderers consume `MSPChatUITimeline` objects:

```js
{
  schema: "msp.chat-ui.timeline.v1",
  id: "conversation",
  messages: [
    {
      id: "u1",
      role: "user",
      blocks: [{ id: "u1:text", type: "markdown", text: "Hello" }]
    }
  ]
}
```

Runtime updates use `MSPChatUIRuntimeEvent`, for example `stream.delta`,
`block.patch`, `tool.lifecycle`, `interaction.collapse`, and
`presentation.update`.

## Default Renderer

Browser hosts load `Hosts/Web/default.html` or load
`Renderers/Default/runtime/loader/default-web-loader.js` with the Default
manifest.

After the loader is ready:

```js
await window.MSPChatUIDefaultRenderer.renderTimeline(timeline);
await window.MSPChatUIDefaultRenderer.applyRuntimeEvent(event);
```

Native hosts should wrap a WebView and call the same renderer API. They should
only implement asset loading, host bridge callbacks, viewport/safe-area
integration, copy/open/menu behavior, and native selection menu presentation.

## Renderer Boundary

Third-party renderers should live under `Renderers/<Name>/` with a
`renderer.manifest.json`. They consume MSP timelines, not Default's private
Readex-derived payload.

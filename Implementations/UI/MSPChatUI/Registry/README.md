# Renderer Registry

The registry is the renderer contribution boundary. It knows about renderer
manifests, capabilities, and asset entrypoints, but it does not know about any
renderer private DOM or payload shape.

Third-party renderers should live under `Renderers/<Name>/` and register a
manifest with the same public MSP contracts:

- `Contracts/runtime/timeline.js`
- `Contracts/runtime/events.js`
- `Contracts/types/msp-chat-ui.d.ts`

Renderers may own private adapters internally, but hosts and MSP runtime events
must keep using the canonical MSP model.

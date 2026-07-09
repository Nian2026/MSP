# Projection

Projection converts MSP chat timelines and live events into renderer payloads.

This layer replaces the Readex-specific Swift projection from the reference
snapshot. It should preserve behavior while removing product-specific names and
Apple-only state.

Projection owns:

- MSP timeline to UI message mapping
- tool call and command output block mapping
- streaming delta to renderer patch mapping
- presentation defaults for the Default theme
- capability flags exposed to renderer hosts

Projection must not contain DOM code or native WebView code.

## Runtime Files

```text
runtime/identity.js         Stable message, block, and group keys.
runtime/default/            Small mappers for Default activity, blocks, messages, actions, and presentation.
runtime/default-adapter.js  Private payload assembler for the built-in Default renderer.
runtime/payload-diff.js     Renderer payload diff builder.
runtime/render-planner.js   Platform-neutral render operation planner.
runtime/stream-delta.js     Text delta helpers for live assistant output.
runtime/timeline-store.js   Canonical runtime event reducer.
runtime/index.js            Public projection entrypoint.
```

Only `runtime/default/` and `runtime/default-adapter.js` may know about the
Default renderer's Readex-derived internal payload shape. The public entrypoint
still accepts and returns MSP-owned concepts: timelines, projections, and render
operations.

`runtime/default/activity-adapter.js` maps MSP activity items to Default tool
rows. `runtime/default/action-policy-adapter.js` maps neutral MSP message action
names such as `copy`, `branch`, `regenerate`, and `edit` to Default's private
footer controls. `runtime/default-adapter.js` also maps collapsed/expanded MSP
presentation state into Default expansion metadata.

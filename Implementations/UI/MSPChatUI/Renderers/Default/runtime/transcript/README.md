# Transcript Runtime

This folder will contain the curated browser runtime that renders MSP chat
timelines. The source oracle is the Readex transcript runtime listed in
`Docs/ReadexModeExtractionMap.md`.

The first migrated runtime is packaged under:

```text
../assets/Math/
```

It is loaded by `../loader/default-web-loader.js` using
`../../renderer.manifest.json`.

The first publishable version should expose a small browser API:

```text
renderConversation(payload)
renderConversationPreservingScroll(payload, options)
applyPatch(patch)
setPresentationState(state)
destroy()
```

The API is deliberately platform-neutral. Native hosts may provide bridge
callbacks for copy, open, scroll, context menu, and probes, but the DOM structure
and visual behavior live here.

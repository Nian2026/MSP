# MSPChatUI

MSPChatUI is the optional UI layer for rendering MSP chat timelines.

This folder is intended to be a self-contained release unit. Publishing the
default MSP chat UI should only require this directory and should not require
copying MSP core sources, examples, product snapshots, or app-specific hosts.

The Default UI is a single cross-platform Web renderer. iOS, macOS, Windows,
Android, and browser hosts must load the same renderer assets and may only
provide thin platform bridges for file loading, copy/open actions, viewport
signals, selection, scrolling, and native menus.

The built-in renderer lives under `Renderers/Default`. It is intended to become
the official MSP default chat experience: user messages, assistant transcript
content, tool activity, command output, streaming patches, and theme assets.

Package entrypoints and release gates are documented in `API.md` and
`RELEASE.md`.

```js
const { projection, registry, defaultRendererManifest } = require("@msp/chat-ui");
```

Before publishing or tagging this folder, run:

```sh
npm install
MSP_CHAT_UI_REQUIRE_BROWSER=1 npm run check:release
```

## Long-Term Architecture

MSPChatUI has one public model and many renderers:

```text
Contracts/          Public MSP timeline, block, operation, and host-event model.
Projection/         Pure model layer: MSP timeline -> renderer operation.
Registry/           Renderer manifest and contribution boundary.
Renderers/Default/  Built-in renderer. Readex-derived details stay internal here.
Hosts/              Thin platform loaders and native bridge adapters.
Conformance/        Cross-renderer and cross-host fixtures and gates.
```

The public contract is the MSP canonical timeline plus runtime events such as
`stream.delta`. Third-party renderers should consume that model, not the Default
renderer's internal payload format. The Default renderer may adapt MSP timelines
into the Readex-derived browser runtime, but that format is private to
`Renderers/Default`.

Render planning is platform-neutral. The planner decides between full render,
payload patch, direct streaming update, presentation-only update, and scroll sync
before any host or DOM code runs.

The extraction plan and parity gate live in `Docs/ReadexModeExtractionMap.md`
`Docs/CrossPlatformRuntimeContract.md`, and
`Conformance/DefaultParityChecklist.md`.

Third-party renderers should be added as separate folders under `Renderers/`
with their own manifest, runtime assets, theme files, and conformance fixtures.

`References/` is a local-only workspace for source snapshots used while
extracting renderer behavior. Its copied contents are intentionally ignored by
Git and must not be treated as publishable MSP SDK source.

Platform hosts should stay thin. They load a renderer, pass MSP timelines or
runtime events into it, and bridge platform actions such as copy, open,
selection, scrolling, and native menus.

Keep files small and local in responsibility. Add a new file when a change mixes
contract definitions, projection, render planning, renderer adaptation, or host
bridge behavior.

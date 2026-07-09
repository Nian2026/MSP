# Current Automated Coverage

This file records what is enforced today. It is not a substitute for the full
parity checklist.

## Static

`Conformance/scripts/static-conformance.cjs` verifies:

- MSP timeline fixture validation and projection
- initial `fullRender`
- append-only assistant markdown planning as `directStreamingUpdate`
- runtime `stream.delta` planning as `directStreamingUpdate`
- streaming finalization planning as `directStreamingUpdate`
- rich `processing` blocks adapting to private `readex_processing`
- empty running assistant messages projecting a status processing line
- processing item source changes planning as direct `readex_processing` updates
- focused presentation planning as `presentationOnlyUpdate`
- MSP message action policy mapping to Default footer controls
- bottom slack, memory citation, and Default visual token preservation
- Readex shimmer cadence constants
- Default renderer manifest validation through `Registry/runtime/renderer-registry.js`

`Conformance/scripts/release-hygiene.cjs` verifies:

- ignored local reference snapshot
- no generated/private release paths outside `References/`
- small authored files outside copied Default runtime assets
- manifest script paths exist
- Default manifest advertises runtime event support

`Conformance/scripts/package-release.cjs` verifies:

- root package entrypoint, types, and exports
- `package.json` version matches `VERSION`
- `npm pack --dry-run` includes required SDK files and excludes references,
  build output, app snapshots, and generated caches

`Conformance/scripts/apple-host-build.cjs` verifies:

- Apple WKWebView host package builds with SwiftPM
- generated `.build` output is removed after the check

`Conformance/scripts/license-audit.cjs` verifies:

- repository Apache-2.0 license boundary
- Default renderer notice files
- Markstream package-lock license coverage
- absence of public-release TODO text in the vendor manifest

`Conformance/scripts/host-conformance.cjs` verifies:

- Apple WKWebView, Windows WebView2, Android WebView, and Web host source exists
- native hosts call the public Web renderer API
- host bridge supports WKWebView, WebView2, Android WebView, and browser events
- native hosts do not copy renderer runtime assets

## Browser

`Conformance/scripts/browser-smoke.cjs` verifies:

- cold static HTML boot
- `markstream-readex-fade`
- user gray bubble and assistant transparent/no-bubble default theme
- tool activity blocks with diverse non-CPU icons
- running tool shimmer
- failed tool detail text
- KaTeX inline math
- code block and table rendering
- dark theme background/token application
- narrow mobile layout containment
- public `applyRuntimeEvent({ type: "stream.delta" })` producing `directStreamingUpdate`

`Conformance/scripts/browser-rich.cjs` verifies:

- rich processing UI, folded details, continuation content without duplicate chrome
- diverse tool rows and failed tool text inside Readex processing
- proposed-plan cards and generated-image placeholders
- unsafe link schemes are sanitized
- block math overflow, code-block header/copy/collapse, and Codex fade markers
- footer actions, text-selection chips, video progress, support previews, markdown headings/lists/blockquotes/hr/footnotes, and bottom slack
- desktop layout containment for the rich fixture

`Conformance/scripts/browser-actions-windowing.cjs` verifies:

- assistant footer action slots, hover tooltip, and host bridge click events
- user edit action slot
- payload patch metadata carrying message action policy
- stable subagent accent across direct streaming updates
- long transcript `displayWindow` rendering and metadata

`Conformance/scripts/browser-screenshot-matrix.cjs` verifies:

- the same rich fixture captures non-empty desktop, mobile, and dark screenshots
- screenshot DOM still contains footer and processing surfaces

`Conformance/scripts/browser-selection-overlay.cjs` verifies:

- selection context menu runtime assets are loaded by the shared Default loader
- assistant text selection shows the Codex selected-text overlay without overlap
- selected-text overlay actions bridge through the host context-menu handler

`Conformance/scripts/browser-patch-behavior.cjs` verifies:

- direct processing-block updates become visible without a full render
- non-live-edge scroll position is preserved during direct updates
- collapse events patch expansion metadata and update DOM expansion state
- live-edge streaming updates stay near the bottom threshold
- streaming finalization preserves the existing markdown DOM block

`Conformance/scripts/browser-empty-streaming.cjs` verifies:

- an empty running assistant message renders a Readex-style thinking/status line

`Conformance/scripts/browser-responsive.cjs` verifies:

- tablet and wide desktop message/code containment

`Conformance/scripts/browser-host-bridge.cjs` verifies:

- WebKit-style handlers fall back to browser custom events
- a custom `MSPChatUIHost.postMessage` bridge receives host events

`Conformance/scripts/browser-reduced-motion.cjs` verifies:

- reduced-motion media disables Codex/shimmer animation paths

# Release Gate

MSPChatUI is released as this folder only.

## Required Commands

From `Implementations/UI/MSPChatUI`:

```sh
npm install
MSP_CHAT_UI_REQUIRE_BROWSER=1 npm run check:release
```

This runs:

- timeline/projection/static conformance
- renderer manifest checks
- host boundary checks
- release hygiene and authored-file line limits
- npm package dry-run audit
- third-party license audit
- browser DOM conformance and screenshot matrix
- Apple WKWebView host Swift build with `.build` cleanup

## Package Rules

- `References/` and `AIReadingReadexModeSnapshot/` must stay untracked and
  absent from `npm pack`.
- `package.json` version must match `VERSION`.
- `index.js`, `index.d.ts`, `API.md`, `RELEASE.md`, Default assets, hosts, and
  conformance fixtures must be present in the package dry run.
- Do not publish generated caches, app snapshots, private product paths,
  `node_modules`, or native build output.

## Platform Signoff

Automated browser screenshots cover desktop, mobile, and dark mode. Before a
stable public release, run the same fixture payloads in real WKWebView,
WebView2, and Android WebView shells and compare against
`Conformance/ScreenshotMatrix.md`.

Allowed differences are WebView font rasterization, scrollbars, and native menu
chrome. Message DOM, Markstream output, tool rows, shimmer, footer actions,
selection overlay behavior, and streaming patch behavior must stay shared.

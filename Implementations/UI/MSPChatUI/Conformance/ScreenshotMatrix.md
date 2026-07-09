# Screenshot Matrix

Default visual parity uses the same fixture payloads across hosts.

Automated browser captures are produced by:

```sh
MSP_CHAT_UI_REQUIRE_BROWSER=1 npm run check:browser
```

`browser-screenshot-matrix.cjs` captures `default-rich.conversation.json` at:

- desktop light: 1200 x 900
- mobile light: 390 x 760
- desktop dark: 960 x 720

Screenshots are written to the system temp directory, not this repository.

Native host screenshots must use the same fixture files:

- `Conformance/fixtures/default-basic.conversation.json`
- `Conformance/fixtures/default-rich.conversation.json`
- `Conformance/fixtures/default-empty-streaming.conversation.json`

Allowed differences are WebView engine font rasterization, scrollbar metrics,
and platform menu chrome. Message DOM, Markstream output, tool rows, shimmer,
footer actions, and streaming patch behavior must stay shared.

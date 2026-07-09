# Contracts

Contracts define the platform-neutral payloads consumed by MSPChatUI renderers.

The Default renderer should not consume Readex Swift structs directly. MSP
timeline data should first be projected into stable UI payloads with these
responsibilities:

- message identity, role, status, and ordering
- content blocks and markdown text
- tool/activity blocks and status transitions
- streaming patch operations
- presentation state and theme tokens
- message action policy, display windows, and host bottom slack
- host bridge capabilities

Contract changes must remain renderer-neutral so third-party renderers can live
beside `Renderers/Default/`.

## Files

```text
runtime/status.js       Shared status normalization.
runtime/timeline.js     Canonical timeline normalization and validation.
runtime/events.js       Canonical runtime event and stream delta validation.
schemas/timeline.schema.json
schemas/runtime-event.schema.json
types/msp-chat-ui.d.ts
```

The contract layer must not mention Readex, DOM nodes, WebView APIs, or Default
renderer payloads. Those are renderer implementation details.

Canonical block types are `markdown`, `toolCall`, `toolGroup`, `processing`,
`reasoning`, `progress`, `videoProgress`, `proposedPlan`, `notice`,
`attachment`, `image`, `searchResults`, `searchProgress`, `sources`,
`textSelection`, and `footer`.

Developers should model live assistant/tool state with MSP `processing` blocks
and activity items. They should not create `readex_processing` blocks or depend
on Default renderer payload fields.

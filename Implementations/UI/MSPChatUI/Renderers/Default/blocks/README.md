# Default Blocks

Default block renderers preserve the high-detail Readex transcript block
families while exposing MSP-facing schemas.

Reference source:

```text
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/chat-transcript-message-block-model.js
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/chat-transcript-message-block-renderer.js
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/chat-transcript-message-block-support-renderer.js
References/AIReadingReadexModeSnapshot/Sources/AIReading/Resources/Math/chat-transcript-message-ui-renderer.js
```

Block families to preserve:

| Family | Notes |
| --- | --- |
| Main text | User HTML escaping and assistant markdown/markstream rendering. |
| `readex_processing` | Folded details, continuation chrome rules, direct source patch updates. |
| `readex_tool_activity` | Batched activity rows, status text, previews, durations, stable colors. |
| `readex_tool_call` | Compatibility input that normalizes into activity blocks. |
| Thinking | Streaming/thinking status and shimmer labels. |
| Proposed plan | Collapse state and action affordance slots. |
| Generated image | Placeholder, progress, preview hooks, rounded media. |
| Video progress | Progress rows and open-time bridge behavior. |
| Support/reference | Content/page/video references, validation state, and native open hooks. |
| Text selection | Highlight overlays, explanation anchors, and context-menu actions. |

Do not collapse these into one generic markdown block; several of them carry
stateful patch and host-action behavior.

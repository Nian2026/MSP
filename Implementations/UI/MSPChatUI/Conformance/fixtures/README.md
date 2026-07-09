# Fixtures

Fixtures for Default renderer parity belong here.

`default-basic.conversation.json` is an MSP canonical timeline fixture. It covers
the Default theme, gray user bubble, assistant open markdown, markstream fade
profile, KaTeX, code blocks, and tool activity projection. It also verifies that
common MSP/Codex tool names such as `read_file`, `render_markdown`, and
`exec_command` resolve to specific activity icons instead of the generic CPU
fallback.

`default-rich.conversation.json` covers the Default parity stress path:
processing details, continuation groups, footer actions, stable subagent accent,
video progress, support previews, text-selection chips, proposed plans,
generated-image placeholders, math, code, table, links, footnotes, and bottom
slack.

`default-empty-streaming.conversation.json` covers a running assistant turn with
no visible text, which should render the Readex-style thinking/status line.

Initial fixture set to mine from the Readex snapshot:

- cold transcript with user bubble and assistant final markdown
- streaming assistant markdown with `markstream-readex-fade`
- active thinking/status shimmer
- processing block with folded and expanded details
- tool activity batch with success and failure rows
- direct processing-block patch update
- long transcript scroll/live-edge behavior
- markdown stress case with code, table, math, links, footnotes, and diff

Each fixture should record:

- source snapshot file or test that motivated it
- MSP canonical timeline input
- expected DOM markers
- screenshot expectation where visual parity matters

Use `../scripts/static-conformance.cjs` for model/projection/planner checks and
`../scripts/browser-smoke.cjs` for a real Default renderer DOM smoke when
Playwright is available.

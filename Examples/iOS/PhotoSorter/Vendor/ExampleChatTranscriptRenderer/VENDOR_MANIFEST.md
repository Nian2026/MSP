# Example Transcript Renderer Vendor Manifest

This directory contains the transcript-rendering assets used by the PhotoSorter
example. The vendored surface is intentionally limited to example UI rendering
support.

Files that are byte-for-byte identical across iOS examples are symlinks into
`Examples/iOS/Shared/ExampleChatTranscriptRenderer`. PhotoSorter-specific
renderer overlays remain as regular files in this tree.

## Vendored Resources

- `RuntimeResources/Math`
  - Chat transcript WebView runtime scripts.
  - `chat-unified-markdown.js` and
    `chat-unified-markdown-THIRD-PARTY.json` for the bundled
    unified/remark/rehype/micromark, MathJax, KaTeX, mhchemparser, and related
    browser markdown packages.
  - Markdown, KaTeX, mhchem, copy-tex, highlight.js, Prettier assets.
  - `legacy-spinner.apng`, documented as a project-local UI asset in the shared
    renderer provenance file.
  - Chat transcript document template, CSS, bootstrap, payload patching,
    rendering, tool/activity block, scrolling, selection, and visual support
    scripts.
  - KaTeX fonts and third-party license files.
- `RuntimeResources/KnowledgeMap`
  - D3 and markmap resources used by rendered knowledge map surfaces.
- `RuntimeResources/Paged`
  - Paged.js runtime used by document rendering surfaces.
- `Swift/ExampleChatTranscriptThemePreset.swift`
  - Compiled iOS demo preset for the default transcript theme: user messages on
    the right, assistant content on the left, no visible speaker labels/model
    labels.
- `Swift/ExampleChatTranscriptRendererShell.swift`
  - Builds the transcript HTML shell and resolves bundled runtime resources.
- `Swift/ExampleChatTranscriptWebView.swift`
  - SwiftUI/WebKit wrapper for rendering transcript payloads inside the example
    app.
- `Swift/ExampleChatPlanProgressPill.swift`
  - PhotoSorter-only progress overlay for active agent plans.
- `Swift/AgentRuntime`
  - `ExampleChatRuntimeJSONValue.swift`
  - JSON value support still used by transcript payload models.
- `Swift/Transcript`
  - Shared shell display, streaming presentation, and support-block projection
    helpers used by the example transcript payload factory.

## Boundaries

- The old request construction, Responses streaming client, and tool-loop files
  are not part of this public example vendor surface.
- Non-renderer source archives and local machine paths must not be added here.
- Example-specific adaptation belongs outside the vendored resource files.

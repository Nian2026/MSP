# Shared Example Chat Transcript Renderer Manifest

This directory contains renderer files that are byte-for-byte shared by the iOS
examples. The example apps keep symlinks to these files from their local
`Vendor/ExampleChatTranscriptRenderer` directories so SwiftPM and Xcode can keep
using the same in-example paths while the duplicated source of truth lives here.

## Shared Surface

- `RuntimeResources`
  - Third-party markdown, math, highlighting, document, paged, and knowledge-map
    resources used by the example transcript WebView.
  - `RuntimeResources/Math/chat-unified-markdown.js` bundles
    unified/remark/rehype/micromark, MathJax, KaTeX, mhchemparser, and related
    browser markdown packages. Its package-level evidence is kept in
    `RuntimeResources/Math/chat-unified-markdown-THIRD-PARTY.json`.
  - `RuntimeResources/Math/legacy-spinner.apng` is a project-local UI asset
    documented by `RuntimeResources/Math/PROJECT-ASSET-PROVENANCE.md`.
  - Shared chat transcript runtime scripts that are identical in both examples.
- `Swift/AgentRuntime/ExampleChatRuntimeJSONValue.swift`
  - JSON value support used by transcript payload models.
- `Swift/Transcript`
  - Shared support models, shell display, streaming presentation, and
    support-block projection helpers that are identical in both examples.

## Not Shared Here

- Example-specific payload factories and workspace shell adapters.
- Transcript shell, WebView, and theme files that still differ between
  MSPPlaygroundApp and PhotoSorter.
- PhotoSorter-only UI helpers such as `ExampleChatPlanProgressPill.swift`.

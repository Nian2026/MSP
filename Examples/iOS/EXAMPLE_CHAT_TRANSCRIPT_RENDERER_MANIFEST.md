# Example Chat Transcript Renderer Manifest

This manifest records the current renderer surface used by the iOS examples.
It is intentionally scoped to example UI support, not the MSP protocol or SDK.

The byte-for-byte common renderer files live in
`Examples/iOS/Shared/ExampleChatTranscriptRenderer`. Each example keeps symlinks
from its local `Vendor/ExampleChatTranscriptRenderer` tree to that shared
surface so SwiftPM and Xcode can continue to use stable in-example paths. Files
that still differ remain as local per-example overlays.

This surface must not grow to include the legacy model request, Responses
streaming, or tool-loop files. Those files and non-renderer source archives have
been removed from the public example trees.

## Shared Core

- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/RuntimeResources`
  - Common third-party runtime assets and transcript scripts that are identical
    in both examples.
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/AgentRuntime/ExampleChatRuntimeJSONValue.swift`
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatShellTranscriptDisplaySupport.swift`
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingSupportBlockPresentationHelper.swift`
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingToolPresentationHelper.swift`
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportBlockProjector.swift`
- `Examples/iOS/Shared/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportModels.swift`

## MSPPlaygroundApp

Compiled Swift renderer files:

- `Examples/iOS/MSPPlaygroundApp/Adapters/ExampleChatTranscriptRenderer/ExampleChatTranscriptPayloadFactory.swift`
- `Examples/iOS/MSPPlaygroundApp/Adapters/ExampleChatTranscriptRenderer/ExampleChatWorkspaceShellTranscriptDisplaySupport.swift`
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/AgentRuntime/ExampleChatRuntimeJSONValue.swift` -> shared core
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptThemePreset.swift`
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptRendererShell.swift`
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptWebView.swift`
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatShellTranscriptDisplaySupport.swift` -> shared core
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingSupportBlockPresentationHelper.swift` -> shared core
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingToolPresentationHelper.swift` -> shared core
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportBlockProjector.swift` -> shared core
- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportModels.swift` -> shared core

Copied renderer resources:

- `Examples/iOS/MSPPlaygroundApp/Vendor/ExampleChatTranscriptRenderer/RuntimeResources` with shared-core symlinks and local overlay files

## PhotoSorter

Compiled Swift renderer files:

- `Examples/iOS/PhotoSorter/Adapters/ExampleChatTranscriptRenderer/ExampleChatTranscriptPayloadFactory.swift`
- `Examples/iOS/PhotoSorter/Adapters/ExampleChatTranscriptRenderer/ExampleChatWorkspaceShellTranscriptDisplaySupport.swift`
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/AgentRuntime/ExampleChatRuntimeJSONValue.swift` -> shared core
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatPlanProgressPill.swift`
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptThemePreset.swift`
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptRendererShell.swift`
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/ExampleChatTranscriptWebView.swift`
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatShellTranscriptDisplaySupport.swift` -> shared core
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingSupportBlockPresentationHelper.swift` -> shared core
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatStreamingToolPresentationHelper.swift` -> shared core
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportBlockProjector.swift` -> shared core
- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/Swift/Transcript/ExampleChatTranscriptSupportModels.swift` -> shared core

Copied renderer resources:

- `Examples/iOS/PhotoSorter/Vendor/ExampleChatTranscriptRenderer/RuntimeResources` with shared-core symlinks and local overlay files

## Removed From This Renderer Surface

- Legacy model request adapter files.
- Legacy Responses runtime/client files.
- Legacy request-builder and tool-loop files.
- Tests that only covered the removed legacy runtime/client/tool-loop surface.
- Non-renderer source archive directories.

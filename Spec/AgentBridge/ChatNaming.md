# ChatNaming capability

`ChatNaming` is an SDK-only metadata capability. It generates and persists a
display title plus an optional search description without entering the main
agent turn, exposing model tools, appending canonical timeline items, or
renaming the physical `.chat` package.

The capability is opt-in because automatic naming performs an additional model
request. A host may reuse its main model configuration, select a cheaper model,
or inject a completely custom `MSPChatTitleGenerating` implementation.

## Quick integration

```swift
let naming = try chatSession.makeChatNamingIntegration(
    modelConfiguration: mainModelConfiguration,
    namingConfiguration: .codexCompatible(model: "developer-selected-model"),
    onEvent: { event in
        await MainActor.run {
            // Project titleUpdated/searchDescriptionUpdated into SwiftUI,
            // UIKit, an indexer, or another host-owned presentation layer.
        }
    }
)

let conversation = runtime.makeConversation(
    configuration: conversationConfiguration,
    chatNaming: naming
)

let result = try await conversation.send(
    "Add automatic titles to the SDK",
    chatNamingInput: MSPChatNamingInput(
        text: "Add automatic titles to the SDK",
        pastedTextExcerpts: pastedTextExcerpts
    )
)
```

Passing no `chatNaming` integration preserves the base AgentBridge behavior and
performs no title request. The integration keeps the persisted Chat ID and its
coordinator together, so they cannot be accidentally wired to different Chats.
The naming model selection is intentionally outside
`MSPAgentConversationConfiguration`, so changing a future title model does not
recreate or reset the live conversation.

When an existing untitled `.chat` contains a stored preview candidate,
`makeChatNamingIntegration` starts historical backfill automatically. Set
`automaticallyBackfillsHistoricalTitle: false` when the host wants to schedule
that work itself. A registered historical backfill owns that Chat's initial
naming lifecycle, so an immediate follow-up `send` cannot race it with a title
based on the newer message.

`namingConfiguration.model` takes precedence over
`modelConfiguration.model`. Passing `nil` deliberately reuses the developer's
main model. Hosts that prefer a public lower-cost reference may pass
`MSPChatNamingConfiguration.codexReferenceModel` (`gpt-5.4-mini`) explicitly,
subject to provider availability.

For a custom provider or local model:

```swift
let naming = try chatSession.makeChatNamingIntegration(
    titleGenerator: MyChatTitleGenerator(),
    searchDescriptionGenerator: MySearchDescriptionGenerator(),
    namingConfiguration: .codexCompatible()
)
```

The search-description generator is optional for title-only integrations. It
is required when the host wants automatic description refresh after manual
renames, unless the title generator also conforms to
`MSPChatSearchDescriptionGenerating`. A provider-backed custom generator can
also use `request.chatID` to fork or query its own full canonical Chat history;
the built-in `.chat` integration supplies recent persisted user context
directly so the default path remains provider-neutral.

The built-in adapter uses strict JSON Schema string constraints, including
`minLength` and the title `maxLength`. OpenAI's fine-tuned Structured Outputs
subset may reject those type-specific keywords; use a custom generator when a
selected provider/model exposes a narrower schema dialect.

## Default lifecycle

The default policy is an independently authored MSP lifecycle designed for
provider-neutral title and retrieval metadata:

1. Start one independent metadata request from the first user input while the
   main turn continues; later sends do not retry the initial-title lifecycle.
2. Combine text parts and pasted-text excerpts, keep content after the last
   `## My request for Codex:` compatibility wrapper, and cap the seed at 2,000
   characters.
3. Use MSP's concise title and retrieval-description rules, then request strict
   structured output containing non-empty `title` and `description` fields.
   The SDK maps `description` to its public `searchDescription` metadata name;
   default output limits are 36 and 100 characters. The built-in Responses
   adapter concatenates those rules and the bounded seed into one isolated user
   input; custom generators still receive `instructions` and `prompt`
   separately for easier integration.
4. Use low reasoning and a 30-second timeout. The provider-neutral Responses
   adapter additionally disables tools, parallel tool calls, web/tool side
   effects, and response storage.
5. On model failure, project the already 2,000-character-bounded seed to plain
   single-line text and derive a fallback of at most 60 characters.
6. Check that the Chat is untitled before generation, check again after the
   model returns, and commit through a conditional `.onlyIfUntitled` write.
7. Within one coordinator/integration, coalesce concurrent requests for the
   same Chat into one in-flight request.
8. Let manual naming cancel pending work and win every race inside the built-in
   single-process writer domain.
9. Refresh `searchDescription` separately after a manual rename using the
   current persisted user context, prioritizing recent purpose and keywords;
   guard the result by both current title and persistence revision.
10. Automatically backfill an opened historical untitled Chat from its first
    preview candidate: the earliest non-empty stored user message or Goal
    objective. Provide a one-call derived-Chat integration that inherits the
    parent title before returning.
11. Keep every title event outside the canonical timeline.

Limits and policy switches are configurable through
`MSPChatNamingConfiguration`; the values above are defaults, not protocol
requirements. Developer-selected models, provider-neutral direct Responses
requests, SDK events, single-flight, revision compare-and-set, and post-model
race checks are intentional MSP integration and hardening layers. Derived Chats
copy both title and search description as an MSP metadata convenience.

The built-in description refresh uses recent persisted user text; custom
generators can use `request.chatID` to supply provider-owned history. The
fallback uses a local plain-text Markdown approximation, and Swift character
counting can differ from JavaScript UTF-16 length for emoji or combining
sequences. MSP exposes pasted excerpts as an explicit input part and the host
passes them through `chatNamingInput`.

## Manual rename, backfill, and inheritance

```swift
try await naming.setManualTitleAndRefreshSearchDescription("ChatNaming SDK")

let childNaming = try await childSession.makeDerivedChatNamingIntegration(
    inheritingTitleFrom: parentSession,
    modelConfiguration: mainModelConfiguration,
    namingConfiguration: .codexCompatible(model: "developer-selected-model")
)
```

The integration also exposes Chat-ID-bound `generateTitleIfNeeded`,
`backfillTitleIfNeeded`, `refreshSearchDescription`, `inheritTitle`, and
`cancelPendingNaming` operations. Advanced hosts that do not use
`MSPAgentChatStore` can construct `MSPChatNamingCoordinator` directly and use
the lower-level AgentBridge runtime overload. Manual title updates can preserve
the current search description (the default), replace it with
`.replace("...")`, or clear it with `.replace(nil)`.

`MSPAgentChatSession.setTitle` remains a persistence-level escape hatch. UI
rename actions should normally use the bound integration methods so pending
generation is canceled, lifecycle events are emitted, and optional description
refresh follows the same race guards.

`MSPAgentChatSession` stores the title, search description, source, timestamp,
and opaque revision in `manifest.json`. Writes preserve unknown manifest data,
do not modify `timeline.ndjson`, and do not move the package path.

## Writer ownership

The built-in `.chat` adapter performs each conditional read-modify-write under
one process-local package lock and atomically replaces `manifest.json`. A host
must give a package to only one writer process at a time. Apps that allow an
app, extension, CLI, or helper process to write the same package concurrently
must add an outer cross-process lock or provide another
`MSPChatTitlePersisting` implementation with cross-process transactions.

Creating multiple integrations for the same `.chat` also creates multiple
coordinators. Persistence compare-and-set still prevents duplicate commits, but
only requests made through the same integration share a model-generation
flight; keep one live integration per Chat to avoid duplicate model cost.

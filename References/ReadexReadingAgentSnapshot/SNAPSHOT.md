# Readex Reading Agent Snapshot

This directory is a public index for a local-only reference snapshot used as a
reading-mode behavior reference.

The extracted source subtree in this directory is intentionally ignored by Git
and is not part of the publishable repository surface. It is also not part of
the Model Shell Protocol Swift package targets.

## Purpose

This snapshot preserves the hand-written reading-mode agent implementation that
can inform a future `MSPAgentRuntime` extraction:

- model configuration and reasoning settings
- request body and prompt payload construction
- streaming lifecycle and presentation updates
- tool-call bridge logic
- support-block and completed-tool timeline presentation
- chat transcript rendering and update behavior
- relevant regression tests for chat/runtime/transcript behavior

## Local Source Scope

Locally restored copies may include reading-mode app runtime, model request,
tool bridge, streaming lifecycle, transcript rendering, and relevant regression
test sources. Those files are local-only reference material and must stay out of
the public Git surface.

## Local Test Scope

Locally restored regression tests may be used to guide MSP-native extraction,
but they are not part of the public MSP conformance suite.

## Extraction Rule

Use locally restored snapshot sources as evidence and source material only.
Public MSP SDK, `MSPAgentRuntime`, and iOS example app code should be
MSP-native and should not carry Readex-specific public names, app model
assumptions, or product-only dependencies.

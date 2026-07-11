# AgentBridge Specs

This directory contains AgentBridge-facing MSP design notes.

## Public Profiles

- `ExecCommandProfile.md`: current `exec_command` request, output, and parity
  notes.
- `ToolContracts.md`: model-facing tool schemas that currently exist in the
  Swift AgentBridge implementation.
- `CapabilityProfiles.md`: optional AgentBridge capability groups such as plan
  progress, goal tracking, plan mode, turn interrupt, and turn steering.
- `ChatNaming.md`: developer-facing automatic Chat title and search-description
  lifecycle, Responses adapter, persistence, and UI event integration.

## Release Boundary

Public AgentBridge profile and conformance contracts live in this directory and
under `Conformance/`. Local construction notes, parity audit drafts, and
unpublished source-review notes are not part of the public SDK/spec contract and
must stay out of the publishable Git surface.

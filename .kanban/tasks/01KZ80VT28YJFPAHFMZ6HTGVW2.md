---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: '[Router] Non-String-output tools bypass the elevation layer: ambient events lose per-tool identity/correlation'
---
Repo: this repo (FoundationModelsRouter). Discovered while implementing ^ew49xjj (delete `EventEmittingTool`/`connecting(_:)`).

`ToolElevation.wrapping` (and `ToolOutputCapping.wrapping`) only wrap a tool whose `Output` is `String`; any other `Output` type passes through both layers unwrapped (see `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift`'s `open(_:)` guard, pinned by `ElevatingToolTests`). Before ^ew49xjj, `instanceToolsWithElevation` also applied the `connecting(_:)` cast to **every** tool regardless of output type, so a non-String-output `EventEmittingTool` conformer had its own event route posting its own `tool`/`op`/`correlationID`. After the deletion, such a tool gets no per-call `ToolContext` binding at all; its ambient posts fall back to the session's turn-scope binding in `RoutedSessionActor` (`turnBindingToolStamp`/`turnBindingOpStamp`), which stamps `tool: "session"`, `op: "respond"`, and the turn's `completionToken` as `correlationID`. Per-tool identity and per-run correlation are silently lost for that class of tool, and no test covers the route.

## What
Decide and implement the intended contract for non-String-output tools' ambient event identity:
- Either extend the elevation layer to bind a per-call, per-tool-stamped `ToolContext` for non-String-output tools too (a binding-only wrapper that skips the pending-envelope/park machinery, which requires a `String` wire form), or
- Pin the current fallback (turn-scope `"session"`/`"respond"` stamps) as the documented contract with a test.

## Acceptance Criteria
- [ ] A test covers the ambient event route of a non-String-output tool composed through `makeSession(tools:)`
- [ ] The doc comments on `RoutedModel.makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)`, `ToolElevation.sessionMounted(_:sessionID:mailbox:sink:cappedToTokenLimit:)`, and `makeSession(tools:)` match the decided behavior (note: ^ew49xjj's review pass renamed `instanceToolsWithElevation` into these two helpers) #phase-1 #router-first
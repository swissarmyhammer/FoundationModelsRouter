---
assignees:
- claude-code
position_column: todo
position_ordinal: 9f80
title: One SessionConfiguration value drives makeSession
---
## Problem

`RoutedLLM.makeSession` takes nine defaulted parameters (Sources/FoundationModelsRouter/RoutedLLM.swift:156-166): `instructions`, `workingDirectory`, `recordingRoot`, `tools`, `budget`, `compactionPrompt`, `summarization`, `agentSpawn`, `discoveryPriming`. `makeGuidedSession` repeats all nine with `grammar` prepended. Every doc comment must cite the full ten-segment selector, and each new session capability grows both signatures. There is also no value a caller can hold, inspect, persist, or reuse that says "this is how my sessions are configured."

## Design shape

A plain struct, not a result builder: flat configuration is what structs are for, and the `Codable` requirement for restore falls out naturally. Defaulted memberwise fields make `SessionConfiguration()` the empty default. Optional fluent `with`-style modifiers can ride on top for call-site chaining. Result builders are for hierarchical content; this is not that.

## Proposed solution

1. Introduce one value type, `SessionConfiguration`: instructions, working directory, recording root, tool list, budget, compaction prompt, summarization, agent spawn, discovery priming, and grammar as a field (this merges the guided and plain surfaces). The value-typed parts are `Codable`; the non-codable parts (tool instances, spawn closure) are held by reference and represented by name for persistence.
2. Add `makeSession(configuration:)` as the primary factory. Keep the current nine-parameter form as a convenience that builds a configuration and forwards — no source break.
3. Fold `makeGuidedSession` into the same path: a configuration with a grammar vends a guided session. Deprecate the separate guided factory or keep it as a thin alias — decide and document.
4. Design the type as the SAME envelope task ^ne5g9jn persists in the sidecar for restore re-application: create-time and restore-time configuration must be one vocabulary, not two. That task's rehydration hook takes this type's non-codable parts by name.

## Acceptance

- `profile.standard.makeSession(configuration:)` vends a session identical in behavior to the current nine-parameter call.
- The existing call sites (examples, tests) compile unchanged through the convenience overload.
- A configuration with a grammar produces the same session `makeGuidedSession` produces today.
- The `Codable` slice of the type round-trips, ready for ^ne5g9jn to persist. #api
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzrwaaa7w094bvcaw3zj2azm
  text: |-
    Research results:

    - The nine-parameter public `makeSession` (Sources/FoundationModelsRouter/RoutedLLM.swift) forwards to the internal ten-parameter builder `makeSession(grammar:...)`. `makeGuidedSession` (Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift) forwards to the same builder with a grammar. The internal builder stays the one implementation.
    - Field types: `TokenBudget`, `CompactionPrompt`, `DiscoveryPriming` are value types with `Equatable`. `Summarization` is a value type without `Equatable`. `Grammar` is an enum with string payloads. None of these is `Codable` now. `SessionSidecar.AgentSpawn` is `Codable` already. Plan: add `Codable` to the five types, and add `Equatable` to `Summarization`. These additions do not break source.
    - Design: one new file Sources/FoundationModelsRouter/Session/SessionConfiguration.swift. `SessionConfiguration` holds the nine knobs plus `grammar`. A nested `SessionConfiguration.Persistable` is the `Codable` slice: it keeps each value-typed field and holds the tool NAMES in place of the tool instances. `configuration.persistable` derives it. Task ^ne5g9jn persists `Persistable` in the sidecar and matches tool names to app-supplied instances at restore time. This keeps one vocabulary for create time and restore time, and a decode-then-encode cycle does not lose the tool names.
    - Decision for item 3: keep `makeGuidedSession` as a thin alias that builds a configuration and forwards. Do NOT deprecate: a deprecation makes warnings at the six existing call sites, and the test gate permits zero warnings. The doc comment on `makeGuidedSession` records this decision.
    - Test harness: shared fixtures exist — `RouterTestFixtures`, `StubModelLoader`, `PlainTranscriptStubContainer`, `StubSessionBackend`, `AmbientEventPostingTool` (name "ambient-emitter"). `RoutedSessionActor` exposes nonisolated `grammar`, `autoCompactionBudget`, `autoCompactionPrompt`, `summarization`, `discoveryPriming`, `workingDirectory`, `tools` for assertions.
    - Duplication-rule risk: the `Persistable` member list mirrors the `SessionConfiguration` member list, and the two forwarding conveniences mirror each other. If the parsed duplication tool reports these, the recourse is a `// sah:allow duplication <reason>` marker; the mirror is the design.
  timestamp: 2026-08-11T17:00:58.055689+00:00
- actor: claude-code
  id: 01kzrwxm2fznx6arr7fvxnw07s
  text: |-
    Implementation landed, TDD order (test first, watched it fail, then the code):

    - New: Sources/FoundationModelsRouter/Session/SessionConfiguration.swift — `SessionConfiguration` (nine knobs plus `grammar`), defaulted memberwise init so `SessionConfiguration()` is the empty default, `persistable` computed property, and nested `SessionConfiguration.Persistable` (the `Codable`, `Equatable` slice; `toolNames` stands in for the tool instances). This is the envelope task ^ne5g9jn persists; its rehydration hook takes the tools by name.
    - New: Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift — 7 tests: empty configuration equals `makeSession()`, each knob matches the nine-parameter call, `recordingRoot` layout, grammar equals `makeGuidedSession`, defaults, and two Codable round-trips.
    - RoutedLLM.swift — added `makeSession(configuration:)` as the primary factory; the nine-parameter overload now builds a configuration and forwards to it; the extension header and the internal-builder docs state the new call flow.
    - GuidedGeneration.swift — `makeGuidedSession` now builds a configuration with the grammar and forwards to `makeSession(configuration:)`. Decision recorded in its doc comment: kept as a thin alias, NOT deprecated, because a deprecation makes warnings at the six existing call sites and the test gate permits zero warnings.
    - Conformance additions (no source break): `TokenBudget`, `CompactionPrompt`, `DiscoveryPriming`, `Grammar` gain `Codable`; `Summarization` gains `Equatable` and `Codable`.
    - The optional fluent `with`-style modifiers from the card's design-shape note are omitted: the card marks them "Optional", no acceptance criterion needs them, and mutable `var` fields already give per-field adjustment.
    - Duplication guard: `Persistable` mirrors the parent type by design; it carries a `// sah:allow duplication` marker with the reason. The parsed duplication tool reports zero findings over the changed set.

    Verification: `swift test` fully green — 827 + 27 + 24 tests pass; the one known issue is the pre-existing BoundedWait one, and the one build warning is the accepted vendored mlx-swift "missing creator for mutated node". No commit made, as directed.
  timestamp: 2026-08-11T17:11:30.639199+00:00
- actor: claude-code
  id: 01kzrwxy17s86qy1cyfnms2s68
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Session/SessionConfiguration.swift (new), Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift (new, 7 tests), Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift, Sources/FoundationModelsRouter/Compaction/TokenBudget.swift, Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift, Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Session/DiscoveryPriming.swift, Sources/FoundationModelsRouter/Guided/Grammar.swift. `swift test` green: 827 + 27 + 24 tests pass, 1 pre-existing BoundedWait known issue, 1 accepted vendored mlx warning.
    - next: /review
  timestamp: 2026-08-11T17:11:40.839354+00:00
position_column: doing
position_ordinal: '8180'
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
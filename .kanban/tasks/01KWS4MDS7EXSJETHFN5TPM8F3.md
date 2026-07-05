---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kws5jw6m8awgd6da8y8a5me6
  text: |-
    Implementation complete. Replaced `liveGenerateMaxTokens`/`liveGuidedMaxTokens` with a single `defaultMaxTokens = 8192` in `LiveModelLoader.swift`, threaded `maxTokens: Int?` through `LoadedLLMContainer` (ModelLoader.swift), the guided convenience methods (GuidedGeneration.swift), and `RoutedSession`/`RoutedSessionActor` (RoutedSession.swift, with a source-compatible single-arg convenience extension). Updated all 10 test-stub `LoadedLLMContainer` conformers to match the new protocol signature. Added two new tests: `SessionChokepointTests.respondThreadsMaxTokensOverride` and `GuidedGenerationTests.respondFollowingForwardsMaxTokensOverride`, both using a `MaxTokensSpy` actor to prove an explicit override reaches the container unchanged and omitting it reaches the container as `nil` (default lives only in `LiveModelLoader`).

    Verification: `swift build` and `swift build --build-tests` both green with no new warnings (only a pre-existing unrelated mlx-swift bundle warning). `swift test`: 157/157 unit tests pass; gated integration suite correctly skips without its opt-in env var.

    Adversarial double-check review launched; awaiting verdict before final handoff.
  timestamp: 2026-07-05T12:55:50.228791+00:00
- actor: claude-code
  id: 01kws5v7b0se194m6qkq1a0npv
  text: |-
    Adversarial double-check verdict: PASS. The reviewer independently re-ran `swift build`, `swift build --build-tests`, and `swift test` (157/157 pass, gated suite skips as expected) and confirmed: nil propagates unmodified through every layer with `maxTokens ?? defaultMaxTokens` coercion happening only in the three `LiveModelLoader.swift` call sites; no stale references to the deleted constants or old doc comments; all 10 test stub conformers genuinely implement the new parameter (none drop it silently); no ambiguous overload resolution between the new `extension RoutedSession` convenience wrappers and the two-arg protocol requirements; no asymmetry between the two new `MaxTokensSpy` test actors. No REVISE findings.

    All acceptance criteria met, all tests specified in the card added and passing. Leaving in doing for /review.
  timestamp: 2026-07-05T13:00:23.776619+00:00
position_column: doing
position_ordinal: '80'
title: Make live generation maxTokens a per-call parameter with a raised shared default
---
## What
`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` currently hardcodes two private constants that silently cap all live generation: `liveGenerateMaxTokens = 1024` (plain `respond`/`streamResponse`, passed as `GenerateParameters(maxTokens:)`) and `liveGuidedMaxTokens = 2048` (guided/grammar-constrained `respond`, passed as the required `Int` `GuidedGenerationLoop.run(maxTokens:)` argument). Both were introduced together in commit `29c6411` (milestone 7 live-wiring) as an arbitrary runaway-guard with no design-doc justification — confirmed by reading the task's kanban history, which never mentions a token budget.

Eliminate both constants in favor of one shared, per-call-overridable default of `8192` (no principled reason to keep guided at 2x plain). Thread a new `maxTokens: Int?` parameter through the whole generation call chain, where `nil` means "use the default."

1. `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift` — `LoadedLLMContainer` protocol: add `maxTokens: Int?` to `respond(to:instructions:)`, `streamResponse(to:instructions:)`, and `respond(to:instructions:following:)`.
2. `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` — replace `liveGenerateMaxTokens`/`liveGuidedMaxTokens` with one `defaultMaxTokens = 8192`. Each of the three `ModelContainer` conformance methods (`respond(to:instructions:)`, `streamResponse(to:instructions:)`, `respond(to:instructions:following:)`) takes the new `maxTokens: Int?` and uses `maxTokens ?? defaultMaxTokens` — via `GenerateParameters(maxTokens:)` for the two plain paths, and directly as the `GuidedGenerationLoop.run(maxTokens:)` argument for guided. Update the doc comment on the old constants (lines ~15-19), which describes two different budgets/ceilings and is no longer accurate.
3. `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift` — the default `LoadedLLMContainer` extension's `respond(to:instructions:following:)` (the stub fallback around line 159 that validates the grammar then throws `GenerationError.notWiredForLiveInference`) needs the new `maxTokens: Int?` parameter added to match the protocol (unused in the body). The `RoutedModel` convenience methods `respond(to:following:)` (line ~191), `respond(to:matching:)` (line ~278), and — under `canImport(FoundationModels)` — `respond(to:generating:)` (line ~347) each gain a `maxTokens: Int? = nil` parameter (these are concrete-type extensions, so default values compile fine here) and thread it down to the layer below.
4. `Sources/FoundationModelsRouter/Session/RoutedSession.swift` — `RoutedSession` protocol: change the `respond(to prompt: String)` and `streamResponse(to prompt: String)` requirements to take `maxTokens: Int?` (Swift disallows default argument values in protocol requirements), then add an `extension RoutedSession` with the old single-argument signatures as convenience wrappers defaulting to `maxTokens: nil`, so every existing single-arg call site across the codebase (e.g. `Sources/FoundationModelsRouter/Tools.swift:66`, `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:192`) keeps compiling unchanged. `RoutedSessionActor` (the sole conformer) implements the two-arg versions and threads `maxTokens` down to `container.respond(...)`/`container.streamResponse(...)`; its private `streamGenerating` helper (around line 256) needs the parameter threaded through too.
5. Update every test stub `LoadedLLMContainer` conformer to match the new protocol signature (add `maxTokens: Int?`, ignored in the body unless a new test needs to assert on it): `CannedLLMContainer` in `Tests/FoundationModelsRouterTests/SessionChokepointTests.swift`, `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`, `Tests/FoundationModelsRouterTests/TranscriptNestingTests.swift`, `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift`; `StubLLMContainer` in `Tests/FoundationModelsRouterTests/ResolveTests.swift`, `Tests/FoundationModelsRouterTests/ExamplesTests.swift`, `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`; `InstrumentedLLMContainer` in `Tests/FoundationModelsRouterTests/ForkConcurrencyTests.swift`; `GuidedStubContainer` and `DefaultGuidedContainer` in `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift`; `GuidedStubContainer` in `Tests/FoundationModelsRouterTests/GuidedShapesTests.swift`.
6. `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift` links `MLXLMCommon`/`MLXLLM` and constructs real `LiveModelLoader`-backed sessions — confirm it still compiles against the new protocol signatures (it calls `.respond(to:)` without `maxTokens`, which resolves through the new convenience overload, so no source change should be required, but it must be checked).

## Acceptance Criteria
- [ ] `liveGenerateMaxTokens` and `liveGuidedMaxTokens` no longer exist anywhere in the source tree; a single `defaultMaxTokens = 8192` constant in `LiveModelLoader.swift` is the only fallback value.
- [ ] `RoutedSession.respond(to:)` / `streamResponse(to:)` still compile and behave identically for every existing no-`maxTokens` call site (source-compatible).
- [ ] `RoutedSession.respond(to:maxTokens:)` accepts an explicit override that is observably threaded all the way to the `LoadedLLMContainer` call (verified by a stub that records the value it received).
- [ ] `swift build` and `swift build --build-tests` succeed with no new warnings.

## Tests
- [ ] Add a test in `Tests/FoundationModelsRouterTests/SessionChokepointTests.swift` (or a new focused test file) using a `LoadedLLMContainer` stub that records the `maxTokens` argument it receives; assert that `session.respond(to:maxTokens:)` with an explicit value (e.g. `4096`) is observed by the stub, and that omitting `maxTokens` (or passing `nil`) results in the stub observing `nil` (i.e. the router does not silently substitute its own default before the container boundary — the default lives in `LiveModelLoader` only).
- [ ] Add/extend a test in `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift` asserting `RoutedModel.respond(to:following:maxTokens:)` forwards an explicit `maxTokens` down to the guided container call.
- [ ] Run `swift test` — full existing suite (110+ unit tests) plus the new tests pass with no regressions.
- [ ] Run `swift build --build-tests` — confirms the gated `FoundationModelsRouterIntegrationTests` target (which is not exercised by `swift test` without the opt-in env var) still compiles against the new protocol signatures.

## Workflow
- Use `/tdd` — write the recording-stub test first (asserting the exact `maxTokens` value observed at the container boundary), watch it fail against the current hardcoded-constant behavior, then implement the parameter threading to make it pass.
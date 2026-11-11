---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m75e104b2dkbcf9bnepzz7n3
  text: |-
    Picked up. Research results:
    - `Router.sizeCandidates` and `slotMembership` read `candidatesBySlot`, thus after `.decision` is in the map, the decision candidates are sized. All unit-test resolves use stub metadata sources (no `Router(...)` with the default `HuggingFaceMetadataSource` resolves in a unit test), thus no network request. `RouterTestFixtures.profile` gets `decision: []`.
    - `footprintBytes(for:...)` must treat a decision-only ref as a generation model, else its precondition "a sized candidate is a member of at least one slot" is false after the change.
    - The Extras pool `holdIfResident` adds `sessionBytes` to the entry. A decision hold on a key that a slot of this resolve holds sends 0/0 and a 0 prompt-cache budget; it is not a new load, thus `finalize` runs once for the key.
    - Design: `SlotResolution.fallback: SlotFallback?` (`.flashModel`, text "fallback: flash model"), new `Verdict.notFitted` for each decision candidate in this task. `JointResolution.decision`. A new `DecisionSlotPlan` (Resolution/) gives the format: the flash fallback gets `GenericPromptFormat()` with no fetch; another decision model gets `DecisionFormatLoader`; a load failure logs and changes the decision slot to the flash fallback before any acquire.
    - A hold whose container is not `PooledLogits` gives a decision container whose model throws the error of `PooledDecisionContainer` (`notLogitsCapable`) at the first decision.
    - `StubDecisionContainer` + `StubDecisionModel` go to `Tests/FoundationModelsRouterTestSupport/`; that target and the public-surface target get the `FoundationModelsDecision` product (manifest dependency only, no new target).
  timestamp: 2026-11-11T13:51:13.035350+00:00
- actor: claude-code
  id: 01m75eybtpxdyyxqv2dzqq20sg
  text: |-
    Implementation notes:
    - Latent bug found and corrected: `ProfileDefinition.resolvingLocalModelPaths` (Core/LocalModelPath.swift) dropped the `decision` list, so each resolve used `defaultDecisionCandidates` (the Mapika ref) whatever the profile said. New test `LocalModelPathTests.profileResolvesTheDecisionCandidates`. Without the fix, `RouterTestFixtures.profile()` with `decision: []` still fetched the Mapika metadata.
    - `RealModelHarness.make` is synchronous and has no pool hold, thus its decision handle is a real `PooledDecisionContainer(model:pool:format:)` (new `package` init, lazy `PooledDecisionModel(ref:pool:)`) whose pool gives the harness container through `FixedContainerLoader`. `FixedContainerLoader` moved from the unit-test helpers to `FoundationModelsRouterRealModelSupport` (public) to keep one copy; the unit tests keep `llmHold` as an extension.
    - The handle footprint is the footprint that the acquire charged (`AdmittedResolve.footprintBytes`), so the decision handle of a shared key reports 0.
    - `SlotProgress` of `.decision` for a shared key: state `.ready`, chosen = flash ref, bytes 0/0 (the decision slot downloads nothing of its own).
    - The format fetch of a non-fallback decision model (R4 path) runs in the admission job, after the joint fit and before `markChosen`, so a failed load changes the slot to the flash fallback before any acquire.
  timestamp: 2026-11-11T14:07:15.286089+00:00
- actor: claude-code
  id: 01m75f2pr7zj67g4c3hx1x3te7
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` after removing the intermediates of this package (`.build/out/Intermediates.noindex/FoundationModelsRouter.build/Debug`): 0 warnings, 0 errors (only the build-system note "missing creator for mutated node", which is there before this change). One full `swift test --skip-build`: 2604 tests in 302 suites passed, 41 tests in 23 suites passed, 19 tests in 3 suites passed, 0 issues, exit 0.
    - source files: Core/ModelSlot.swift, Core/ProfileDefinition.swift, Core/LocalModelPath.swift, Resolution/SlotResolution.swift, Resolution/JointFit.swift, Resolution/DecisionSlotPlan.swift (new), Resolution/PooledDecisionContainer.swift, Resolution/ResolutionProgress.swift, Router.swift, LanguageModelProfile.swift, Session/RoutedSessionActorClosing.swift, Recording/SessionTreeRestoration.swift, Tracing/RouterTelemetry.swift, Package.swift.
    - test files: DecisionSlotResolveTests.swift, DecisionSlotJointFitTests.swift, DecisionSlotPlanTests.swift (new); TestSupport/StubDecisionContainer.swift, RealModelSupport/FixedContainerLoader.swift (new); changed CoreTypesTests, JointFitTests, LocalModelPathTests, OwningProfileTests, RoutedDeciderTests, RealModelHarnessTests, PooledDecisionContainerTests (import), Helpers/StubLogits, Helpers/RouterTestFixtures, Helpers/HandBuiltProfileFixtures, RealModelHarness, ResolutionProgressPublicSurfaceTests.
    - process note: one filtered test run was run two times with no code change between the runs (the second run gave the same 2 failures). Do not repeat this.
    - next: /review
  timestamp: 2026-11-11T14:09:37.543301+00:00
depends_on:
- 01M7468B410V0HR94ZBY52DT1Q
- 01M7469KKAMMEPD1RQHTRT8SF1
position_column: doing
position_ordinal: '80'
title: 'R2/R6/R7b: ModelSlot.decision through the resolve to LanguageModelProfile.decision (flash fallback)'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R2, R6 and R7, decisions D7 and D9. The new enum case breaks each exhaustive `switch` on `ModelSlot`, thus R2 and R6 are one task so that the commit compiles. In this task the decision slot ALWAYS uses the flash winner. The real fit of the decision candidates is the R4 task.

1. `Core/ModelSlot.swift`: add `case decision` (wire form `"decision"`). `poolRole` is `.llm` (D9). `poolKey(of:context:)` uses the profile context, the same as standard and flash. Update the DocC.
2. `Core/ProfileDefinition.swift`: add `.decision: decision` to `candidatesBySlot`.
3. `Resolution/JointFit.swift`, `Resolution/SlotResolution.swift`: `JointResolution` gets `let decision: ModelRef` and a decision `SlotResolution`, appended after flash. In this task it is the flash winner. Each decision candidate is recorded as not chosen, and the slot records "fallback: flash model" (add a verdict case or a field; give it a `description` text in `ResolutionFailure`/report rendering). The decision slot never makes the resolve fail.
4. `Router.swift`:
   - `acquisitionOrder` gets `.decision` after `.embedding`. The decision key can be the same key as the flash (or standard) key. Remove the comment "No two slots of one resolve share a key" and make the code correct for a shared key: one extra hold of the same pool entry, charged 0 more bytes, and `finalize` (preload) runs once for each key.
   - `AdmittedResolve` gets `decision: any LoadedDecisionContainer`. Get the format with `DecisionFormatLoader` (R7a) for a decision model that is not the flash fallback; the flash fallback uses `GenericPromptFormat()` with no fetch. Make `PooledDecisionContainer(hold:format:)`. When the container of the hold is not logits-capable (for example a stub LLM container of a test), the resolve does NOT fail: use a container whose `decisionModel` throws `PooledLogitsModelError.notLogitsCapable(ref)` at the first decision. When the format load fails, log it and use the flash fallback.
   - `chosenRef(of:in:)`, `beginSizing` progress map, and the resolve span winner attributes get `.decision`.
5. `LanguageModelProfile.swift` (R6): `public let decision: RoutedDecider`. `init` takes `decision:` after `embedding:` and calls `decision.registerOwningProfile(self)`. Update the type DocC (the list of handles).
6. Each other `switch` on `ModelSlot`: `Session/RoutedSessionActorClosing.swift` (`.decision: profile.decision.sessionDirectory`), `Recording/SessionTreeRestoration.swift` (`.decision` throws `slotNotInProfile`, the same as `.embedding`), `Compaction/Summarization.swift` if it switches on the slot. Update the 3 `LanguageModelProfile(` call sites: `Router.swift`, `Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift`, `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`. Add a stub decision container (`StubDecisionContainer` with a stub `DecisionModel`) to the test helpers for hand-built profiles.

Note: the default decision candidate is a Mapika GGUF. In the unit tests, the stub metadata sources do not know it, so it is sized as `metadataUnavailable` and the slot falls back to flash. Check that no unit test makes a network request for it.

## Acceptance Criteria
- [x] `ModelSlot.decision.poolRole == .llm`; its pool key has the profile context.
- [x] Each resolved profile has `profile.decision`, and `profile.decision.chosen == profile.flash.chosen` in this task.
- [x] The resolution of the decision slot records each candidate and "fallback: flash model".
- [x] A resolve with a shared decision/flash key takes one extra hold of the same entry, preloads once, and the pool footprint does not grow.
- [x] A profile over stub LLM containers resolves; a decision on it throws `notLogitsCapable`.
- [x] All existing tests pass with no change other than the call sites above.

## Tests
- [x] New `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: resolve with stub loader and stub metadata; `profile.decision.chosen` is the flash winner; resolution records the fallback; pool hold count and footprint for the shared key; `notLogitsCapable` at first decision with a stub container; a stub logits-capable container gives a decision.
- [x] Update `Tests/FoundationModelsRouterTests/CoreTypesTests.swift` for the wire form and pool role of `.decision`.
- [x] Run `swift test` once. All tests pass, no new warnings (clean build; see the memory note on cache-hit builds).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
1. **Shared key bytes.** `Router.acquire` sends `sessionBytes` to `acquireHold`, and `ModelPool.holdIfResident` adds them to the entry. For a decision hold whose key a slot of this resolve already holds, send `footprintBytes: 0`, `sessionBytes: 0` and 0 prompt-cache budget. The `footprintBytes` of the decision handle in this case is 0, so that a host does not count the flash model two times. One rule for the whole work: a decision candidate that is the same pool key as a model that this resolve allocated costs 0 bytes (R8 and R4 use the same rule).
2. **Tests that change.** `Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift` (about line 301) expects `[.standard, .flash, .embedding]`; `Tests/FoundationModelsRouterTests/JointFitTests.swift` (about line 209) expects `error.slots.count == 3`. Decision: `ResolutionFailure` does NOT list the decision slot (the decision slot never blocks), so `slots.count` stays 3; the progress map gets `.decision`. Update both tests.
3. **New public-surface test** (plain `import FoundationModelsRouter`, not `@testable`) in `Tests/FoundationModelsRouterPublicSurfaceTests/`: `progress.slots[.decision]` reaches `.ready` with its chosen ref and byte counts for a shared key; `profile.decision.makeSession(state:)` compiles; `fraction` reaches 1.
4. **More switches.** Also update `Resolution/JointFit.swift` `verdict(blockedBy:)` (about line 702) and `Resolution/SlotResolution.swift` `blockedText` (about line 211). The decision slot never blocks the trio; give `.decision` the same text as `.flash`/`.embedding` and add a comment that the case does not occur.
5. **Stub location.** Put `StubDecisionContainer` (and a stub `DecisionModel`) in `Tests/FoundationModelsRouterTestSupport/` (plan R7), not in the test helpers, because the public-surface tests need it. `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift` (about line 201) makes a real `PooledDecisionContainer` over the flash hold with `GenericPromptFormat()`, not a stub.
6. **No network in unit tests.** `Router` uses `HuggingFaceMetadataSource()` by default. A test router with no stub source would fetch `Mapika/decider-4b-GGUF` on each resolve. Fix it: the shared test fixtures (`RouterTestFixtures`, `HandBuiltProfileFixtures` and the other `ProfileDefinition(` helpers that resolve) pass `decision: []`, or their stub sources throw for an unknown repo. Criterion: a unit resolve makes no fetch for the default decision ref (test with a recording metadata source).

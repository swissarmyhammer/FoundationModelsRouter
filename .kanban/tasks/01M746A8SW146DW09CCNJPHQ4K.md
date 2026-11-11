---
assignees:
- claude-code
depends_on:
- 01M7468B410V0HR94ZBY52DT1Q
- 01M7469KKAMMEPD1RQHTRT8SF1
position_column: todo
position_ordinal: '8480'
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
- [ ] `ModelSlot.decision.poolRole == .llm`; its pool key has the profile context.
- [ ] Each resolved profile has `profile.decision`, and `profile.decision.chosen == profile.flash.chosen` in this task.
- [ ] The resolution of the decision slot records each candidate and "fallback: flash model".
- [ ] A resolve with a shared decision/flash key takes one extra hold of the same entry, preloads once, and the pool footprint does not grow.
- [ ] A profile over stub LLM containers resolves; a decision on it throws `notLogitsCapable`.
- [ ] All existing tests pass with no change other than the call sites above.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/DecisionSlotResolveTests.swift`: resolve with stub loader and stub metadata; `profile.decision.chosen` is the flash winner; resolution records the fallback; pool hold count and footprint for the shared key; `notLogitsCapable` at first decision with a stub container; a stub logits-capable container gives a decision.
- [ ] Update `Tests/FoundationModelsRouterTests/CoreTypesTests.swift` for the wire form and pool role of `.decision`.
- [ ] Run `swift test` once. All tests pass, no new warnings (clean build; see the memory note on cache-hit builds).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
1. **Shared key bytes.** `Router.acquire` sends `sessionBytes` to `acquireHold`, and `ModelPool.holdIfResident` adds them to the entry. For a decision hold whose key a slot of this resolve already holds, send `footprintBytes: 0`, `sessionBytes: 0` and 0 prompt-cache budget. The `footprintBytes` of the decision handle in this case is 0, so that a host does not count the flash model two times. One rule for the whole work: a decision candidate that is the same pool key as a model that this resolve allocated costs 0 bytes (R8 and R4 use the same rule).
2. **Tests that change.** `Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift` (about line 301) expects `[.standard, .flash, .embedding]`; `Tests/FoundationModelsRouterTests/JointFitTests.swift` (about line 209) expects `error.slots.count == 3`. Decision: `ResolutionFailure` does NOT list the decision slot (the decision slot never blocks), so `slots.count` stays 3; the progress map gets `.decision`. Update both tests.
3. **New public-surface test** (plain `import FoundationModelsRouter`, not `@testable`) in `Tests/FoundationModelsRouterPublicSurfaceTests/`: `progress.slots[.decision]` reaches `.ready` with its chosen ref and byte counts for a shared key; `profile.decision.makeSession(state:)` compiles; `fraction` reaches 1.
4. **More switches.** Also update `Resolution/JointFit.swift` `verdict(blockedBy:)` (about line 702) and `Resolution/SlotResolution.swift` `blockedText` (about line 211). The decision slot never blocks the trio; give `.decision` the same text as `.flash`/`.embedding` and add a comment that the case does not occur.
5. **Stub location.** Put `StubDecisionContainer` (and a stub `DecisionModel`) in `Tests/FoundationModelsRouterTestSupport/` (plan R7), not in the test helpers, because the public-surface tests need it. `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift` (about line 201) makes a real `PooledDecisionContainer` over the flash hold with `GenericPromptFormat()`, not a stub.
6. **No network in unit tests.** `Router` uses `HuggingFaceMetadataSource()` by default. A test router with no stub source would fetch `Mapika/decider-4b-GGUF` on each resolve. Fix it: the shared test fixtures (`RouterTestFixtures`, `HandBuiltProfileFixtures` and the other `ProfileDefinition(` helpers that resolve) pass `decision: []`, or their stub sources throw for an unknown repo. Criterion: a unit resolve makes no fetch for the default decision ref (test with a recording metadata source).

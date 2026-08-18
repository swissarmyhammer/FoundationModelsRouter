---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: Move the three hand-built gated-model profile copies onto the shared RealModelHarness
---
`^d02ryqj` added `Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift`, which builds a real `LanguageModelProfile` over an already-loaded container. It is the same consolidation commit d82c33e made for `RealModelContainer.load`.

Three near-identical copies of that body remain, and `^d02ryqj` did not touch them:

- `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift`, `buildProfile(id:container:cacheDir:recordingsDir:)`
- `Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift`, `buildProfile(id:container:cacheDir:recordingsDir:)`
- `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift`, `buildProfile(container:cacheDir:recordingsDir:)`

## Why they were left

Two of the three are gated suites with a 20-minute time limit against the 30B model. `^d02ryqj` could not run either one, so it could not prove the change safe. The third is in a separate test target that cannot see the integration target, so it needs its own answer.

## What the move needs

- `RealModelHarness.make` must gain the router identity the round-trip suite needs. That suite builds a SECOND profile stamped with the first router's id, so a restore reads the same recording root, and it reads `router.id` afterwards. So the shared function needs a `routerId` parameter and must return the `Router` beside the profile.
- The evals target cannot import the integration target. Decide where the shared function lives for it: either `FoundationModelsRouterTestSupport`, which both targets already depend on, or a copy that stays and is recorded as deliberate.

## Acceptance Criteria

- [ ] The integration target holds one profile builder, not three
- [ ] `CompactionRoundTripIntegrationTests` and `SessionTreeRestorationIntegrationTests` call it
- [ ] Both gated suites are run once, green, and the run's wall clock is recorded on this card
- [ ] The evals runner either calls the same function or states in its doc comment why it cannot #compaction #real-model #tests
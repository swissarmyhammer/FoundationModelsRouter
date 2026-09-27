---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3htzd98y2snt5ynzj8jratv
  text: |-
    Research and decisions:
    - JointFit had a within-trio "share one resident container" path (ReservationKey, sessionBytes closure). When flash skips the standard model, this path can not run (the embedding role is different). I removed it: JointFit.resolve has no `sessionBytes` parameter now, and ResolutionFailure no longer renders the "earlier slot already reserved the weights" note. The Router preload dedup for two slots on one key is removed for the same reason. The pool (ModelPool) is not changed.
    - New verdict `Verdict.sameModelAsStandard`. The flash slot records the standard model with this verdict and never sizes it.
    - New error `SameGenerationModelFailure` (profileName, model). `Router.resolve` throws it after beginSizing and before any metadata fetch or load, when `ProfileDefinition.sharedGenerationModel` is not nil (both lists name only the same one model). The progress phase becomes `.failed(description)`.
    - With a derived context, a standard candidate whose trio is blocked by flash moves to the next standard candidate. With an explicit context, resolution fails with ResolutionFailure (flash: sameModelAsStandard).
    - Integration profile: `RealModels.flash` was Muse Glimmer (same as standard, on purpose, because only one Muse Glimmer repo exists). I changed it to `mlx-community/Qwen3-4B-4bit`, a small real model that PromptCacheBudgetIntegrationTests and RealToolAnswerComparisonTests already load. Tools/RecordCompactionFixture gets `RecordingScript.flashModel` with the same model.
    - Test profiles with one ref in both slots were changed: ResolveTests (heals, dual-fail: flash gets a second candidate), PooledResidencyTests (pair tests: two refs, oneTrioFootprint budget; `sharedPairTrioFootprint` removed), SharedGenerationQueueContentionTests (the resolved pair now asserts two queues; the hand-built pair keeps the one-queue drill), JointFitTests (shared-reference tests removed; multitool profile gets a separate flash model, window 56_880).
  timestamp: 2026-09-27T16:25:38.344312+00:00
- actor: claude-code
  id: 01m3htzm0d5cw5k1h6vhztjpf2
  text: |-
    ### implement — changed
    - evidence: Sources: Resolution/JointFit.swift, Resolution/SlotResolution.swift, Core/ProfileDefinition.swift, LanguageModelProfile.swift, Router.swift; README.md; Tests: DistinctGenerationSlotsTests.swift (new), JointFitTests.swift, ResolveTests.swift, PooledResidencyTests.swift, SharedGenerationQueueContentionTests.swift, Helpers/ResidencyStubs.swift, RealModelSupport/RealModels.swift; IntegrationTests: Support/GatedRealProfile.swift, PinnedChatTemplateDateIntegrationTests.swift; Tools/RecordCompactionFixture (main.swift, RecordingScript.swift). Targeted run: 76 tests in 6 suites passed. `swift build --build-tests --package-path IntegrationTests` passed.
    - next: /test
  timestamp: 2026-09-27T16:25:45.229917+00:00
- actor: claude-code
  id: 01m3hv54rdp48csc4622a0g7f9
  text: |-
    ### test — green
    - evidence: `swift package clean && swift build --build-tests` — exit 0, no source warnings (only the SwiftPM "missing creator for mutated node" note on the mlx bundle, from the build system). `swift test` — 1451 tests in 174 suites passed (2 known issues are the intended `withKnownIssue` checks in BoundedWaitTests and RealModelHarnessTests), plus 17 and 19 tests in the two other test products; 0 failed, 0 skipped. `swift build --build-tests --package-path IntegrationTests` — Build complete.
    - next: /commit
  timestamp: 2026-09-27T16:28:46.221700+00:00
position_column: doing
position_ordinal: '80'
title: 'Router: resolve never gives the same model to the standard and flash slots'
---
## What
Decision (user, 2026-09-26): the `standard` and `flash` slots of one resolved profile must never use the same model.

Reason: a tool such as the multitool `searchTools` runs a synchronous selection call on `flash` inside an open submission on `standard`. Each model has one FIFO work queue. If both slots are the same `ModelRef`, the selection call waits behind the submission that waits for it. The queue then throws `GenerationQueueError.waitInsideOpenSubmission`. Thus a profile with one model in both slots cannot run tools of this type.

- `Sources/FoundationModelsRouter/Resolution/JointFit.swift`: when it selects the `flash` slot (after `standard`), skip each candidate that is equal to the `ModelRef` selected for `standard`. If no other candidate fits, resolve throws a clear error that names both slots and the model.
- `Sources/FoundationModelsRouter/Core/ProfileDefinition.swift`: if the `standard` and `flash` candidate lists contain only the same one `ModelRef`, report it early (for example a throwing validation in `Router.resolve` before any load). Do not change the public init signature.
- Document the rule in the doc comment of `ProfileDefinition`, in `README.md`, and in the doc comment of `LanguageModelProfile.flash`.
- Update each test, example and `IntegrationTests/` profile that puts the same model in both slots (about 44 files make a `ProfileDefinition`; find the ones with the same ref in both slots). Give them two different stub refs.

## Acceptance Criteria
- [ ] No resolved `LanguageModelProfile` has `standard` and `flash` on the same `ModelRef`.
- [ ] A profile whose only `flash` candidate is the `standard` model fails to resolve with a clear error, and loads no model.
- [ ] A profile that lists the `standard` model first for `flash`, followed by a different model, resolves `flash` to the different model.
- [ ] The rule is in the docs.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add tests in `Tests/FoundationModelsRouterTests/` (for example `JointFitTests` and a resolve test) for the three cases above, with stub loaders.
- [ ] `swift test` passes, and the output shows the full count of tests run.
- [ ] `IntegrationTests/` compiles (`swift build --build-tests` in `IntegrationTests/`).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router-api
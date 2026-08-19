---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqxyzx1061s332c94ednx
  text: |-
    ## Audit at `dd55fcd2c` — LIVE, and not a duplicate of `^we8n8nk`

    This card is the PROFILE BUILD. `^we8n8nk` is the CONTAINER LOAD. They are different work.

    `RealModelHarness.make` (`Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift:65`) has one caller: `AutoCompactionTriggerIntegrationTests.swift:419`. All three copies of the build remain:

    - `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift:154`
    - `Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift:106`
    - `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift:80`

    `RealModelHarness.swift:22-24` names this card as the follow-up. `make` returns only the profile, so what this card says it needs — a `routerId` parameter, and a returned `Router` — is correct.

    ## Do this card and `^we8n8nk` in one session

    Both cards touch the same continuity runner, and both answer the same cross-target question. One session for the two of them.
  timestamp: 2026-08-18T23:19:12.607587+00:00
- actor: claude-code
  id: 01m0byam44465a3hyczjsh6qpm
  text: |-
    ## Done, with ONE acceptance criterion left open

    The integration target holds one profile builder, and both of its suites call it. The evals runner states in its doc comment why it cannot. The gated-run criterion is NOT met and stays open — see the last section.

    ### `routerId` in, and NO `Router` out

    The card says `make` "needs a `routerId` parameter and must return the `Router` beside the profile". Half of that is right.

    The parameter is genuinely needed: both suites build a SECOND profile stamped with the first router's id so a restore reads the same recording root. It is now `routerId: ULID = .generate()`.

    The returned `Router` is not needed, and was not added. `LanguageModelProfile.router` is `private`, but `RoutedModel.routerId` is `public let`, and `router.id` was the ONLY thing either suite ever read off the returned router — `CompactionRoundTripIntegrationTests` at three sites, `SessionTreeRestorationIntegrationTests` at three. Every one now reads `profile.standard.routerId`, which is the idiom the continuity eval runner already used. Returning a `Router` would have handed callers a handle to a residency the router owns, for one field they can already reach.

    ### Provable without a gated run

    Both callers are 20-minute gated suites against a 30B model, which is exactly why `^d02ryqj` left the copies alone. Compile is not proof, so the harness was split so the move could be measured:

    - `RealModelHarness.makeResolution(slot:model:context:)` and `makeDurableRecording(slot:model:context:recordingsDir:routerId:)` need no container at all.
    - `make` now takes `any LoadedLLMContainer` rather than `MLXFoundationModelsContainer`. Nothing in it needed the concrete type; the concrete type cannot be built without a resident MLX model, and the protocol can be stood in for. `LoadedLLMContainer`'s own doc already names stub containers as its unit-test seam.

    `RealModelHarnessTests` (ungated, 11 ms) then reads back every fact the two suites depend on: the definition name, each slot's `SlotResolution` compared against the literal each hand-built copy produced, the context threaded to all three slots, the one router id every handle carries, the `routerId` parameter being honoured against a fresh one, and the `session.json` the durable recording actually writes to disk, decoded and checked field by field.

    **Proved able to fail.** The harness was deliberately broken three ways — `contextTokens` forced back to the profile default, the `routerId` parameter dropped, the definition name changed — and the suite recorded 7 issues across 3 tests. The definition-name break did NOT fail, because that assertion compared the build against the constant it was built from; it now pins the literal instead.

    ### What is preserved, exactly

    - `CompactionRoundTripIntegrationTests` resolved at `Self.context`; it passes that.
    - `SessionTreeRestorationIntegrationTests` passed no `contextTokens:` at all, so every slot took `SlotResolution`'s own default. It now states `ProfileDefinition.defaultContext`, and `statingTheProfileDefaultMatchesOmittingIt` is the equality that makes those two spellings the same profile.
    - `definitionName` moved from `"test"` to `"real-model-harness"`. Nothing reads it: no gated suite, and not the sidecar, which is written with `profile: nil`. Checked by grep across the whole test tree.

    Review also required an assertion the move exposed: three restore sites passed a `routerId` and never asserted the restored session carried it. All three now do.

    ### The evals runner, and why it cannot call this

    Its `buildProfile` stays, with the reason in its doc comment. Measured, not assumed: hosting the shared function in `FoundationModelsRouterTestSupport` builds clean under `swift build --build-tests` and then breaks `swift build -c release`, which compiles that target against a router with no testability. Declaring that target a `.testTarget` does not rescue it — release still compiles it and still fails, while the leaf test targets are not compiled in release at all. `LanguageModelProfile`'s initializer is internal, so the function needs `@testable`, so it can only live in a leaf test target, and SwiftPM cannot share source between two of those. The full measurement is on `^we8n8nk`.

    ### Acceptance criteria

    - [x] The integration target holds one profile builder, not three.
    - [x] `CompactionRoundTripIntegrationTests` and `SessionTreeRestorationIntegrationTests` call it.
    - [ ] **Both gated suites are run once, green, and the run's wall clock is recorded on this card.** NOT DONE. The session that did this work was instructed not to run a gated suite and not to set `FM_ROUTER_INTEGRATION_TESTS`, and was told instead to make the move provable without one. That is what `RealModelHarnessTests` is. This criterion still wants a real 20-minute run of each suite before the card closes, and nothing here substitutes for it — no ungated test reaches the real model's own behavior.
    - [x] The evals runner states in its doc comment why it cannot call the same function.

    `swift test` 1099 pass; `FM_ROUTER_COMPACTION_SMOKE=1 swift test` 1099 pass; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift build -c release` clean; `review working` 0 findings.
  timestamp: 2026-08-19T02:41:39.460040+00:00
- actor: claude-code
  id: 01m0byb1zx3at7kqyfkzfaj16d
  text: |-
    ### implement — changed
    - evidence: this card's own files: `Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift`, `RealModelHarnessTests.swift` (new), `CompactionRoundTripIntegrationTests.swift`, `SessionTreeRestorationIntegrationTests.swift`. `swift test` 1099 pass; `FM_ROUTER_COMPACTION_SMOKE=1 swift test` 1099 pass; `swift build -c release` clean; `review working` 0 findings.
    - next: `/review` for the code. The card does NOT close on that: acceptance criterion 3 — both gated suites run once, green, wall clock recorded — is still open, and needs a session that is allowed to set `FM_ROUTER_INTEGRATION_TESTS`.
  timestamp: 2026-08-19T02:41:53.661103+00:00
position_column: doing
position_ordinal: '8480'
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
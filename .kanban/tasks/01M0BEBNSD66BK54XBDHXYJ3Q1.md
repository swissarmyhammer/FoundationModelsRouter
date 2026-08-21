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
- actor: claude-code
  id: 01m0bzpmvdgvh9tzvnxzc6nzfg
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit c349f05) — the engine returned 0 findings, 0 confirmed, 0 refuted, 14 validator passes attempted, 0 failed. The CODE on this card is clean. The card does NOT advance, because acceptance criterion 3 is still open: `Both gated suites are run once, green, and the run's wall clock is recorded on this card`. That run needs `FM_ROUTER_INTEGRATION_TESTS`, which this work deliberately did not set, and this review was instructed not to set either. Nothing here substitutes for it — no ungated test reaches the real model's own behavior.
    - verified from source, not from the summary:
      - `RealModelHarness.make` takes `container: any LoadedLLMContainer` and `routerId: ULID = .generate()`, and returns `LanguageModelProfile` alone. No `Router` is returned.
      - Two of the three hand-built copies moved onto it. `CompactionRoundTripIntegrationTests` calls it twice, the second with `routerId: routerId` read off `profile.standard.routerId`. `SessionTreeRestorationIntegrationTests` calls it from its own thin wrapper.
      - The third copy did NOT move, and that is what criterion 4 asks for. `CompactionContinuityEvalRealSubjectRunner.buildProfile` stays, and its doc comment states the measured reason: the shared function needs `@testable import FoundationModelsRouter`, `@testable` reaches only a leaf test target, and SwiftPM cannot share source between two leaf test targets.
      - No assertion in `RealModelHarnessTests` is tautological. Each was read:
        - `everySlotResolvesToWhatTheHandBuiltCopiesDid` compares against a `SlotResolution` spelled out in literals, not derived from the function.
        - `statingTheProfileDefaultMatchesOmittingIt` compares two independently-declared spellings. `SlotResolution.init` defaults `contextTokens: Int = ProfileDefinition.defaultContext`, so this fails if either that default or `makeResolution`'s threading of `context` drifts.
        - `durableRecordingWritesTheSidecarARestoreReads` decodes the `session.json` on disk and checks each field against a literal or a locally-made value.
        - `builtProfileStampsEverySlot` pins the literal `"real-model-harness"`, not `RealModelHarness.definitionName`. This is the assertion the implementer replaced, and the replacement holds.
        - `profileStampedWithAnExistingRouterIdContinuesThatRoot` checks a passed-in id comes back out AND that an unstamped build differs, so a `make` that ignored the parameter fails.
    - next: a session that is allowed to set `FM_ROUTER_INTEGRATION_TESTS` runs both gated suites once, green, and records the wall clock here. The card then re-reviews and closes. It stays in `review` until then.
  timestamp: 2026-08-19T03:05:41.997526+00:00
- actor: claude-code
  id: 01m0d64n8tw25fhhgrfkg5hrv5
  text: |-
    ### finish iteration 1 — stuck
    - implement: no-change — the code criteria are closed, and the last review returned 0 findings
    - blocker: acceptance criterion 3 needs both gated suites run once with `FM_ROUTER_INTEGRATION_TESTS`, green, with the wall clock recorded here. The card records that such a run is a sanctioned event, and this session has no sanction for it.
    - next: a person sanctions the gated run of `CompactionRoundTripIntegrationTests` and `SessionTreeRestorationIntegrationTests`, then the card re-reviews and closes
  timestamp: 2026-08-19T14:17:27.066512+00:00
- actor: claude-code
  id: 01m0hby2jrdyya81mp1smqtkp7
  text: |-
    ## The last open criterion is closed, and it needed no source change

    The three earlier sessions left criterion 3 open and named one blocker: the gated run needs `FM_ROUTER_INTEGRATION_TESTS`, and no session had permission to set it. That blocker no longer exists. Commit 1db2b56 deleted the 16 environment variables and made the selection structural, so the run is now a plain command against the nested package.

    ### What the tree holds today, read from source

    The card was written before three moves, and each of them changed one of its answers:

    - `RealModelHarness` is no longer in the integration target. Task `^cvsh3m9` made the router initializers `package` and moved the harness to `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`, a plain target the root package publishes as a product. Every test target can import it, in both packages.
    - The gated suites moved to `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/` (commit 1db2b56).
    - The eval runner CALLS `RealModelHarness.make` now (task `^bh97dp7`). Criterion 4 offers a choice — call it, or state why not — and the tree takes the better half.

    So criteria 1, 2 and 4 were already true when this session opened the card, and this session added nothing to them. Criterion 3 is what was left.

    ### The gated run

    `swift test --package-path IntegrationTests --filter 'CompactionRoundTripIntegrationTests|SessionTreeRestorationIntegrationTests'`

    3 tests in 2 suites, all green, 209.5 s of test time. Per test: 17.3 s for the round trip, 104.6 s for the fork tree, 87.6 s for tool calling after a restore. The table is on the card.

    The two models were already in the Hugging Face cache — `Qwen2.5-3B-Instruct-4bit` (1.6 GB) and `Muse-Glimmer-30B-4bit` (18 GB) — so no download time is inside those numbers. A cold machine pays for the download on top.

    The fork tree at 104.6 s is 87 percent of the two-minute budget. That agrees with the three runs of 2026-08-20 in that suite's own doc (94.1, 114.1, 116.4 s), and it says nothing new: task `^bpwfbyz` already carries bringing that suite well inside the budget.

    ### Found while reading, and filed as `^zz6kam0`

    Four more suites of the integration target still build a `LanguageModelProfile` by hand: `LanguageModelSessionBackendTests`, `TranscriptReconstructionIntegrationTests`, `RealToolTurnComparisonTests` and `RecordingHandleIntegrationTests`. Each one is the same body — real container, one `JSONLRecorder`, the same `DurableRecording` arguments, one shared gate set across `.standard` and `.flash`, `SlotResolution` at `ProfileDefinition.defaultContext`. Three of the four even copy the harness's `UnusedEmbeddingContainer`.

    They are not in this card's scope. This card names three copies and those three are gone. The four go to `^zz6kam0`, which records the per-file differences the survey measured — most of all `RealToolTurnComparisonTests`, whose embedding stub calls `Issue.record` as a tripwire that the harness stub does not have.
  timestamp: 2026-08-21T05:15:40.504573+00:00
- actor: claude-code
  id: 01m0hbybaev6r66atx2c8adwhj
  text: |-
    ### implement — no-change
    - evidence: no source file changed. All four criteria were verified against the tree and all four now hold. Criteria 1, 2 and 4 already held: `RealModelHarness.make` is at `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`, and `CompactionRoundTripIntegrationTests`, `SessionTreeRestorationIntegrationTests` and `CompactionContinuityEvalRealSubjectRunner` all call it. Criterion 3 is closed by this session's run: `swift test --package-path IntegrationTests --filter 'CompactionRoundTripIntegrationTests|SessionTreeRestorationIntegrationTests'` — 3 tests in 2 suites green, 209.5 s (17.3 / 104.6 / 87.6 s per test). Root `swift test` green: 1025 tests in 96 suites and 77 tests in 9 suites. `swift build --build-tests -Xswiftc -warnings-as-errors` clean in the root package and in `IntegrationTests`.
    - board: new card `^zz6kam0` filed for the four hand-built profile copies that remain in the integration target and were never in this card's scope.
    - next: `/review`. The card is in `doing` with every box checked.
  timestamp: 2026-08-21T05:15:49.454947+00:00
position_column: doing
position_ordinal: '80'
title: Move the three hand-built gated-model profile copies onto the shared RealModelHarness
---
`^d02ryqj` added `RealModelHarness`, which builds a real `LanguageModelProfile` over an already-loaded container. It is the same consolidation commit d82c33e made for `RealModelContainer.load`.

Three near-identical copies of that body remained, and `^d02ryqj` did not touch them:

- `CompactionRoundTripIntegrationTests`, `buildProfile(id:container:cacheDir:recordingsDir:)`
- `SessionTreeRestorationIntegrationTests`, `buildProfile(id:container:cacheDir:recordingsDir:)`
- `CompactionContinuityEvalRealSubjectRunner`, `buildProfile(container:cacheDir:recordingsDir:)`

## Why they were left

Two of the three are gated suites with a time limit against a large real model. `^d02ryqj` could not run either one, so it could not prove the change safe. The third is in a separate test target that could not see the integration target, so it needed its own answer.

## What the move needs

- `RealModelHarness.make` must gain the router identity the round-trip suite needs. That suite builds a SECOND profile stamped with the first router's id, so a restore reads the same recording root, and it reads `router.id` afterwards. So the shared function needs a `routerId` parameter and must return the `Router` beside the profile.
- The evals target cannot import the integration target. Decide where the shared function lives for it: either `FoundationModelsRouterTestSupport`, which both targets already depend on, or a copy that stays and is recorded as deliberate.

## Where the code is now (2026-08-21)

The tree moved after this card was written, and some of the answers above moved with it:

- `RealModelHarness` is at `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`. Task `^cvsh3m9` made the router initializers `package`, and it moved the harness to that plain target. The root package publishes the target as a product, so EVERY test target can import it. This is what closed the cross-target question above: the eval runner does not need a copy any more.
- The two gated suites are at `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/`, in the nested `IntegrationTests` package (commit 1db2b56).
- `make` takes `routerId: ULID = .generate()` and returns the profile alone. It returns NO `Router`. `RoutedModel.routerId` is public, and `router.id` was the only field either suite ever read off a router.
- `RealModelHarnessTests` in the unit target proves the whole build with no model, because `make` takes `any LoadedLLMContainer` instead of the concrete MLX type.
- There is no `FM_ROUTER_INTEGRATION_TESTS` variable any more. Commit 1db2b56 made the selection structural. Earlier comments on this card say criterion 3 waits for that variable; the run below is what that criterion asks for, done the new way.

## The measured gated run (2026-08-21)

`swift test --package-path IntegrationTests --filter 'CompactionRoundTripIntegrationTests|SessionTreeRestorationIntegrationTests'`

3 tests in 2 suites, all green. 209.5 seconds of test time, 220.5 seconds with the build.

| suite | test | wall clock |
| --- | --- | --- |
| CompactionRoundTrip | the whole round trip | 17.3 s |
| SessionTreeRestoration | the fork tree | 104.6 s |
| SessionTreeRestoration | tool calling after a restore | 87.6 s |

Every test is inside the two-minute `integrationTestBudgetMinutes` limit. The fork tree at 104.6 s is the dearest, which agrees with the three runs of 2026-08-20 that suite's doc records (94.1, 114.1, 116.4 s).

## Found, and moved to its own card

Four more suites of the integration target build a `LanguageModelProfile` by hand: `LanguageModelSessionBackendTests`, `TranscriptReconstructionIntegrationTests`, `RealToolTurnComparisonTests`, `RecordingHandleIntegrationTests`. This card names three copies, and those three are gone, so criterion 1 is closed here. The other four are new work on card `^zz6kam0`.

## Acceptance Criteria

- [x] The integration target holds one profile builder, not three
- [x] `CompactionRoundTripIntegrationTests` and `SessionTreeRestorationIntegrationTests` call it
- [x] Both gated suites are run once, green, and the run's wall clock is recorded on this card
- [x] The evals runner either calls the same function or states in its doc comment why it cannot #compaction #real-model #tests
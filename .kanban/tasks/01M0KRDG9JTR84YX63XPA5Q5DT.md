---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ksfwhghp4bx4zj9kd0n3tp
  text: |-
    ### Picked up — box load and research

    Box load at the start, as the card asks. `uptime` gives `up 15:50, 3 users, load averages: 10.27 12.36 13.24`. `ps -Ao pcpu,comm -r | head -3` gives Total War WARHAMMER III at 789 percent CPU and sourcekit-lsp at 105.9 percent. The box is under the same GPU-heavy game that runs 6 and 7 measured under. No user process was stopped. No probe that can hang was run.

    A prior run of this step stopped on an API quota limit after it read the code. It made no source edit, and the working tree is clean.

    Research:

    - The test is `endToEnd()` of the suite `IntegrationTests` in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. The card and the run table name it by its display name, `resolve real profile, then generate, embed, guide, fork, and record`. There is no type named `RealModelEndToEndIntegrationTests`.
    - The test resolves `realProfile`, which names `RealModels.standard` in the `.standard` slot, `RealModels.flash` in the `.flash` slot and `RealModels.embedding` in the `.embedding` slot. Both generation slots name one repository, so the loader builds two resident containers, not three — `realProfileResidentContainerCount` reads that off the profile.
    - The test then drives four real generation turns: a plain turn, a guided JSON turn, a turn on a fork, and a turn on the parent after the fork is released. It also embeds two documents.
    - The test builds `LiveModelLoader` directly and states no `samplingMode`, so every turn takes the provider default, which samples at temperature 0.6 out of a clock-seeded PRNG. That is the spread the card reports.
    - No turn states a token ceiling, so each one takes `LiveModelLoader`'s own `defaultMaxTokens` of 8192. `GatedRealModelBudget.responseTokenCeiling` is 4096.
    - `RoutedSession.respond(to:maxTokens:)` and `RoutedModel.respond(to:matching:maxTokens:)` both accept a ceiling, so a ceiling needs no production change.
    - `RealToolTurnComparisonTests` measures each phase with `ContinuousClock` and prints one line. This card takes the same shape.

    Next: add the per-phase clock, then measure the split in isolation.
  timestamp: 2026-08-22T03:51:04.496108+00:00
- actor: claude-code
  id: 01m0ktnyjwpxe6rxqhyyesqbg3
  text: |-
    ### Isolation measurements, and what the per-phase clock says

    All measured with `swift test --package-path IntegrationTests --filter 'IntegrationTests/endToEnd'`, on the box under the game (load average above 10). The `--filter` string matters: `IntegrationTests\.` matches the sibling eval target's suites and ran the wrong tests. `IntegrationTests/endToEnd` selects this test alone.

    Baseline, with the per-phase clock added and nothing else changed — 55.8 s:

    | phase | seconds |
    |---|---|
    | resolve | 5.37 |
    | plainTurn | 22.38 |
    | embed | 0.03 |
    | guidedTurn | 5.21 |
    | forkTurn | 20.60 |
    | parentTurn | 2.00 |

    The whole cost is the two first turns of a session, 43 of 55.8 seconds. Each is one short prompt answered by the 30B, so the cost is the `<think>` block.

    Then the `@MainActor` question the coordinator raised. Measured, not assumed. `ResolutionProgress` is `@MainActor @Observable`, and it is the only main-actor thing the body reads, so the annotation comes off and the progress reads hop with `await MainActor.run`. `Router` is an actor and `RoutedModel` carries no isolation, so nothing else needed a hop. Second run — 35.4 s:

    | phase | before | after |
    |---|---|---|
    | resolve | 5.37 | 5.38 |
    | plainTurn | 22.38 | 22.65 |
    | embed | 0.026 | 0.026 |
    | guidedTurn | 5.21 | 4.63 |
    | forkTurn | 20.60 | 1.03 |
    | parentTurn | 2.00 | 1.50 |

    The total fell, but the annotation is not the cause. Each phase that the main actor could touch stayed where it was. One phase moved, the fork turn, from 20.6 to 1.0 seconds, and that phase is a sampled 30B turn whose `<think>` block is a different length on every run. The `@MainActor` removal bought nothing measurable. It is kept because the target's rule asks for it, and the card says so.

    That measurement names the true cause: the sampling. So `samplingMode` pins `.greedy`, and each of the four turns now passes `GatedRealModelBudget.responseTokenCeiling` where it stated no ceiling before. Third run — 57.1 s, and repeatable:

    | phase | seconds |
    |---|---|
    | resolve | 5.51 |
    | plainTurn | 22.52 |
    | embed | 0.026 |
    | guidedTurn | 5.23 |
    | forkTurn | 22.24 |
    | parentTurn | 1.42 |

    Argmax gives the fork turn a full `<think>` block every run rather than a lucky short one, so 57.1 s is the honest repeatable number where 35.4 was a lucky draw. No assertion is weakened and the budget is not raised.

    `RealModels.standard` stays, as the card's plan asks when the point of the test is the real profile. This is the one test of the target that drives `Router.resolve(profile:reporting:)` end to end over the real Hub — real sizing, real joint fit, two real containers co-resident. Every other gated suite calls `RealModelContainer.load` and never reaches the resolver, so a smaller generation model here would stop proving that the standard profile resolves at all. Thinking is never disabled.

    Next: two runs of the whole target.
  timestamp: 2026-08-22T04:11:51.772035+00:00
- actor: claude-code
  id: 01m0kx8kzf4m05kshdzhz0d0yt
  text: |-
    ### implement — changed

    - box load: the game ran for every measurement. `uptime` gave load average 10.27 at the start, 12.03 before run 8 and 14.60 before run 9. Total War WARHAMMER III held 789 percent CPU. No user process was stopped, and no probe that can hang was run. There was no quiet box to measure on, and the card records that.
    - isolation, before: 55.8 s. The per-phase clock gives the split — resolve 5.37, plainTurn 22.38, embed 0.03, guidedTurn 5.21, forkTurn 20.60, parentTurn 2.00. The two first turns of a session are 43 of 55.8 seconds.
    - isolation, after: 57.1 s, and repeatable — resolve 5.51, plainTurn 22.52, embed 0.026, guidedTurn 5.23, forkTurn 22.24, parentTurn 1.42. The number went up against the 55.8 because argmax removed a lucky short fork turn, so 57.1 is the honest repeatable cost.
    - whole target, run 8: 57.5 s. Whole target, run 9: 58.2 s. Both under half of `integrationTestBudgetMinutes`, so box 1 ticks on its first clause, not on its "or" clause. Each run was `swift test --package-path IntegrationTests`, exit 0, 29 measured tests.
    - `@MainActor`: measured, not assumed, as the coordinator asked. Removing it moved no phase — plainTurn 22.38 to 22.65, resolve 5.37 to 5.38, embed 0.026 to 0.026. The 20.6-to-1.0 fall in the fork turn was the sampling, and pinning argmax proved it by putting that turn back at 22.2. The annotation was not load-bearing for cost. It is kept off because the target's rule asks for it, and the suite doc says exactly that.
    - `RealModels.standard` is unchanged, and `RealModels.standard` itself was never edited. This is the one test of the target that reaches `Router.resolve(profile:reporting:)`.
    - what changed: a per-phase wall-clock line under a new `endToEndPhase` tag; `samplingMode` pinned to `.greedy` on the `LiveModelLoader` the test builds; `GatedRealModelBudget.responseTokenCeiling` on each of the four turns; `@MainActor` off the test with the `ResolutionProgress` reads inside `await MainActor.run`; the suite's "What it NO LONGER proves" section; and rows 8 and 9 of the run table with the box load.
    - follow-on card: `MLX path: whether the ToolContext bound around respond() arrives` is now nearest the limit at 60.6 and 118.7 seconds, 99 percent of the budget, with the widest spread of the table. Filed as ^s49ya8p, tagged `integration`, `real-model`, `test-debt`, and named in the margin section of `integrationTestBudgetMinutes`.
    - files: `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`, `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift`
    - root `swift test`: exit 0, 1032 tests in 98 suites and 83 tests in 10 suites. `swift build --build-tests --package-path IntegrationTests`: exit 0.
    - next: review.
  timestamp: 2026-08-22T04:57:00.655427+00:00
position_column: doing
position_ordinal: '80'
title: '`resolve real profile, then generate, embed, guide, fork, and record` measured 89.8 seconds, 75 percent of the two-minute budget'
---
Filed by task ^6ww73dm, which moved `RealToolTurnComparisonTests` under half of `integrationTestBudgetMinutes`. The two whole-target runs of 2026-08-21 after that move (runs 6 and 7 in the table in the doc comment of `integrationTestBudgetMinutes`) measured this test of `RealModelEndToEndIntegrationTests` at 89.8 and 55.0 seconds. The earlier runs measured 46.6, 48.7, 44.9, 84.9 and 60.9. The 89.8 is 75 percent of the budget and the largest number of runs 6 and 7. The box ran a GPU-heavy game for both runs, so some of the spread is the box; measure on a quiet box first.

The test is `endToEnd()` of the suite `IntegrationTests`, in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. No type named `RealModelEndToEndIntegrationTests` exists.

## Acceptance Criteria

- [x] The test measures under half of `integrationTestBudgetMinutes` across two runs of the whole target, or the card records why it cannot and what was tried
- [x] No assertion is weakened and the budget is not raised
- [x] The suite doc states what the conversion no longer proves, as `SessionTreeRestorationIntegrationTests` does
- [x] The run table in `integrationTestBudgetMinutes` records the new measurements #integration #real-model #test-debt
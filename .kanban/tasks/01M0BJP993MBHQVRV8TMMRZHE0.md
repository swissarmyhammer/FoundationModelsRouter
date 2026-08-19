---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0d2etnynbvagfjg4kx8j7rm
  text: |-
    ### Measured, 2026-08-19 — the 20-minute limit is not off by a little, it is off by about 10x

    A gated run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --no-parallel` at `f1dd39e` reached this tier and was stopped by hand partway through the fact-retention tier. What it measured of the continuity tier is complete, and it settles this card's claim with a number rather than an analogy.

    Evidence log: `scratchpad/gated-full-continuity-evidence.log`.

    ## What the tier did

    ```
    ✘ Suite CompactionContinuityEvaluationIntegrationTests failed after 1200.639 seconds with 3 issues
    ✘ ... recorded an issue at CompactionContinuityEvaluationTests.swift:430:6:
        Time limit was exceeded: 1200.000 seconds
    ```

    The model load was not the cost — it took 3.4 s, timed on its own line, which is `^aktsp2e`'s instrumentation working.

    **One sample used the whole limit.** `sample=1/10 task=codename-and-owner` drove 13 steps and reached `elapsed=1197.2s` before the limit fired. Its per-step costs are not uniform: the three dearest steps took **280.7 s, 260.6 s and 206.4 s**.

    Samples 2 to 10 then ran to the end of the suite in no time at all, every step reporting `replyBytes=0 folds=0 took=0.0s`. That is cancellation, not work. A reader of the tail alone would take those zeros for measurements, which is worth noting because that is exactly the misreading `^9cw5g6n` corrected for the other tier.

    ## The two aggregate failures follow from the cancellation

    ```
    result.aggregateValue(.mean(of: CompactionContinuityMetric.foldOccurred)) → 0.1
    result.aggregateValue(.mean(of: CompactionContinuityMetric.answersCorrect)) >= 0.8 → false
    ```

    `foldOccurred` of 0.1 is 1 of 10 tasks, and the 1 is the only task that ran. These two are NOT evidence of a compaction defect. They are what a tier reports when 9 of its 10 samples were cancelled. Do not carry them onto a defect card.

    ## What this card should now do

    The limit is not a wrong number to nudge. At about 1200 s for one sample of ten, the tier needs on the order of **200 minutes**, not 20. The choices are the same shape as `^6ssbakk`'s and the arithmetic is now available:

    - state a measured limit for 10 samples, which is roughly 3.3 hours and probably not a limit anyone runs by habit
    - cut the sample count, as the fact-retention tier did with its representative subset
    - cut the per-sample cost — 13 steps at up to 280 s each is the driver, and the filler steps were deliberately grown to force a fold

    Note the interaction with `^6ssbakk`: that card derived the fact-retention subset limit from the DEAREST measured sample rather than the mean, because the spread was 1.78x. The spread here is worse — 280.7 s against steps that return in under a second — so a mean would understate it by more.

    **Not yet measured:** what a complete continuity run costs. This run never finished one. The figure above is a lower bound from a single sample.
  timestamp: 2026-08-19T13:13:05.982163+00:00
- actor: claude-code
  id: 01m0dfy8gy1qc22e6bvt82ddz6
  text: Task ^k0d30s4 sets a two-minute budget for each integration and eval test. This budget replaces the direction to raise or keep long limits for the real-model suites. A test that cannot finish in two minutes must become smarter or boot from a recording. It must not get a larger limit.
  timestamp: 2026-08-19T17:08:43.166295+00:00
position_column: todo
position_ordinal: '9080'
title: The 20-minute limit on the continuity eval tier is an analogy, not a measurement
---
Filed from the backlog audit at `dd55fcd2c`, as the narrow residue of `^y0mhcdq`. That card said both gated evals go over one shared limit of 20 minutes. That is no longer true, and the card is closed. This card holds the one part that is still true.

## The residue

`gatedEvalSuiteTimeLimitMinutes = 20` now applies to the continuity suite alone (`Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluationTests.swift:246`).

The two compaction fact-retention tiers each measured a limit of their own:

- `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:1424` — the subset tier, 30 minutes
- `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:1454` — the whole-dataset tier, 120 minutes

`Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift:78-92` states the rule: the shared ceiling applies "when the suite has measured no ceiling of its own".

The continuity tier measured none. `GatedEvalSerialGate.swift:81` still gives its source as an analogy: "Matches `CompactionRoundTripIntegrationTests`". No gated run of the continuity suite has ever been timed end to end at the current dataset size and the current model.

## Work

Time the continuity suite end to end in a gated run. Write the measured duration on this card. Then set the continuity tier its own measured constant, the same as the two fact-retention tiers have, and state the measurement in the doc comment.

Keep the stated purpose of the limit: to bound a hung real-model load. The new value must still serve it.

## Acceptance Criteria

- [ ] A gated end-to-end run of the continuity suite is timed, and the duration is written on this card
- [ ] The continuity tier has its own time-limit constant, set from that measurement with headroom
- [ ] The doc comment of the new constant states the measurement, not an analogy
- [ ] `GatedEvalSerialGate.swift:81` no longer names `CompactionRoundTripIntegrationTests` as the source of a value the continuity suite uses
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` reports no time-limit issue from the continuity suite #eval #test-debt
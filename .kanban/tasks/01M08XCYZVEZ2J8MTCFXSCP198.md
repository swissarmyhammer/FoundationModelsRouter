---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqz3nh7cgwp3d6f8pmabd
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. 7 seeds, a floor of 0.9, and provider sampling that is not pinned — all unchanged.

    Today's gated run confirms that the tier has no tolerance: 4 of 6 measured seeds carried the fact, and the mean was 0.333.
  timestamp: 2026-08-18T23:19:13.781974+00:00
- actor: claude-code
  id: 01m0cv3zmrj3y6r24vynrbxwe6
  text: |-
    ## Research — what the run really measured, and what the recipe allows

    `gated-crit5.log` of 2026-08-18, read line by line:

    ```
    counts: retained=2 answerMissedFactSummaryCarriedIt=2 summaryLostFact=2 foldProducedNoSummary=0 unrecognizedSample=0
    result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) -> 0.3333333333333333
    ```

    So the two numbers on this thread are two different measurements, and the earlier comment put them side by side without saying so:

    - the SUMMARY carried the key phrase on 4 of the 6 measured seeds (`factInSummary=true` on `budget-cap-tool-and-owner`, `encryption-algorithm`, `env-file`, `three-facts-long-project-brief`) — 0.667.
    - the ANSWER carried it on 2 of 6 — 0.333, which is the `FactRetention` mean the tier asserts on.

    The two failure classes split evenly, 2 and 2. `answerMissedFactSummaryCarriedIt` is `^e814b60`'s to fix and is not this card's. What it proves here is that one number covers two steps.

    ## The recipe DOES allow a pin

    `CompactionEvalRealModelContainer.load(samplingMode:unexpectedContainerType:)` already takes a sampling mode, and `CompactionContinuityEvalRealSubjectRunner` already passes `.greedy` for exactly this reason. `CompactionEvalRealSubjectRunner` passes nothing, and its comment says: "This tier scores a key-phrase search over an answer rather than the answer's exact text, so it does not need the argmax pin the continuity tier carries."

    Measurement refutes that comment. The two runs of 2026-08-17 ran identical fold code and differed on one seed, `env-file`, which answered with the key phrase in one run and refused in the other. A key-phrase search over a SAMPLED answer is still a draw, because the draw decides whether the model states the phrase at all.

    ## What the tier will assert, and why

    1. Pin `.greedy`. It removes the variance rather than budgeting for it, it costs no wall clock, and the container already carries the parameter.
    2. Say what the floor really means at a given seed count. 0.9 over 7 seeds admits only 7 of 7, because 6/7 is 0.857. Stated as an arithmetic the code computes, beside the floor, with an ungated test.
    3. Assert the summary side and the answer side apart, against the same floor. The fold must write a summary that carries the fact; the resumed session must then answer with it. The floor is one number because the first is a necessary condition for the second — a tier that misses the summary bar can never make the answer bar. Today's run showed the two at 0.667 and 0.333, and one mean hid it.

    The floor itself stays at 0.9. compaction_plan.md section 5 states it, and lowering a bar to make a red tier green would hide `^e814b60` rather than measure it.

    Criterion 1 asks for two gated runs of identical code with identical verdicts. That needs a gated run, which is ruled out for now, so the box stays open.
  timestamp: 2026-08-19T11:04:50.584477+00:00
- actor: claude-code
  id: 01m0cw6a2znetm78txzf2kae46
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift. `swift test` — 1107 tests in 117 suites, 0 failures, 1 pre-existing known issue (`BoundedWaitTests`). Done with `^6ssbakk` in one change.
    - what this card got: `.greedy` pinned in `CompactionEvalRealSubjectRunner`; `compactionEvalFactRetentionRequiredSamples(of:)` beside the floor, with the seed-count table in the floor's own doc; `expectFactRetention(of:)` asserting the fold share and the answer share apart, each naming what it measured and what the seed count needs; a `retention: summary=k of n answer=k of n` line in the report. Five new ungated tests in `CompactionEvalTierBarTests` and three in `CompactionEvalFactRetentionReportTests`.
    - open: criterion 1's FIRST half — two gated runs of identical code agreeing — needs a gated run. The second half is met, so the box is ticked with that stated on it.
    - next: `/review`
  timestamp: 2026-08-19T11:23:35.391386+00:00
position_column: doing
position_ordinal: '8480'
title: The 7-seed gated subset can only pass FactRetention at 7 of 7 — 6 of 7 is 0.857, under the 0.9 bar, so the tier has no tolerance for model sampling
---
Found by the gated subset run of 2026-08-17 21:42 while measuring `^fm5ddk9`.

## What happens

`compactionEvalFactRetentionFloor` is `0.9`, and `compactionEvalRepresentativeSeeds` holds 7 seeds. `FactRetention` scores one bit per sample, so the only means the tier can produce are `k/7`:

| retained | mean |
|---|---|
| 7 | 1.000 |
| 6 | 0.857 |
| 5 | 0.714 |

`6/7 = 0.857` is under `0.9`. So the subset tier passes at 7 of 7 and at no other count: the stated bar of "at least 0.9" is, on this tier, "every seed, every run".

## The run that showed it

Two runs of the same tier, against code whose fold behaviour is identical:

- 2026-08-17 20:xx (recorded on `^fz49qds`): 7 of 7 retained, mean 1.0, PASSED in 1644.7 s.
- 2026-08-17 21:42 (recorded on `^fm5ddk9`): 6 of 7 retained, mean 0.857, FAILED in 1675.3 s.

The one seed that moved is `env-file`. It answered `I don't have access to that project's files or secrets, so I can't confirm where its API key is stored.` where the earlier run had answered with the key phrase. Nothing about the fold changed between the two runs — every sample of both runs discarded its fold and answered from the original transcript.

`^fz49qds` already recorded the cause in its own words: this runner "leaves the provider's own sampling in place rather than pinning `.greedy`, so answer lengths move between runs of identical code". What it did not record is that a 7-sample tier turns any single sampled refusal into a suite failure.

## Why this is its own task

It is independent of `^fm5ddk9`. Once folds are applied and `FactRetention` measures a summary rather than the original turns, the tier still passes only at 7 of 7 — a bar with no tolerance against a sampling model is a flaky gate whatever it is measuring.

Three answers exist and the choice is a person's:

1. Pin the runner's sampling to `.greedy` so identical code gives identical answers, and keep the bar. That makes the tier deterministic and makes a red run mean something.
2. Widen the subset, so a single sampled refusal is not the whole difference. Every added seed costs about 235 s of wall clock, and `^fz49qds` sized the tier against a 30-minute limit that the last run used 27.9 minutes of. There is no room without raising the limit.
3. State the bar in samples rather than in a mean, so the tier says what it really requires.

Prefer 1: it removes the variance rather than budgeting for it, and it costs no wall clock.

## What landed, 2026-08-19

Answers 1 and 3 together, plus a split the gated run of 2026-08-18 made necessary. The floor itself stays at 0.9, because compaction_plan.md section 5 states it and lowering a bar to make a red tier green would hide `^e814b60` rather than measure it.

- **The sampling is pinned.** `CompactionEvalRealSubjectRunner` now loads with `.greedy`, as `CompactionContinuityEvalRealSubjectRunner` already did. The old comment said a key-phrase search does not need the pin; measurement refutes it, because the draw decides whether the model states the phrase at all. `GatedEvalSerialGate`'s own doc used the decoding difference as its reason for rejecting one shared container, and now states the eviction argument instead, which survives the pin.
- **The bar states the tolerance it has.** `compactionEvalFactRetentionRequiredSamples(of:)` computes the smallest count that clears the floor, by the same `>=` the assertion applies, so the two can never disagree. The floor's own doc carries the table: the subset needs 7 of 7 and may lose 0; the whole dataset needs 22 of 24 and may lose 2. `CompactionEvalTierBarTests` holds it, and `expectFactRetention(of:)` states it in the message of a failing run.
- **The two steps are measured apart.** `expectFactRetention(of:)` asserts the floor twice: once on the share of samples whose FOLD wrote a summary carrying the key phrase, and once on the share whose ANSWER carried it. One number for both, because the summary is a necessary condition for the answer. The run of 2026-08-18 measured those at 4 of 6 and 2 of 6, and reported the second alone. The table now prints a `retention: summary=k of n answer=k of n` line, so a red run is attributable without reading every stanza.

The second failure class, `answerMissedFactSummaryCarriedIt`, stays `^e814b60`'s to fix. What this card changed is that the tier no longer reports it under the same number as a fold that dropped the fact.

## Acceptance Criteria

- [x] Two gated subset runs of identical code produce identical verdicts, or the tier's bar states the tolerance it really has — the SECOND half is met: the bar states its tolerance in code, in the floor's own doc, and in the message of a failing run. The first half is NOT proven. `.greedy` is pinned and argmax consumes no randomness, but showing two gated runs agree needs two gated runs, and a gated run is ruled out for now.
- [x] The relationship between the seed count and the floor is stated where the floor is declared, so a subset that cannot express the bar cannot be chosen silently
#compaction #eval #real-model
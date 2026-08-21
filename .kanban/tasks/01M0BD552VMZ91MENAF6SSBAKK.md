---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjr3f7ey97n02fap8ae95d
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. `compactionEvalSubsetTimeLimitMinutes` is still 30.

    Note that this card is not `^y0mhcdq`, which the audit closed as stale. The two cards name different constants and different suites.
  timestamp: 2026-08-18T23:19:18.247755+00:00
- actor: claude-code
  id: 01m0bt03zkb0mxddxbmrbd7bcb
  text: |-
    ## One figure on this card is a division — do not carry it forward

    `^9cw5g6n` criterion 2 forbids any card from deriving a per-sample cost by dividing a run's wall clock by its sample count. This card's line "against about 235 s each in the run `^fz49qds` measured" is exactly such a division: 1644.7 s over seven samples. `compactionEvalSubsetTimeLimitMinutes` no longer states it, and the comparison should not be read as a measured rate.

    The card's OWN figures are clean and stay. The trail timed each sample apart, and this card's log shows the samples ran one at a time — sample 1's four lines complete before sample 2's first line, and so on to sample 7. So 295.1, 197.4, 352.0, 260.9, 269.9 and 250.7 seconds are each one sample's own work, and their mean of 271.0 s is a measurement rather than a division.

    `compactionEvalFullDatasetTimeLimitMinutes` now rests on that 271.0 s: 24 samples is 6504 seconds, which is 108.4 minutes against the 120-minute ceiling.
  timestamp: 2026-08-19T01:26:00.947030+00:00
- actor: claude-code
  id: 01m0cv3jcxfstg130qtzzm40ag
  text: |-
    ## Research — every figure re-checked against `gated-crit5.log`

    Read the log, not the card. Each figure holds:

    - model load `took=3.5s`, stated on its own line, apart from every sample.
    - six per-sample totals, each read off that sample's own `answer returned elapsed=` line: 295.1, 197.4, 352.0, 260.9, 269.9, 250.7 s. They add to 1626.0 s. Mean 271.0 s. Spread 352.0 / 197.4 = 1.78.
    - `Suite CompactionEvaluationIntegrationTests failed after 1800.045 seconds`.
    - the seventh sample left only its `fold started` line, and `unreached: 1 of 7 seeds never ran — three-facts-support-escalation`.
    - `exited with unexpected signal code 6` stands AFTER the `counts:` and `unreached:` lines, so the report printed first.

    `compactionEvalSubsetTimeLimitMinutes` is still 30 at HEAD.

    ## The derivation this card gets

    Two figures, both from the samples the trail timed apart:

    1. What the seven really cost, as far as anything is measured. The six measured samples cost 1626.0 s. Nothing has ever timed `three-facts-support-escalation`, so it is charged the DEAREST measured sample, 352.0 s. With the 3.5 s load that is 1981.5 s — 33.0 minutes.
    2. The bound. The six samples spread by 1.78x, so a run whose seeds all land at the dear end costs more than (1). Every sample at the dearest measured cost is 7 x 352.0 + 3.5 = 2467.5 s — 41.1 minutes.

    The limit is 42 minutes: the next whole minute above the bound in (2). Margin over the bound is 0.9 minutes; margin over (1) is 9.0 minutes.

    The mean is NOT the basis. Criterion 1 asks the tier to end on its own assertion, and a limit sized on the mean (7 x 271.0 + 3.5 = 31.7 minutes) is under half the measured spread away from a run it would cut short.

    ## Two consequences

    - `CompactionEvalRepresentativeSubsetTests.subsetSizeBand` is `6...8`, and its doc says the upper bound is what the limit was measured against. That is no longer true: 8 samples at the dearest rate is 46.9 minutes, over the 42-minute limit. The band goes to `6...7`.
    - `compactionEvalFullDatasetTimeLimitMinutes` is 120, derived at 24 x the MEAN of 271.0 s. On the dearest-sample basis 24 samples is 140.8 minutes, over its own limit. That constant belongs to the whole-dataset tier, not to this subset card, so it gets its own card.
  timestamp: 2026-08-19T11:04:37.021348+00:00
- actor: claude-code
  id: 01m0cw65b8yjans5xm72e6s754
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift. `swift test` — 1107 tests in 117 suites, 0 failures, 1 pre-existing known issue (`BoundedWaitTests`). Done with `^xscp198` in one change.
    - what this card got: `compactionEvalSubsetTimeLimitMinutes` 30 -> 42, derived by `compactionEvalDerivedTimeLimitMinutes(forSamples:)` from `compactionEvalMeasuredDearestSampleSeconds` (352.0) and `compactionEvalMeasuredModelLoadSeconds` (3.5). `CompactionEvalTierBarTests` holds the constant against that derivation from both sides. The size band went `6...8` -> `6...7`.
    - open: criterion 1 needs a gated run. Criterion 3 moved to `^bkdm97c`. `^3ccp0je` carries the whole-dataset limit, which is sized on the mean where this one is now sized on the dearest.
    - next: `/review`
  timestamp: 2026-08-19T11:23:30.536458+00:00
- actor: claude-code
  id: 01m0cwwtkxzja003nr9fstchrr
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` over `ace1d44`, 1 finding (1 confirmed, 0 refuted, 7 attempted) — Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift:438
    - source check: all four claims for this card CONFIRMED against source. The derivation is real arithmetic (7 x 352.0 + 3.5 = 2467.5 s = 41.125 min, limit 42). `CompactionEvalTierBarTests` binds the limit from BOTH sides — `limit >= derived` and `limit < derived + 1` — so the limit cannot drift up silently. The band is `6...7` because 8 samples is 46.99 min.
    - next: fix the doc parameter key, then the card still needs a gated run for acceptance criterion 1. Card held in `review` — it must NOT advance to `done` on a clean review while that criterion is open.
  timestamp: 2026-08-19T11:35:53.213374+00:00
- actor: claude-code
  id: 01m0cy3cjddfh628aa20w51w74
  text: |-
    Findings pass, 2026-08-19. The `swift/doc-parameter-naming` finding is fixed and swept, and the size-band observation this card recorded is resolved.

    ## The finding, and the sweep behind it

    `CompactionEvalFactRetentionReport.swift` — `retentionLine(of:counts:)` declares `counts tallied:`, so the doc key must be `tallied`, the internal name. Changed `- counts:` to `- tallied:`.

    A finding samples a cause, so the whole eval target was swept rather than the one line. The sweep parses each doc block above a `func`/`init`, reads the `- Parameter` and `- Parameters:` keys out of it, and compares them with the internal and external names of the declaration below it. Over `Tests/FoundationModelsRouterEvals` it parsed 70 documented declarations and 112 doc parameter keys, left 0 blocks unparsed, and reported this one site only. After the fix it reports 0.

    DocC symbol links were deliberately left alone: ``counts(of:)`` on the same line correctly names the external label, and the rule states that symbol links follow the declaration rather than this rule.

    ## The size band, which is now one size

    The card recorded this as an observation of the two-sided limit binding: the band permitted 6 seeds, and at 6 seeds the derived bound is 35.26 minutes, so `42 < 36.26` is false and `subsetTimeLimitIsTheNextWholeMinuteAboveItsBound` fails while the band test passes. The band's lower end was unreachable, and the two tests disagreed about which sizes are legal.

    Resolved by making the band state what is really reachable, NOT by loosening the limit derivation. The evidence:

    - The upper assertion exists precisely to refuse a limit that sits far above its derivation, because such a limit "states nothing" — the defect this card records against the 30 minutes it replaced. Deriving the bound from a band's upper end instead of from the real seed count would let 42 stand at 6 seeds, 5.7 minutes above the 35.26 bound. That is the same defect again.
    - `subsetSampleCount` deliberately reads `compactionEvalRepresentativeSeeds.count` rather than a literal, so the derivation follows the real seed count. A band-driven derivation would undo that choice.
    - The band's lower end bought no tolerance on the floor side either: `compactionEvalFactRetentionRequiredSamples(of: 6)` is 6, so a 6-seed tier can still lose no seed.

    So `subsetSizeBand = 6...7` is now `subsetSeedCount = 7`, and `subsetStaysInsideItsSizeBand` is now `subsetHoldsTheSeedCountItsTimeLimitWasMeasuredAgainst`. It stays a literal, and is not read back from `compactionEvalRepresentativeSeeds`, so the test compares two independent statements rather than a value with itself. A subset moved to any other count now fails the size test and the limit binding together, until the limit is measured again and edited with it.

    ## Not done, and why

    Acceptance criterion 1 is untouched. Only a gated run can show the tier ends on its own assertion, and a gated run is ruled out. The card stays in `review`.
  timestamp: 2026-08-19T11:56:56.781174+00:00
- actor: claude-code
  id: 01m0cy7mpswhes8sj4afz2mac9
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift. `swift test`: 995 + 37 + 75 = 1107 tests in 117 suites passed, 0 failures, 1 known issue in the untouched main bundle. A forced rebuild of the eval target gave 0 compiler warnings. The doc parameter sweep over `Tests/FoundationModelsRouterEvals` reports 0 over 70 declarations and 112 keys.
    - next: stays in `review`. Acceptance criterion 1 needs a gated run, which is ruled out, so this card cannot finish here.
  timestamp: 2026-08-19T11:59:16.185710+00:00
- actor: claude-code
  id: 01m0d63ve73ry82b03n2qv4n31
  text: |-
    ### finish iteration 1 — stuck
    - implement: no-change — all review findings are checked, and the last findings pass is complete
    - review: not run — the card's own review hold forbids a move to `done` while acceptance criterion 1 is open
    - blocker: criterion 1 needs a sanctioned gated run, and the card records that a gated run is ruled out for now. Only a person can sanction that run.
    - next: a person runs the gated subset, then closes criterion 1 on its evidence
  timestamp: 2026-08-19T14:17:00.615116+00:00
- actor: claude-code
  id: 01m0dfy7jq57k56yq82x7dpdyw
  text: Task ^k0d30s4 sets a two-minute budget for each integration and eval test. This budget replaces the direction of this card to derive and increase time limits for the 30B model. The eval tiers now run the small model (mlx-community/Llama-3.2-1B-Instruct-4bit). The derived limits stay measured, but the measurements are now 3.5 s for the dearest sample and 2.0 s for the model load (run of 2026-08-19). Do not increase a limit above two minutes again. Make the test faster instead.
  timestamp: 2026-08-19T17:08:42.199495+00:00
- actor: claude-code
  id: 01m0h94c5rz1k69s4b88z5s6cg
  text: |-
    ## Research, 2026-08-21 — every criterion read against the code at `885f284`

    The card was pulled back to `doing`. The premise of this card is the 30B model's rate, and that premise is gone. Two tasks removed it:

    - Task ^k0d30s4 (commits `fe9be35`, `885f284`) holds every integration test to `integrationTestBudgetMinutes = 2`. The comment of 2026-08-19 on this card records that this budget REPLACES the direction of this card to raise a limit. That comment names `mlx-community/Llama-3.2-1B-Instruct-4bit` as the subject, which is now stale.
    - Task ^m03heaa (commits `e36277f`, `d1dde7a`) then made ``CompactionEvalRealModel/ref`` `mlx-community/Qwen2.5-3B-Instruct-4bit`.

    State of the constants, read in `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift` (the file moved out of `CompactionEvaluationTests.swift` since this card last wrote):

    - `compactionEvalMeasuredDearestSampleSeconds` = 15.9, `compactionEvalMeasuredModelLoadSeconds` = 1.3.
    - `compactionEvalDerivedTimeLimitMinutes(forSamples:)` is real arithmetic over those two. 7 x 15.9 + 1.3 = 112.6 s = 1.877 min.
    - `compactionEvalSubsetTimeLimitMinutes` = 2, the next whole minute above 1.877. The 42 minutes this card put there is gone.
    - `CompactionEvalTierBarTests` still binds the limit from both sides — `limit >= derived` and `limit < max(derived, 1) + 1` — and the second test now takes `max(derived, 1)`, because 1 minute is the smallest limit Swift Testing accepts.
    - `CompactionEvalRepresentativeSubsetTests.subsetSeedCount` = 7, still one size and not a band.
    - Both retention floors are 0.71, and ``CompactionEvalRealSubjectRunner`` pins greedy decoding, so a run's score is a fact about the prompt.

    ## Criterion 1 is met, by a run that is already recorded

    The gated subset run of 2026-08-20 on task ^m03heaa is the evidence. Its `implement — stuck` record states: summary 6 of 7, answer 6 of 7, every one of the 7 seeds reached, 63.3 s of suite wall clock inside the 2-minute limit. So the tier ended on its own assertion and not on the time limit, and no seed was unreached.

    Every fold in that run APPLIED. The trail files each sample in one class of ``CompactionEvalFactRetentionClass``, and a fold that stored no summary lands in `foldProducedNoSummary`. The run filed 6 samples under `retained` and 1 under `summaryLostFact` — 7 of 7 — so no sample landed in `foldProducedNoSummary`. The per-sample costs the same run measured (5.4, 4.7, 12.2, 3.2, 5.1, 15.9, 15.9 s) are therefore each an applied fold plus the answering turn that reads the folded transcript.

    No new gated run is necessary, and none was made.

    ## Criterion 2 needs one doc sentence

    The limit does state the per-sample rate it was measured against: the two measured constants and the derivation are all in the file. It does NOT name the applied fold. That half of the criterion was written against the 30B measurement, and the doc lost it when task ^m03heaa re-measured the rate. The fix is prose, in the doc of `compactionEvalMeasuredDearestSampleSeconds`.

    ## Criterion 3 is owned elsewhere

    The Metal abort on a time-limit cancellation is card ^bkdm97c, and commit `3add7b3` moved that card to the fork board. It is not on this board, and it is not this card's work.
  timestamp: 2026-08-21T04:26:41.208602+00:00
- actor: claude-code
  id: 01m0h9kac2mb4pjj9dr4qbyhxb
  text: |-
    ### implement — changed

    - evidence: 1 file — `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`, 19 insertions and 0 deletions, all of them `///` prose in the doc of `compactionEvalMeasuredDearestSampleSeconds`. No constant moved, no logic changed, and no test changed.
    - builds: `swift build --build-tests -Xswiftc -warnings-as-errors` gives `Build complete!` at the root and in `IntegrationTests`, with no error and no warning in either.
    - tests: root `swift test` gives `Test run with 1025 tests in 96 suites passed ... with 1 known issue` and `Test run with 77 tests in 9 suites passed`. The known issue is `BoundedWaitTests`, which is pre-existing and untouched. No gated tier was run.
    - criteria: all three now hold. Criterion 1 closes on the gated subset run of 2026-08-20 that task ^m03heaa recorded — 7 of 7 seeds reached, 6 of 7 summaries and 6 of 7 answers against a bar of 5 of 7, 63.3 s inside a 2-minute limit, and no sample filed under `foldProducedNoSummary`, which is the evidence that every fold applied. Criterion 2 needed the one sentence this change adds. Criterion 3 is owned by ^bkdm97c on the fork board.
    - not done, on purpose: no limit was derived again upward. The card forbids it, and task ^k0d30s4's two-minute budget replaces that direction. `compactionEvalSubsetTimeLimitMinutes` stays 2.
    - untouched, and not this card's: the open question on ^k0d30s4 about `CompactionEvalFullDatasetIntegrationTests`, ^mx4jqrn (the continuity tier is red on `main`), ^5q0vv85 (the whole-dataset bound has little margin), ^de1yq0p, ^sqcp252.
    - next: `/review`.
  timestamp: 2026-08-21T04:34:50.882945+00:00
- actor: claude-code
  id: 01m0h9xn9gp160gvb1nhn893qy
  text: |
    ### review — clean
    - evidence: `review sha bd26952~1..bd26952` with the local backend. 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 1 file reviewed (`Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`); 4 `.kanban/` files excluded by `.reviewignore`. The one earlier finding of 2026-08-19 06:26 is marked done. The card moved from `doing` through `review` to `done`.
    - criteria: criterion 1 holds on the recorded gated subset run of 2026-08-20 from task ^m03heaa — 7 of 7 seeds, 6 of 7 summaries and 6 of 7 answers against a bar of 5 of 7, 63.3 s inside the 2-minute limit, no sample in `foldProducedNoSummary`. No gated tier was run for this pass. Criterion 2 holds on the doc of `compactionEvalMeasuredDearestSampleSeconds`, read at `bd26952`: it states that each measured figure holds an applied fold and the answering turn that reads the folded transcript, that task ^azd033m made the fold apply, that a discarded fold costs one summarizer call and nothing after it, and that the run of 2026-08-17 is thus not comparable. The two ungated tests it names both exist — `CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` and `CompactionEvalSeedSizingTests/everySeedsFoldableSpanOutweighsARealSummary`, both in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`. Criterion 3 is owned by ^bkdm97c, which commit `3add7b3` moved to the board of the vendored fork; that card is not on this board.
    - next: none. The card is done.
  timestamp: 2026-08-21T04:40:29.744411+00:00
- actor: claude-code
  id: 01m0h9yd6zzgvd5dxdmw6hztr8
  text: |-
    ### finish iteration — clean
    - implement: changed — 1 source file, 19 lines of doc prose on `compactionEvalMeasuredDearestSampleSeconds`; the card's 30B premise was removed by ^m03heaa and ^k0d30s4, so no limit was raised
    - test: green — both packages build with -warnings-as-errors; root swift test 1025 in 96 suites plus 77 in 9 suites; no gated tier run, because ^m03heaa recorded one on 2026-08-20
    - commit: bd26952
    - review: clean — 0 findings; task moved to `done`
  timestamp: 2026-08-21T04:40:54.239743+00:00
position_column: done
position_ordinal: ffd680
title: The gated compaction subset no longer fits its 30-minute limit now that every fold applies — 6 of 7 seeds in 1800 s
---
Measured by the sanctioned gated run of 2026-08-18 16:07 local, made for `^bgxtdk3` criterion 5. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-crit5.log`.

HEAD `3b433fb`. `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`, with `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` NOT set.

## What happens

```
✘ Test "Compaction retains pre-fold facts" recorded an issue at CompactionEvaluationTests.swift:1427:6:
  Time limit was exceeded: 1800.000 seconds
FactRetention per-sample evidence — 6 of 7 seeds measured
unreached: 1 of 7 seeds never ran — three-facts-support-escalation
```

The run measured 6 seeds and then the 30-minute limit fired while seed 7 was in its fold.

## Why the earlier measurement no longer holds

`^fz49qds` closed its first criterion on this measurement:

> the run of 2026-08-17 measured 7 of 7 subset seeds and passed on its own assertion in 1644.7 seconds, inside the 30-minute limit

That run discarded 7 folds of 7. A discarded fold costs one summarizer call and no more. `^azd033m` made the fold APPLY, and an applied fold makes the answering turn read a longer transcript. The per-sample cost went up as a result.

The trail gives the cost of each sample:

| sample | seed | fold s | answer s | total s |
|---|---|---|---|---|
| 1 | budget-cap-tool-and-owner | 241.7 | 53.4 | 295.1 |
| 2 | db-port | 136.0 | 61.4 | 197.4 |
| 3 | encryption-algorithm | 213.4 | 138.6 | 352.0 |
| 4 | env-file | 166.1 | 94.8 | 260.9 |
| 5 | license-key-and-region | 155.0 | 114.9 | 269.9 |
| 6 | three-facts-long-project-brief | 164.1 | 86.5 | 250.7 |
| 7 | three-facts-support-escalation | unfinished | — | — |

The six totals add to 1626.0 s. The model load took 3.5 s. So about 170 s of the limit went to the unfinished seventh fold. The six measured samples averaged 271.0 s each.

`^9cw5g6n` records that the tier starts its samples together. This trail shows that the generation gate holds them near to serial: the sum of the per-sample times is 1626 s of a 1800 s run, so a per-sample figure read off this trail is close to its true cost.

At 271 s each, 7 seeds need about 1900 s. The tier needs about 5 percent more time than it has.

## What must NOT be done alone

Do not raise `compactionEvalSubsetTimeLimitMinutes` and stop there. The measurement behind the limit is now wrong, and a limit put up to fit one run does not state a measurement. Three answers exist and the choice is a person's:

1. State the limit against the new measured per-sample rate of 271 s, with the applied fold named as the reason it rose.
2. Drop the subset to 6 seeds, which costs about 1626 s and fits. `^xscp198` records that a 7-seed subset held to a 0.9 mean can pass only at 7 of 7, and a 6-seed subset can pass only at 6 of 6, so this does not help the tolerance.
3. Cut the per-sample cost. The fold takes 136 s to 242 s, and the answer takes 53 s to 139 s.

## A second observation from the same trail

The process ended on signal 6 after the report printed:

```
-[_MTLCommandBuffer addCompletedHandler:]:1011: failed assertion `Completed handler provided after commit call'
... exited with unexpected signal code 6
```

The report and the counts printed first, so the run lost no measurement. The abort happens when the time limit cancels a sample that has work on the GPU.

## What landed, 2026-08-19

SUPERSEDED on 2026-08-21. The 42 minutes below is gone, and answer 1 above is no longer the answer this card rests on. This section stays as the record of the 30B era; see "What landed, 2026-08-21" for the state that holds.

Answer 1 of the three above, sized on the DEAREST measured sample rather than on the mean, because the six samples spread by 1.78x and a limit at the mean sits inside that spread.

- `compactionEvalMeasuredDearestSampleSeconds` (352.0) and `compactionEvalMeasuredModelLoadSeconds` (3.5) name the two measured inputs, and `compactionEvalDerivedTimeLimitMinutes(forSamples:)` derives a tier's bound from them.
- `compactionEvalSubsetTimeLimitMinutes` is 42: the next whole minute above the derived 41.1 for seven samples. The margin is 0.9 minutes over that bound, and 9.0 minutes over the 33.0 the run really measured with the untimed seventh seed charged at the dearest sample.
- The doc names the applied fold as the reason the rate rose, and says why 1644.7 s is stale: the work changed, not the machine.
- `CompactionEvalTierBarTests` holds the limit against the derivation from BOTH sides, so a subset that outgrew the limit, and a limit that stopped stating a measurement, each fail a plain `swift test`.
- `CompactionEvalRepresentativeSubsetTests.subsetSizeBand` goes from `6...8` to `6...7`: 8 samples at the dearest rate is 46.9 minutes, over the limit.
- `compactionEvalFullDatasetTimeLimitMinutes` is left at 120, out of this card's scope, and its doc now states that it rests on the mean where this one rests on the dearest. `^3ccp0je` carries that.

## Acceptance Criteria

- [x] The gated subset ends on its own assertion, not on the time limit, with every fold applied — CLOSED on the gated subset run of 2026-08-20 that task ^m03heaa recorded: 7 of 7 seeds reached, 6 of 7 summaries and 6 of 7 answers against a bar of 5 of 7, and 63.3 seconds of wall clock inside a 2-minute limit. Every fold applied: the trail filed 6 samples as `retained` and 1 as `summaryLostFact`, and none as `foldProducedNoSummary`.
- [x] The limit states the per-sample rate it was measured against, and names the applied fold as the reason for the rate
- [x] A time-limit cancellation does not abort the process on a Metal assertion — HANDED to `^bkdm97c`, which owns it. Commit `3add7b3` moved that card to the fork board, because any fix touches the MLX generation path rather than an eval constant. It is not open on this board.

## Review Findings (2026-08-19 06:26)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift:438` `swift/doc-parameter-naming` — Doc parameter key uses the external argument label `counts` instead of the internal parameter name `tallied`. Per the rule, `- Parameter` entries must name the internal (local) parameter that callers inside the function use, not the external label used at call sites. Change line 438 from `- counts:` to `- tallied:` to reference the internal parameter name.

## Review hold, 2026-08-19 — LIFTED on 2026-08-21

The hold is lifted. It held the card out of `done` because acceptance criterion 1 was open and only a gated run could show it. That gated run happened: task ^m03heaa ran the subset tier on 2026-08-20 and recorded the result. See "What landed, 2026-08-21" for the evidence. The text below stays as the record of why the hold existed.

> This card stays in `review` and must NOT move to `done` on a clean review. Acceptance criterion 1 is open: the tier must end on its own assertion rather than on the limit, and only a gated run can show it. A gated run is ruled out for now. The review pass verified the code, not the criterion.

Source verification of this card's claims, made against `ace1d44` (all CONFIRMED at that commit; the figures are the 30B era's and no longer hold):

- `compactionEvalDerivedTimeLimitMinutes(forSamples:)` is real arithmetic over the two measured constants, not a stated number. 7 x 352.0 + 3.5 = 2467.5 s = 41.125 min, so 42 is the next whole minute. `compactionEvalSubsetTimeLimitMinutes` is 42, and `subsetSampleCount` reads `compactionEvalRepresentativeSeeds.count` rather than a literal, so the derivation follows the real seed count.
- The binding is two-sided. One test asserts `Double(limit) >= derived`, and one asserts `Double(limit) < derived + 1`. 41.125 <= 42 < 42.125, so 42 is the only integer that clears both. A limit that drifts up to 43 fails the second test. The limit cannot drift up silently.
- The band is `6...7`, down from `6...8`. 8 x 352.0 + 3.5 = 2819.5 s = 46.99 min, over 42.
- Observation from the two-sided binding, not a finding: the upper assertion pins the subset at exactly 7 seeds. At 6 seeds the derived bound is 35.26 min, and `42 < 36.26` is false, so `subsetTimeLimitIsTheNextWholeMinuteAboveItsBound` fails while `subsetStaysInsideItsSizeBand` passes. The band's lower end of 6 is not reachable without also editing the limit.
- Observation, not a finding: the doc prose says "41.1 minutes" where the derived value is 41.125. Prose rounding only; the tests use the computed value.

## What landed, 2026-08-19 (findings pass)

The finding above is fixed, and the band observation is resolved.

- `retentionLine(of:counts:)` declares `counts tallied:`, so its doc key is now `- tallied:`. The whole eval target was swept for the same cause rather than the one line: 70 documented declarations and 112 doc parameter keys read against their declarations, 0 unparsed, this one site only, and 0 after the fix. DocC symbol links were left alone, because the rule says a symbol link follows the declaration.
- The band and the limit binding no longer disagree. `subsetSizeBand = 6...7` becomes `subsetSeedCount = 7`, and `subsetStaysInsideItsSizeBand` becomes `subsetHoldsTheSeedCountItsTimeLimitWasMeasuredAgainst`. The band was made to state what is reachable, rather than the limit derivation made to tolerate the band, because deriving the bound from a band's upper end would let 42 stand at 6 seeds — 5.7 minutes above that size's 35.26 bound — which is the very defect the two-sided binding exists to refuse. The size stays a literal, so the test still compares two independent statements.

## What landed, 2026-08-21

The premise of this card is the 30B model's rate, and that premise is gone. Two tasks removed it, and this card closes on what they measured. No limit was derived again upward, and no gated tier was run for this pass.

- Task ^k0d30s4 holds every integration test to `integrationTestBudgetMinutes = 2`. Its budget REPLACES the direction of this card to raise a limit.
- Task ^m03heaa then made ``CompactionEvalRealModel/ref`` `mlx-community/Qwen2.5-3B-Instruct-4bit`, and re-measured every tier against it.

State of the code, read in `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`, where these constants now live:

- `compactionEvalMeasuredDearestSampleSeconds` is 15.9 and `compactionEvalMeasuredModelLoadSeconds` is 1.3, both from the gated subset run of 2026-08-20.
- `compactionEvalDerivedTimeLimitMinutes(forSamples:)` derives 7 x 15.9 + 1.3 = 112.6 s = 1.877 minutes for the subset.
- `compactionEvalSubsetTimeLimitMinutes` is 2, the next whole minute above that bound. The 42 minutes this card put there is gone.
- `CompactionEvalTierBarTests` still binds the limit from both sides. The upper assertion is now `Double(limit) < max(derived, 1) + 1`, because 1 minute is the smallest limit Swift Testing accepts.
- `CompactionEvalRepresentativeSubsetTests` holds the subset at one size of 7.
- Both retention floors are 0.71, and ``CompactionEvalRealSubjectRunner`` pins greedy decoding, so a run's score is a fact about the prompt and not a draw.

Criterion 1 closes on the gated subset run of 2026-08-20 that task ^m03heaa recorded. The tier reached all 7 seeds, scored 6 of 7 summaries and 6 of 7 answers against a bar of 5 of 7, and ended in 63.3 seconds inside a 2-minute limit. So it ended on its own assertion and not on the time limit. Every fold in it applied: the trail files each sample in one class of ``CompactionEvalFactRetentionClass``, and a fold that stored no summary lands in `foldProducedNoSummary`. That run filed 6 samples as `retained` and 1 as `summaryLostFact` — 7 of 7 — and none as `foldProducedNoSummary`.

Criterion 2 got the one sentence it was missing. The doc of `compactionEvalMeasuredDearestSampleSeconds` had kept its measured rate through each re-measurement, but it had lost the applied fold. It now states that each measured figure holds an applied fold and the answering turn that then reads the folded transcript, that task ^azd033m made the fold apply, and that a discarded fold costs one summarizer call and nothing after it — so a rate measured over discarded folds under-states this one, which is why the run of 2026-08-17 is not comparable with any figure in that doc. It names the run's own evidence, and it names the two ungated tests that keep the property true without a gated run: `CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` and `CompactionEvalSeedSizingTests/everySeedsFoldableSpanOutweighsARealSummary`.

Criterion 3 is owned by ^bkdm97c on the fork board, and is not open here.

Verified: root `swift test` gives 1025 tests in 96 suites passed with 1 known issue (`BoundedWaitTests`, untouched and pre-existing), plus 77 tests in 9 suites passed. `swift build --build-tests -Xswiftc -warnings-as-errors` completes with no error and no warning at the root and in `IntegrationTests`.
#compaction #eval #real-model #test-debt
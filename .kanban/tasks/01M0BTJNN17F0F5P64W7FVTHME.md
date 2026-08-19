---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dwnm39sdygmtgygvab6jv7
  text: |-
    Findings, and what changed since the card was written.

    Commit efd3b58 (task ^k0d30s4) removed most of this card's defect before this card started. That commit moved the gated tiers to the small 1B model and made the limit 2 minutes (120 s), not 120 minutes. The 120-minute figure, the 271.0 s mean rate, and the 11.6-minute margin do not apply now. The card's step "set FM_ROUTER_COMPACTION_EVAL_FULL_DATASET" does not apply now: the repository forbids env-var gates, and the tier is selected by name with `swift test --filter CompactionEvalFullDataset` (commit 1db2b56).

    Criterion 1 — the tier has run end to end, three times. Task ^k0d30s4 measured 52.5 s, card ^3ccp0je measured 52.4 s, and this card's own run today measured 53.6 s of suite wall clock against the 120 s limit: `Scripts/swift-test.sh --filter CompactionEvalFullDataset` passed in 53.551 s total, all 24 seeds ran (`unreached: <none>`), retention summary 17 of 24 and answer 13 of 24, equal to the recorded baselines.

    Criterion 2 — the doc comment of `compactionEvalFullDatasetTimeLimitMinutes` in `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift` now states the measurement: it names the three measured runs of 2026-08-19 and their wall clocks (52.5, 52.4, 53.6 s), each over all 24 seeds. The derivation text stays beside the measurement, and this is deliberate: card ^3ccp0je (done) set one dearest-rate derivation for the two tier limits, and `CompactionEvalTierBarTests` holds this constant to that derivation from two sides. To delete the derivation text would make the doc comment disagree with the test that enforces the value. The measurement now confirms the derivation: 53.6 s measured against the 86.0 s bound.

    Criterion 3 — the value 2 follows from measurement plus a stated margin. Each sample is charged the dearest measured 1B sample cost (3.5 s), one measured model load (2.0 s) is added, and the sum (86.0 s = 1.43 min) is rounded up to the next whole minute. The measured tier (53.6 s) spends under half of the 120 s limit.
  timestamp: 2026-08-19T20:51:11.593241+00:00
- actor: claude-code
  id: 01m0dwnzk33n69gt61hyy94q05
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift (doc comment of `compactionEvalFullDatasetTimeLimitMinutes` now names the measured runs: 52.5, 52.4 and 53.6 s wall clock, 24 of 24 seeds each). Tier run: `Scripts/swift-test.sh --filter CompactionEvalFullDataset` passed, 1 test in 1 suite, 53.6 s wall clock against the 120 s limit, `unreached: <none>`, retention summary 17 of 24 and answer 13 of 24. Verification: `Scripts/swift-test.sh --skip IntegrationTests` passed (1018 tests in 96 suites with 1 known issue that a `withKnownIssue` test expects, plus 75 tests in 8 suites, 0 failures); `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0 with no compiler warning.
    - next: the card is ready for /review. The three acceptance criteria show checked in the description.
  timestamp: 2026-08-19T20:51:23.363387+00:00
- actor: claude-code
  id: 01m0dwrq1bw0z2a0ttyt4yggvb
  text: |-
    ### test — green
    - evidence: `Scripts/swift-test.sh --skip IntegrationTests` — Test run 1 (1018 tests, 96 suites) passed, 1 known issue (the pre-existing BoundedWaitTests known issue, which counts as green). Test run 2 (75 tests, 8 suites) passed. No fail, no warning, no skip found in the output.
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` — build complete, exit code 0. No warning.
    - next: hand off to the review step.
  timestamp: 2026-08-19T20:52:52.907974+00:00
position_column: doing
position_ordinal: '8480'
title: The whole-dataset compaction eval limit is derived with 11.6 minutes of room and has never been run
---
`compactionEvalFullDatasetTimeLimitMinutes` is `120`, and no run of that tier has ever measured it. Commit `2525f29` re-derived the figure it stands against from directly timed samples instead of a division, and the derived cost moved from 94 minutes to 108.4. The margin went with it: 26 minutes of room became 11.6.

## Why this now needs a real run

The derivation is honest and the constant says it is derived, but it rests on an assumption the target cannot check without running the tier:

- The rate is 271.0 s, the mean of the six samples `^6ssbakk` timed one by one. Their spread is a factor of 1.8, from 197.4 s to 352.0 s. A mean of six is a thin base for a 24-sample multiply.
- The multiply assumes 24 samples cost about 24 times one sample, because MLX gives the resident container serial access. That reasoning is sound, and it is still reasoning.
- The whole-dataset seeds are not the subset seeds. Nothing says the 24 cost what the 6 cost.

At 9.7% margin, any of those three being slightly optimistic puts the tier over its limit. The failure is expensive to find: the run must reach 120 minutes before it reports.

## The work

- Run the whole-dataset tier once, with `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` set, and capture the progress trail.
- Record the real duration in `compactionEvalFullDatasetTimeLimitMinutes`'s doc comment in place of the derivation, exactly as that comment already asks. State it as measured, and name the run.
- Set the constant from the measurement plus a stated margin, rather than leaving 120 standing because the derivation happened to fit under it.
- If the tier overruns, that is the finding, and the limit or the tier's size is what changes.

## Acceptance Criteria

- [x] The whole-dataset tier has been run once end to end and its duration recorded
- [x] `compactionEvalFullDatasetTimeLimitMinutes`'s doc comment states a measurement, not a derivation
- [x] The constant's value follows from that measurement and a stated margin

## Related

- `^9cw5g6n` — re-derived the figure and moved the margin to 11.6 minutes. Its criterion 3 was met in substance; this card carries the whole-dataset run that criterion could not reach.
- `^6ssbakk` — the trail that timed the six samples the rate rests on.
- `^23qeprz` — the dispatch shape is unmeasured, which this run would also settle for the whole-dataset tier. #compaction #eval #real-model #test-debt
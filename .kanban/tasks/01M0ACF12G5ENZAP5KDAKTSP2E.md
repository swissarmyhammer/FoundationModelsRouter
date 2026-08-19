---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqcra1cem29mfqt2cyzjy
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds.

    `CompactionEvalProgressLog` has 39 references across 3 files. `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift` is not one of them. Its `container()` (lines 47-73) and its `run(...)` (lines 172-260) emit no progress at all.

    `CompactionEvalProgressStep` is still a String-raw enum (`CompactionEvalProgressLog.swift:12`), so the plan on this card to extend it still applies.
  timestamp: 2026-08-18T23:18:54.986074+00:00
- actor: claude-code
  id: 01m0by9rqzax5s4v817yzw0591
  text: |-
    ## Done

    `CompactionContinuityEvalRealSubjectRunner` now writes a live trail.

    ### The step vocabulary

    `CompactionEvalProgressStep` gained two cases beside `fold`/`answer`: `step` and `finalInstruction` (raw value `final-instruction`). The prefix, the started/returned markers and `makeSecondsText(_:)` are untouched and shared, so one `grep` still reads both tiers.

    The label needed one more fact than it carried. `CompactionEvalSampleLabel.seedID` became `fixtureID` beside a new `CompactionEvalFixtureKind` (`seed` / `task`), so a line renders `sample=2/10 task=vault-code-and-outpost` for this tier and `sample=3/7 seed=...` for the other. The question-keyed initializer went away; each runner now resolves its own fixture and hands the label the answer, which is why the continuity runner gained `tasks` and `CompactionContinuitySeed.keyedByFinalInstruction(_:)` — the final instruction is the join key a sample already carries.

    ### The model load

    Timed on its own two lines by the shared `CompactionEvalRealModelContainer.load` (task `^we8n8nk`), exactly as the fact-retention runner does. A tier that spends its whole limit loading leaves the started line and no returned line.

    ### The `elapsed=0.0s` literal is gone from BOTH runners

    `makeStepStartedLine` now takes `elapsedSeconds: Double?` and states NO `elapsed=` clause when it is `nil`. A sample's first step passes `nil` — it has measured nothing, and a zero there reads as a measurement while carrying none.

    That change reaches `CompactionEvalRealSubjectRunner` too, which passed the literal `0` at fold start. Leaving it would have kept a false measurement in a function this change rewrote, so the fold-start call now passes `nil`. It is one line, and it is the same defect, not a second card's work.

    A step's started line also carries `step=4/13`, because a continuity task drives a dozen steps that all render the same `step` word — without it a cut-short run names the sample and not the step. Its returned line carries `replyBytes=… folds=…`, so the trail states WHICH step folded rather than leaving the count to be read at the end.

    ### Covered hermetically

    `CompactionContinuityEvalProgressLogTests`, beside `CompactionEvalProgressLogTests` — 8 tests, 1 ms, no model. Each was proved able to fail: the renderer was broken four ways (the nil guard back to a zero, the label borrowing `seed=`, the fold count dropped, the step position dropped) and 7 issues were recorded across 4 tests. All restored, all green.

    ### Acceptance criteria

    - [x] A continuity run states its model load time apart from its sample time.
    - [x] One line per sample while it runs, so a run that hits its limit names the sample it stopped in — and the step.
    - [x] Each sample states the time of each step it drove.
    - [x] Both tiers share one line prefix and one seconds rendering, pinned by `bothTiersShareOnePrefixAndOneSecondsRendering`.

    `swift test` 1099 pass; `FM_ROUTER_COMPACTION_SMOKE=1 swift test` 1099 pass; `-warnings-as-errors` clean; `review working` 0 findings.
  timestamp: 2026-08-19T02:41:11.423318+00:00
- actor: claude-code
  id: 01m0byaz84g8pp4ac27rzct100
  text: |-
    ### implement — changed
    - evidence: 13 files across the three cards done in one session. This card's own: `Tests/FoundationModelsRouterEvals/CompactionEvalProgressLog.swift`, `Support/CompactionContinuityEvalRealSubjectRunner.swift`, `Support/CompactionEvalRealSubjectRunner.swift`, `CompactionContinuityDataset.swift`, `CompactionContinuityEvaluationTests.swift`, `CompactionEvaluationTests.swift`, `Support/SequenceKeyedByFirst.swift`. `swift test` 1099 pass; `FM_ROUTER_COMPACTION_SMOKE=1 swift test` 1099 pass; `review working` 0 findings.
    - next: `/review`.
  timestamp: 2026-08-19T02:41:50.852243+00:00
- actor: claude-code
  id: 01m0bzp3kdehtx3n0220qcv85q
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit c349f05) — 0 findings, 0 confirmed, 0 refuted, 14 validator passes attempted, 0 failed. 13 files reviewed; 6 `.kanban/` files excluded by `.reviewignore`. No prior `## Review Findings` section on this card.
    - verified from source, not from the summary:
      - `CompactionContinuityEvalRealSubjectRunner` emits lines. Each of `steps` writes a started line and a returned line, and the final instruction writes its own pair.
      - The model load is timed apart from the samples. `CompactionEvalRealModelContainer.load` writes the started line, takes `Date()`, and writes the returned line with the real interval. The sample clock, `sampleStartedAt`, is taken after the load and after the profile build, so no sample is charged for the load.
      - Nothing prints a number that is not a measurement. Every `elapsed=`, `took=`, `replyBytes=`, `folds=` value comes from a `timeIntervalSince` or a real count. `sample=n/total` and `step=n/total` are positions, and read as positions.
      - `makeStepStartedLine` takes `elapsedSeconds: Double?` and appends the `elapsed=` clause only under `if let`.
      - No caller passes a literal `0`. Every `elapsedSeconds:` argument in the test tree is `nil`, a `timeIntervalSince` result, `foldSeconds`, or a named test constant. `CompactionEvalRealSubjectRunner`'s fold-start call passes `nil`, and the continuity runner's first step passes `nil` through `offset == 0 ? nil : …`.
    - next: none. The card advances to `done`.
  timestamp: 2026-08-19T03:05:24.333049+00:00
position_column: done
position_ordinal: ffbd80
title: The gated compaction continuity eval has the same one-bit defect — it prints nothing until it ends
---
Found while instrumenting the fact-retention tier for `^h2xxsse`.

## What happens

`CompactionContinuityEvaluationTests` is the second gated eval tier in `FoundationModelsRouterEvals`. It runs under `gatedEvalSuiteTimeLimitMinutes` (20 minutes), it drives a real `RoutedSession` per sample through `CompactionContinuityEvalRealSubjectRunner.run(steps:finalInstruction:prompt:budget:)`, and it writes nothing at all while it runs.

That is exactly the shape `^h2xxsse` names on the fact-retention tier: a measurement that costs tens of minutes and, when its time limit cuts it short, reports one bit — "not finished". A run of this tier that hits its 20-minute limit cannot say whether the model load, one step of one sample, or the final instruction spent the time.

## What `^h2xxsse` did, and why it stopped at the boundary

`^h2xxsse` added `CompactionEvalProgressLog` (`Tests/FoundationModelsRouterEvals/CompactionEvalProgressLog.swift`) and wired it into `CompactionEvalRealSubjectRunner`:

- the model load timed and stated on its own two lines, so it is never charged to the first sample,
- one line for each sample when its fold starts, when the fold returns, when the answering turn starts, and when it returns, each with elapsed seconds.

It stopped at the fact-retention runner deliberately. The continuity runner is a different type with a different `run` signature, it carries no `[CompactionEvalSeed]` to number its samples against, and its samples are a LIST OF STEPS rather than one fold plus one answering turn — so its step vocabulary is not `fold`/`answer` and its label is not `sample=n/total seed=id`. Instrumenting it is real work rather than one line of that change, and half-doing it would have left two gated tiers with two different trails.

## The work

- Decide the continuity tier's own step vocabulary. `CompactionEvalProgressStep` is a `String`-raw-valued enum for exactly this reason — extend it, or give the continuity tier its own, but keep `CompactionEvalProgressLog.linePrefix`, `startedMarker`, `returnedMarker` and `makeSecondsText(_:)` shared so one `grep` reads both tiers.
- Time `CompactionContinuityEvalRealSubjectRunner.container()`'s model load on its own lines, exactly as the fact-retention runner now does. That runner's `container()` is a near-copy of the other one and is the obvious first site.
- Emit one line for each step the sample drives, and one for the final instruction, each naming the sample and stating its own seconds.
- Cover the rendering hermetically, beside `CompactionEvalProgressLogTests`.

## Acceptance Criteria

- [ ] A continuity run states its model load time apart from its sample time
- [ ] A continuity run prints one line for each sample while it runs, so a run that hits its limit names the sample it stopped in
- [ ] Each sample states the time of each step it drove
- [ ] Both gated tiers' trails share one line prefix and one seconds rendering, so one `grep` reads either

## Related

- `^h2xxsse` — the same defect on the fact-retention tier, and the `CompactionEvalProgressLog` this card extends. #compaction #eval #real-model #defect
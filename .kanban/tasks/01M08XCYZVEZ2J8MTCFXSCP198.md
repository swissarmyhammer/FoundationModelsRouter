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
- actor: claude-code
  id: 01m0cwwyvbcpptamnm7rrgeg53
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` over `ace1d44`, 1 finding (1 confirmed, 0 refuted, 7 attempted, 1 review task failed so the pass is INCOMPLETE) — Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift:438
    - source check: all three claims for this card CONFIRMED against source. `.greedy` is pinned at CompactionEvalRealSubjectRunner.swift:152-154 and the old no-pin comment is gone. `compactionEvalFactRetentionRequiredSamples(of:)` uses the assertion's own `share(...) >= floor`; hand-checked at n=7 (7), n=10 (9), n=24 (22) with no off-by-one, and it avoids the `ceil(floor * n)` trap. The floor is 0.9, unchanged, and both the summary share and the answer share are asserted against it.
    - next: fix the doc parameter key. Card held in `review` — acceptance criterion 1 is ticked on its second disjunct only, and the first disjunct needs two gated runs, so this card must NOT advance to `done` on a clean review.
  timestamp: 2026-08-19T11:35:57.547043+00:00
- actor: claude-code
  id: 01m0cy3rgyjkqgf33dgxhkzh7b
  text: |-
    Findings pass, 2026-08-19. The `swift/doc-parameter-naming` finding is fixed and swept, and the two observations this card recorded against `expectFactRetention(of:)` are judged and acted on.

    ## The finding, and the sweep behind it

    `CompactionEvalFactRetentionReport.swift` — `retentionLine(of:counts:)` declares `counts tallied:`, so the doc key must be `tallied`, the internal name. Changed `- counts:` to `- tallied:`.

    Swept the whole eval target rather than the one line: 70 documented declarations parsed, 112 doc parameter keys read against their declarations, 0 blocks unparsed, this one site reported. After the fix the sweep reports 0. DocC symbol links were left alone — ``counts(of:)`` on the same line correctly names the external label, and the rule says symbol links follow the declaration.

    ## Observation 1 — the "can never disagree" claim: NARROWED, not widened

    The claim covered the summary side only, because the answer side reads `result.aggregateValue(.mean(of:))` rather than `share(of:over:)`.

    Narrowing is the correct half. The answer side reads the framework metric ON PURPOSE, and its own comment says so: the tier's end-to-end verdict IS the framework's verdict rather than a second derivation of it that could drift from the metric it reports. Rewriting it to `share(of:over:)` would trade a true guarantee for the one being claimed, and it would divide by the report's recording where the framework divides by its own. So the doc on `compactionEvalFactRetentionRequiredSamples(of:)` now says the guarantee reaches the SUMMARY assertion and no further, and states why the two sides read different recordings. The floor and the `>=` are the same on both sides, so the bar is unchanged.

    ## Observation 2 — `required` over `seeds.count`: a defect in the MESSAGE

    Judged, and it is the message. Both assertions divide by `measured` = `findings.count`, and the message quoted a bar computed over `seeds.count`. On the run of 2026-08-18 that read "4 of 6 folds wrote a summary carrying the fact, and a floor of 0.9 over 7 seeds needs 7 of them" — a reader counts the shortfall as 3 where the assertion really needed 6 of 6.

    The assertions are right to divide by what ran, and were left alone. A run the time limit cuts short already fails on that limit, so applying the tier's whole bar to a partial measurement would report a fact-retention defect for a run that only ran out of clock. Dividing the summary side by `seeds.count` would also give the two sides different denominators, since the framework mean divides by what it recorded.

    So a new `compactionEvalFactRetentionBar(measured:of:)` states the bar the assertion really applied, over the measured count, and names the tier's own bar as well when the run recorded fewer samples than the tier holds.

    ## Not done, and why

    Acceptance criterion 1's first disjunct is untouched — two gated runs of identical code reaching identical verdicts needs two gated runs, and a gated run is ruled out. The card stays in `review`.
  timestamp: 2026-08-19T11:57:09.022340+00:00
- actor: claude-code
  id: 01m0cy7ppzah4rc07sf88czz1b
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift. `swift test`: 995 + 37 + 75 = 1107 tests in 117 suites passed, 0 failures, 1 known issue in the untouched main bundle. A forced rebuild of the eval target gave 0 compiler warnings. The doc parameter sweep over `Tests/FoundationModelsRouterEvals` reports 0 over 70 declarations and 112 keys.
    - next: stays in `review`. Acceptance criterion 1's first disjunct needs two gated runs, which are ruled out, so this card cannot finish here.
  timestamp: 2026-08-19T11:59:18.239317+00:00
position_column: review
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

## Review Findings (2026-08-19 06:29)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 8 not reviewed.

> ⚠️ 1/7 review tasks failed — results are INCOMPLETE.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift:438` `swift/doc-parameter-naming` — Parameter documentation uses the external argument label `counts` instead of the internal parameter name `tallied`. DocC and Xcode resolve documentation against internal names, and mismatches break documentation lookup. Change line 438 from `///   - counts:` to `///   - tallied:`.

## Review hold, 2026-08-19

This card stays in `review` and must NOT move to `done` on a clean review. Acceptance criterion 1 is ticked on its SECOND disjunct only — the bar states the tolerance it has. The first disjunct, that two gated runs of identical code reach identical verdicts, is not proven, and only two gated runs can prove it. A gated run is ruled out for now.

Source verification of this card's claims, made against `ace1d44` (all CONFIRMED):

- `.greedy` is pinned on the fact-retention runner: `CompactionEvalRealSubjectRunner.swift:152-154` loads the container with `samplingMode: .greedy`. The old comment claiming a key-phrase search needs no pin is removed. The replacement text names the old reasoning only to refute it, and `GatedEvalSerialGate.swift:33` likewise records that decoding no longer separates the two runners. No surviving claim that the pin is unnecessary.
- `compactionEvalFactRetentionRequiredSamples(of:)` at `CompactionEvaluationTests.swift:281-286` searches `(0...sampleCount).first` for the smallest count where `CompactionEvalFactRetentionReport.share(of:over:) >= compactionEvalFactRetentionFloor` — the same expression shape the summary assertion applies at `:1758-1760`. Hand-checked: n=7 returns 7 (6/7 = 0.857 is short), n=10 returns 9 (9/10 clears 0.9), n=24 returns 22 (21/24 = 0.875 is short, 22/24 = 0.9167 clears). No off-by-one. The `ceil(floor * n)` trap is real and avoided: the nearest Double to 0.9 is about 0.90000000000000002, so `0.9 * 10` rounds to 9.000000000000002 and `ceil` would give 10, where the search form returns 9.
- The floor is applied to BOTH shares and is still 0.9. `compactionEvalFactRetentionFloor = 0.9` at `CompactionEvaluationTests.swift:266`, unchanged in value by this commit. The fold's summary share is asserted at `:1758-1760` and the answer share at `:1768-1771`, both against `>= compactionEvalFactRetentionFloor`.
- Observation, not a finding: the answer-side assertion at `:1769` reads the Evaluations framework mean, `result.aggregateValue(.mean(of:))`, rather than `share(of:over:)`. The floor and the operator match, so the bar is the same, but the "can never disagree" guarantee stated at `:271-272` covers the summary side only.
- Observation, not a finding: `required` is computed over `seeds.count` at `:1752` while the summary share divides by `measured` = `findings.count` at `:1751`. On a run the time limit cuts short, `measured < seeds.count`, so the failure message quotes a bar for the full seed count while the assertion applies the floor to the smaller measured set.
- Observation, not a finding: the property test at `:1658` and `:1661` writes `Double(required) / Double(sampleCount)` by hand rather than calling `share`, so it re-derives the same arithmetic by a second path.

## What landed, 2026-08-19 (findings pass)

The finding above is fixed, and the first two observations are judged and acted on.

- `retentionLine(of:counts:)` declares `counts tallied:`, so its doc key is now `- tallied:`. The whole eval target was swept for the same cause: 70 documented declarations and 112 doc parameter keys read against their declarations, 0 unparsed, this one site only, and 0 after the fix. DocC symbol links were left alone, because the rule says a symbol link follows the declaration.
- **The "can never disagree" claim is NARROWED, not widened.** The answer side reads the framework's own `.mean(of:)` on purpose, so the tier's end-to-end verdict IS the framework's verdict rather than a second derivation that could drift from the metric it reports. Rewriting it to `share(of:over:)` would trade that true guarantee for the one being claimed. The doc on `compactionEvalFactRetentionRequiredSamples(of:)` now says the guarantee reaches the SUMMARY assertion and no further, and states why the two sides read different recordings.
- **The `seeds.count` bar is a defect in the MESSAGE, and is fixed there.** Both assertions divide by the measured count, and the message quoted a bar over the seed count — on the run of 2026-08-18 that read "4 of 6 folds ... and a floor of 0.9 over 7 seeds needs 7 of them", where the assertion really needed 6 of 6. The assertions were left alone: a run the time limit cuts short already fails on that limit, so applying the tier's whole bar to a partial measurement would report a fact-retention defect for a run that only ran out of clock, and it would give the two sides different denominators. `compactionEvalFactRetentionBar(measured:of:)` now states the bar the assertion really applied, and names the tier's own bar as well when the run stopped short.
- The third observation, that the property test re-derives `Double(required) / Double(sampleCount)` by hand, is left as it stands: a property test that computes the share by a second path is what makes it a check of the shared helper rather than a restatement of it.

Acceptance criterion 1's first disjunct is untouched: only two gated runs can close it. #compaction #eval #real-model
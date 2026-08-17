---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m08cn49q5crm5q4j5r6t5p6x
  text: |-
    Context from `^vjf3mdm`, which lands before this card is measured: the eval seeds grew.

    Each seed transcript now carries an authored background paragraph in its foldable head, because a fold of the old heads was always discarded — `Compactor.compact` refuses a fold that leaves the transcript no smaller, and a 128-token summary of a 150-byte span is larger than the span. Measured over the built seeds:

    - Whole seed: about 100-185 estimated tokens before, 419-520 now.
    - Foldable span: 319-444 estimated tokens now, against a worst-case real summary of 154.

    What that does to the runtime this card measures:

    - The generation ceilings did not move. One summarizer call at `summary allowance + reasoningTokenHeadroom`, and one answering turn at `GatedRealModelBudget.responseTokenCeiling`, exactly as before. Generation is what dominates the wall clock, so the growth should not multiply the run.
    - Prefill grew by roughly 300 tokens per summarizer call and by the same again on the resumed session.
    - `CompactionEvalSeedSizingTests/everySeedsFoldableSpanFitsOneSummarizerCall` pins the seeds under `Summarization.maxChunkTokens`, so a fold still makes exactly ONE summarizer call. That bound exists to stop a seed from silently turning one call into a map-reduce tree and multiplying this suite's model calls.

    So re-measure against the grown dataset rather than against the 9-samples-in-1200-s figure recorded above; that figure was taken before the seeds changed.
  timestamp: 2026-08-17T17:35:06.039113+00:00
- actor: claude-code
  id: 01m08nzxj3b19j0r57y5fm9wj0
  text: |-
    ## Decision (from the user, 2026-08-17)

    Shrink the gated tier and keep a short limit.

    - The default gated tier (`FM_ROUTER_INTEGRATION_TESTS=1`) runs a representative subset of about 6 to 8 seeds and fits a 20 to 30 minute limit.
    - The full 24-seed set moves behind a second opt-in variable, with its own longer limit.

    Reason for the choice: the everyday gated run stays affordable and CI-friendly. The cost accepted is that `factRetention >= 0.9` is measured on the subset by default, and the whole-dataset number comes only from the opt-in run.

    This is what changed the size of the problem: `^vjf3mdm` grew every seed from about 100-185 estimated tokens to 419-520, so the ~45 minute figure in this card's description is now too low. Do not trust it. Measure.

    The subset must be chosen for coverage, not by taking the first N. The dataset spans single-fact and multi-fact heads, tool-traffic and plain-reply delivery, and `recentTurnCount` from 4 to 7. The subset must state which property each of its members carries.
  timestamp: 2026-08-17T20:18:16.771995+00:00
- actor: claude-code
  id: 01m08q44yyfjgw0pr6wzxd48bk
  text: |-
    Research done. What the code shows, before any edit:

    **The gate pattern to match.** Every gated suite in this repository states its own file-scoped `private let <name>EnvVar = "FM_ROUTER_INTEGRATION_TESTS"` plus a `private var <name>Enabled: Bool { ProcessInfo.processInfo.environment[...] != nil }`, and passes that to `.enabled(if:)`. Swift's top-level `private` is file-scoped, not target-scoped, so each file keeps its own copy on purpose — several files say so in their own comments. The second variable follows the same shape in the same file.

    **The time limit is shared today.** `gatedEvalSuiteTimeLimitMinutes = 20` lives in `Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift` and BOTH eval suites read it — `CompactionEvaluationIntegrationTests` and `CompactionContinuityEvaluationTests`. Raising it would move the continuity suite too, which this card never asked for. So the compaction tiers get their own constants and the continuity suite keeps the shared one untouched.

    **What the dataset varies.** 24 fixtures. Read off `compactionEvalFixtureSpecs`: fact counts 1, 2 and 3; `probedFactViaTool` true on 7 and false on 17; `recentTurnCount` 4, 5, 6 and 7; `probedFactIndex` 0, 1 and 2. Those four are the properties a subset has to span, and `CompactionEvalSeed` carries none of them — it keeps only id, entries, plantedFact, factKeyPhrase and question. So the coverage test has to read `compactionEvalFixtureSpecs`, not the built seeds.

    **Where the misleading table is written.** `CompactionEvalFactRetentionReport.lines(of:)` heads the table `"FactRetention per-sample evidence — \(findings.count) samples"` and closes it with the `counts:` tally. It is given only the samples that ran, so it has no way to know what never ran. It needs the seed set the tier was supposed to cover.

    **Callers of `lines(of:)`**: the gated `@Test`, and four hermetic tests in `CompactionEvalFactRetentionReportTests` (two of them through the `renderedTable(for:)` helper). All five move to the new signature.

    **One `--filter` note.** The card sanctions `swift test --filter CompactionEvaluationIntegrationTests`. `--filter` is a regex, so a second suite must not carry that name as a substring, or the sanctioned command would run both tiers. The full-set suite is therefore named `CompactionEvalFullDatasetIntegrationTests`.
  timestamp: 2026-08-17T20:38:03.998117+00:00
- actor: claude-code
  id: 01m08skk6q1cvqb6qvyegwf84c
  text: |-
    Implementation landed, and the measurement is in.

    **The measurement.** `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` over the seven-seed subset: **passed in 1644.7 seconds — 27.4 minutes**, `7 of 7 seeds measured`, mean `FactRetention` 1.0. That is 235 seconds a sample, with the model load inside it. The old 20-minute limit is below the measurement; 30 fits it with 2.6 minutes over, which is thin and the constant says so — this runner leaves the provider's own sampling in place rather than pinning `.greedy`, so answer lengths move between runs of identical code.

    **The full tier's limit is DERIVED, not measured**, and its doc comment states that in the first line. 235 seconds a sample over 24 samples is 5639 seconds — 94 minutes; the constant is 120. The derivation over-states the work, because the rate carries a one-time model load spread over seven samples and multiplying it by 24 charges that load more than three times.

    **What the run also showed, and what it did NOT prove.** All seven samples report `summarizerCalls=1` with an EMPTY stage list and `summary=<discarded>`, so `factInSummary=false` on 7 of 7. Every `retained` verdict came from a transcript the pipeline handed back unchanged, not from a summary. The 1.0 is real and it is a pass for the wrong reason. That is `^vjf3mdm`'s still-open third acceptance criterion, and it is a defect of its own rather than of this card, so it is filed as **`^fm5ddk9`** with the evidence.

    **Dead end avoided, recorded for the next agent.** The obvious shape — one suite whose seed set switches on the second variable — cannot work: `.timeLimit` and `.enabled(if:)` are suite traits evaluated when the test is registered, so one suite cannot carry two limits. Two suites is what the tiering costs, and the second one is named `CompactionEvalFullDatasetIntegrationTests` rather than anything containing `CompactionEvaluationIntegrationTests`, because `swift test --filter` is a regular expression and the everyday targeted command would otherwise select both tiers.

    **One transient red seen and not reproduced.** A `swift test` run immediately after the 27-minute GPU run failed `HumanWaitGateTests` ("a human wait overlapping a turn it is not part of…", `RunNeverFinished`) and `GenerationStallDiagnosticTests` ("a streaming turn reports the stall against the fragments it counted"). Both are wall-clock-bounded waits in files this change does not touch; the next run of the same code was green. Recorded so the next agent does not chase it as a regression of this card.
  timestamp: 2026-08-17T21:21:27.255939+00:00
- actor: claude-code
  id: 01m08smjpp44eqx6m9wxq73rag
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift
    - verification: `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift test` 974 + 27 + 45 tests, 0 failures, 1 pre-existing known issue (BoundedWait). `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` passed in 1644.7 s, 7 of 7 seeds measured
    - new cards: `^fm5ddk9` — the real model still discards every fold, so `factInSummary=false` on 7 of 7 and the 1.0 is a pass for the wrong reason
    - next: `/review`
  timestamp: 2026-08-17T21:21:59.510937+00:00
- actor: claude-code
  id: 01m08srrgpc8pxw20kkvyz91zq
  text: |-
    ### test — green
    - evidence: `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` clean, 0 warnings; `swift test` (ungated, no `FM_ROUTER_INTEGRATION_TESTS` / `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` set) — 3 bundles, 974+27+45=1046 tests, 0 failures, 1 known issue (pre-existing `withKnownIssue` in `BoundedWait ends every wait on a wall clock, never on a count of scheduler hops`, expected)
    - gated real-model suites and the full-dataset suite reported `skipped`, as designed by the two-tier split; not run per instruction (no gating env vars set)
    - next: none
  timestamp: 2026-08-17T21:24:16.534252+00:00
- actor: claude-code
  id: 01m08svnntp5heed6c3nt95b7h
  text: |-
    ### commit — changed
    - evidence: a58f55c test(evals): split the compaction eval into a subset and full-dataset tier (^fz49qds)
    - next: local commit only, not pushed.
  timestamp: 2026-08-17T21:25:51.930917+00:00
position_column: doing
position_ordinal: '80'
title: 'The gated compaction eval no longer finishes inside gatedEvalSuiteTimeLimitMinutes: 9 of ~20 samples in 1200 seconds'
---
Found by the targeted gated run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` while verifying `^bgxtdk3`.

## What happens

```
✘ Test "Compaction retains pre-fold facts" recorded an issue at CompactionEvaluationTests.swift:458:6: Time limit was exceeded: 1200.000 seconds
FactRetention per-sample evidence — 9 samples
```

The suite carries `.timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))`, which is 20 minutes. The run reached 9 of the roughly 20 seeds and the trait stopped it. Each remaining seed is simply never measured, and the `@Test` fails on the time limit rather than on its own assertion.

## Why

`^bgxtdk3` raised each summarizer call's ceiling from 500 tokens to the summary allowance plus 4096 tokens of reasoning headroom, because the gated model always writes a `<think>` block and 500 tokens left no room for an answer at all.

The old ceiling is what made the suite fit. A generation that stops at 500 tokens is fast, and it was fast because it was producing nothing usable — every one of those 19 samples stored an empty summary. Real reasoning plus a real answer costs real time, and each sample pays it twice: once for the summarizer call inside the fold, and once for the answering turn on the resumed session (`GatedRealModelBudget.responseTokenCeiling`, also 4096).

So the time limit did not become wrong. What it bounded became honest.

## What was decided

The user decided on 2026-08-17: shrink the gated tier and keep a short limit. The default tier measures a representative subset that fits a 20 to 30 minute limit, and the whole 24-seed dataset moves behind a second opt-in variable with its own longer limit.

## Acceptance Criteria

- [x] The gated compaction eval runs every seed and ends on its own assertion, never on the suite time limit
- [x] A run cut short states the seeds it never reached, so a partial table cannot read as a whole one
- [x] The chosen time limit is stated with the measurement behind it, the way `GatedRealModelBudget` states its own

The first criterion is held by measurement for the DEFAULT tier: the run of 2026-08-17 measured 7 of 7 subset seeds and passed on its own assertion in 1644.7 seconds, inside the 30-minute limit. The opt-in whole-dataset tier is not measured — running it costs the hour and a half its limit exists to bound, and the user did not sanction that cost — so its limit is derived from the subset's per-sample rate and its constant says so. #compaction #eval #real-model
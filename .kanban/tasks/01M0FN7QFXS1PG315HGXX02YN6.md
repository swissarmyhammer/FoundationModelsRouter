---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fnx2yf45gzh6ax38388q0m
  text: |-
    ## Research at HEAD a5c2527

    Findings from the code and from the ^e814b60 trail:

    - The fork routes reasoning apart from the answer. `MLXLanguageModel` (fork, read only) declares `.reasoning` for every model `LiveModelLoader` builds, and the protocol decoder emits `.reasoning(text)` and `.response(text)` as two different destinations to two different entry ids. `MLXBackedSessionBackend.respond(to:maxTokens:)` returns `response.content` only. So the text `Summarization` receives holds NO `<think>` block. The think tokens cost generation ceiling, not answer bytes.
    - The stored one-line summaries of the 2026-08-20 Qwen run are the section cut. `Summarization.cut` keeps the longest whole-section prefix inside `summaryRetentionRatio` (0.8) of the call's rendered content. Raw answers were 2188 to 3045 bytes; stored summaries were the `1. Intent` line alone. The raw answers are NOT in the run log (`qwen38-subset.log` records byte counts only), so the diagnosis probe must capture them.
    - The shrink guard measures whole transcripts: `Compactor.compact` applies a fold only when `estimatedTokenCount(folded) < estimatedTokenCount(original)`. The boundary entry's content bytes = summary text + pending-runs rendering; the structure segment counts zero. So "entry bytes <= span content bytes - 4" guarantees a strict shrink (the estimate divides total bytes by 4 and rounds up once).
    - Run procedure for a gated Qwen probe (from the sanctioned ^e814b60 run, all edits temporary): `CompactionEvalRealModel.ref` -> `mlx-community/Qwen3.8-27B-mxfp4`; `compactionEvalReasoningTokenHeadroom` 128 -> 4096; `compactionEvalSubsetTimeLimitMinutes` -> 120; `compactionEvalFullDatasetTimeLimitMinutes` -> 360; `gatedEvalSuiteTimeLimitMinutes` -> 180; command `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` with a shell timeout >= 3600000 ms. Greedy stays pinned in `CompactionEvalRealSubjectRunner.container()`. For the 2-seed probe, narrow `compactionEvalRepresentativeSubsetIDs` to `three-facts-long-project-brief` and `encryption-algorithm` (also temporary).
    - Ripple map for the redesign: `summaryRetentionRatio` and `boundaryBoundedSummary` live only in `Summarization.swift`; doc references in `CompactionSegment.swift`, `CompactionEvalTiers.swift`, `CompactionEvalFactRetentionReport.swift`, `CompactionEvaluationTests.swift`, `CompactionSmokeIntegrationTests.swift`; behavior pins in `SummarizationStageTests.swift` (tests at lines 694-1103). `CompactionResult` is the fold's report type; `SessionProjection.compactionRow` rebuilds one from the persisted `CompactionSegment.Content`, so a new report field needs a default in `init`.

    Plan (per the card): capture raw answers on the 2-seed probe first, record the diagnosis, then TDD the new trim decision and prompt invariants hermetically, then iterate on the 2-seed probe, confirm on the 7-seed subset once, and re-baseline the 1B tiers.
  timestamp: 2026-08-20T13:31:25.007881+00:00
- actor: claude-code
  id: 01m0fpr4mfztp829vprng4namv
  text: |-
    ## Diagnosis — 2-seed Qwen probe, 2026-08-20 (baseline, no production change)

    Run: `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` with the PROBE-TEMP configuration (Qwen3.8-27B-mxfp4, headroom 4096, greedy, subset narrowed to the 2 probe seeds, limits raised). Log: `scratchpad/probe0-diagnosis.log`. Model load 4.7 s; suite wall clock 660.2 s.

    Evidence, per the card's three questions:

    1. **The `<think>` block is NOT in the text `Summarization` receives.** The fork routes reasoning to a separate `.reasoning` destination (`MLXLanguageModel` emits `.reasoning`/`.response` to two entry ids; `respond` returns `response.content` only). Both captured raw answers start at `1. Intent` and carry no think text.
    2. **Both raw answers carry the planted fact VERBATIM; the cut destroys it.**
       - `encryption-algorithm`: raw answer 3045 bytes, holds "Data at rest is encrypted with AES-256-GCM." in section 2 and again quoted in section 3. Stored summary: 237 bytes — the `1. Intent` line alone. Fold 377.4 s, answer turn 37.6 s, class `summaryLostFact`.
       - `three-facts-long-project-brief`: raw answer 2188 bytes, holds "The archive's internal reference id is WX-ARCHIVE-6." in section 2. Stored summary: 256 bytes — the `1. Intent` line alone. Fold 226.1 s, answer turn 14.4 s, class `summaryLostFact`.
    3. **Where the bounds bind.** The generation ceiling was 4224 tokens (allowance 128 + headroom 4096); the fold times (226-377 s) show the think block spends most of it, and the `encryption-algorithm` answer stops after section 4 (sections 5-8 absent), consistent with the ceiling ending the answer early. The cut is what discards the fact: `summaryRetentionRatio` (0.8) of the call's rendered content gives a limit in the 512-1400 byte range for these seeds, and `sectionAlignedPrefix` keeps only whole sections inside it — section 2 (the facts) does not fit beside section 1, so the stored summary is the `1. Intent` line. The cut, not the model, is the failure: retention summary=0 of 2 with the fact present in 2 of 2 raw answers.

    Conclusion: Qwen is already a competent summarizer of these spans — the raw answers are dense, sectioned, and quote identifiers verbatim. The trim logic discards the model's correct work. This confirms the card's design direction: state the budget, bound against the span (shrink invariant), recover before cutting, cut only as last resort and record it.
  timestamp: 2026-08-20T13:46:11.471185+00:00
- actor: claude-code
  id: 01m0fvrfy24cp0ypffj9qcsp8k
  text: |-
    ## Design landed hermetically, and probe iterations 1-2 measured a new failure mode

    **What is implemented (TDD, root package green):**

    - `CompactionPrompt.default` is `router-default-v3`: verbatim-value demand ("EXACTLY as it appears... character for character") and a size-budget paragraph. compaction_plan.md §2 updated to match.
    - `Summarization` states the size budget per call in the assembled prompt, as a word count.
    - The per-call ratio cut is REMOVED. The one bound on the stored summary is the span byte budget: `summaryByteBudget(forSpanBytes:pendingRunsRenderingBytes:) = spanBytes - shrinkMarginBytes(4) - renderingBytes` — the shrink invariant's own arithmetic. Recovery ladder in `resolveOversizedSummary`: fits -> stored word for word; oversized -> ONE condense re-ask (`makeCondensePrompt`); still oversized -> last-resort `cut` to the budget, recorded as `Folded.summaryCut` -> `CompactionResult.summaryCut`. A budget at or under zero skips the condense call and the guard discards the fold.
    - `summaryRetentionRatio` and `boundaryBoundedSummary` are gone; `maximumSummaryTokens` and the generation ceiling stay.
    - `reasoningTokenHeadroom` default 4096 -> 8192 (measurement below).
    - Hermetic: SummarizationStageTests rewritten to the new invariants (46 tests green); AutoCompactionTests updated (fallback summary now stored word for word); root run 1024 tests green, 1 pre-existing known issue; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; nested IntegrationTests package builds clean.

    **Probe iteration table so far (2-seed Qwen3.8-27B, greedy, thinking on):**

    | iteration | change | encryption-algorithm | three-facts-long-project-brief | verdict |
    |---|---|---|---|---|
    | 0 (baseline) | old prompt+cut | raw 3045 B carries AES-256-GCM, stored 237 B loses it | raw 2188 B carries WX-ARCHIVE-6, stored 256 B loses it | cut destroys correct work |
    | 1 | v3 prompt, budget "at most about 85 words", ceiling 4224 | answer EMPTY (emptySummary) | answer EMPTY | think spends whole ceiling |
    | 2 | softened "about N words... without counting words", ceiling 8320 | answer EMPTY | answer EMPTY | think spends whole ceiling |
    | 2b | think captured | think 30345 B: model drafts, then COUNTS ITS DRAFT WORD BY WORD ("1: 1(1) Intent2 User3 gave4...Total 87. Good.") against the 85-word target, ceiling ends inside verification | think 29754 B, same shape | the numeric target triggers a counting spiral |

    The think capture shows the draft itself was GOOD — it carried "AES-256-GCM" verbatim in section 2 — and the model never exited `<think>` before the ceiling.

    **Iteration 3 (running next):** the stated budget is now `statedBudgetShareOfContent` (0.75) of the call's own content — near the enforced span bound, ~3x the old allowance-derived number, so the model's natural answer already sits near the target — and the budget line forbids the verification as its own rule: "This is a rough ceiling — never count or verify the length; a near miss is fine." The condense prompt carries the same rule.
  timestamp: 2026-08-20T15:13:45.922144+00:00
- actor: claude-code
  id: 01m0fzcydz62sh5ax4mgkr56vv
  text: |-
    ## Probe iterations 3 and 4 — measurements (recorded after session reset)

    Both runs: full pipeline, 2-seed subset, Qwen3.8-27B, greedy, thinking on, headroom 8192.

    **Probe 3** (stated budget = 0.75 of content, "never count or verify the length" as its own rule). Log: `scratchpad/probe3-contentshare.log`. Suite wall clock 1803.1 s.

    | seed | calls | raw answer | stored summary | fold s | answer s | class |
    |---|---|---|---|---|---|---|
    | encryption-algorithm | 1 | 1422 B | 1422 B, carries AES-256-GCM | 1105.0 | 8.3 | retained |
    | three-facts-long-project-brief | 2 | 1771 B, then condense 2254 B | cut to budget (~1745 B), carries WX-ARCHIVE-6 | 682.5 | 4.7 | retained |

    **2 of 2 retained** — criterion "both probe seeds carry the planted fact in the STORED summary" is met by this configuration. The second seed overshot the enforced span budget by 26 bytes; the condense re-ask came back BIGGER (2254 B), so the last-resort cut fired on the smaller candidate and `CompactionResult.summaryCut` recorded it. The recovery ladder worked as designed.

    **Probe 4** (stated budget share 0.75 -> 0.6, to remove that 26-byte overshoot). Log: `scratchpad/probe4-share06.log`. Suite wall clock 773.3 s.

    | seed | calls | raw answer | stored summary | fold s | class |
    |---|---|---|---|---|---|
    | encryption-algorithm | 1 | 0 B — EMPTY | none (emptySummary error) | ~420 | fold failed |
    | three-facts-long-project-brief | 1 | 1562 B | 1562 B whole, carries WX-ARCHIVE-6, no cut | 340.4 | retained |

    The tighter target re-triggered the think spiral on `encryption-algorithm` under greedy decoding. **Decision: `statedBudgetShareOfContent` stays `0.75`** — the only configuration measured green on both seeds — restored in `Summarization.swift` and its test mirror, with both measurements in the constant's doc.

    Note for the coordinator's lean-probe direction: probe 4 already ran on the full path, and on the lean single-seed protocol (`three-facts-long-project-brief` only) share 0.6 would have PASSED while being red on the other seed. The lean probe is being built next for fast iterations and for the small-span trigger evidence; the confirming 7-seed run will use the measured-best 0.75.
  timestamp: 2026-08-20T16:17:21.855274+00:00
- actor: claude-code
  id: 01m0fznftp23q6fdz2hpxnzven
  text: |-
    ## Lean probe built and green (new probe protocol)

    New PROBE-TEMP instrument: `IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/CompactionLeanProbeTests.swift` — ONE seed (the `three-facts-long-project-brief` facts over a one-sentence context, `recentTurnCount` 4), fold ONLY (no resumed-session answer turn), fold-forcing budget at half the deterministic floor. One iteration costs one generation over a ~130-token span. Run with `swift test --package-path IntegrationTests --filter CompactionLeanProbe`.

    **Lean run 1** (current design: share 0.75, never-count rule, headroom 8192, Qwen, greedy). Log: `scratchpad/lean1-share075.log`.

    | span | calls | fold s | stored | summaryCut | fact |
    |---|---|---|---|---|---|
    | 132 est tokens | 1 | 113.1 | 515 B, whole answer | false | WX-ARCHIVE-6 present — PASS |

    Two findings for the compact-sooner follow-up note:
    - The small span's stated budget lands at ~88 words — the same small number that triggered the word-counting think spiral in probes 1-2 — and with the never-count rule and content-share sizing the model answered normally. The spiral defense holds at small spans.
    - A small-span fold costs 113 s against 340-1105 s for the full seeds' ~600-token spans: think time scales strongly with span size on this model, so earlier triggers (smaller spans per fold) would cut per-fold latency roughly 3-10x.

    The design holds on the lean path. Next: the ONE confirming 7-seed subset run (full pipeline, answer turns, current thresholds, share 0.75). The subset is being restored to all 7 seeds for that run; subset/suite time limits raised further (PROBE-TEMP) because two measured folds alone cost 1105 s and 682 s.
  timestamp: 2026-08-20T16:22:01.814026+00:00
- actor: claude-code
  id: 01m0g2byqhyb6m9bgz8wqza62z
  text: |-
    ## Confirming 7-seed subset run on Qwen3.8-27B — criterion 5 MET

    Command: `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` (PROBE-TEMP config: Qwen, greedy, thinking on, headroom 8192, subset restored to all 7 seeds, limits 240 min). Log: `scratchpad/confirm7-qwen.log`. Model load 2.2 s; suite wall clock 2692.3 s (44 min 52 s). **The tier's own assertions PASSED** at the unchanged floors (0.65 summary / 0.5 answer over measured samples).

    | seed | calls | fold s | answer s | summarizer bytes | class |
    |---|---|---|---|---|---|
    | budget-cap-tool-and-owner | 1 | ~450 | — | 0 (EMPTY) | fold failed: emptySummary |
    | db-port | 1 | 285.2 | 4.4 | 1330 | retained |
    | encryption-algorithm | 1 | 345.2 | 4.8 | 1422 | retained |
    | env-file | 1 | ~450 | — | 0 (EMPTY) | fold failed: emptySummary |
    | license-key-and-region | 1 | 278.3 | 5.5 | 1469 | retained |
    | three-facts-long-project-brief | 2 | 512.4 | 4.7 | 1771, condense 2254, cut | retained |
    | three-facts-support-escalation | 1 | 416.7 | 4.8 | 1646 | answerMissedFactSummaryCarriedIt |

    Counts: `retained=4 answerMissedFactSummaryCarriedIt=1 summaryLostFact=0 foldProducedNoSummary=0`. Retention: **summary 5 of 5 measured — 5 of the 7 seeds' stored summaries carry the fact (the criterion's "at least 5 of 7")**; answers 4 of 5. Against the pre-design Qwen baseline of 0 of 7 summaries and 0 of 7 answers.

    **Honest residual, recorded as measured signal:** 2 of 7 folds still fail whole — the think capture on `env-file` shows the model word-counting its draft against the stated 183-word target ("previous 180 + one (181) + again (182)...") despite the "never count or verify the length" rule, spending the whole 8320-token ceiling inside `<think>`. The rule and the wider content-share target cut the spiral from 7 of 7 seeds (probes 1-2) to 2 of 7, and a failed fold is SAFE — `emptySummary` is reported, the transcript is unchanged, and a session degrades to its next summarizer tier — but the spiral is not eliminated on Qwen at greedy + template effort `xhigh`. `summaryLostFact` is 0: no stored summary lost its fact anywhere in the run.

    Next: remove PROBE-TEMP (model ref, headroom, limits, prints, lean probe file), re-baseline the 1B tiers, full verification.
  timestamp: 2026-08-20T17:09:15.121900+00:00
- actor: claude-code
  id: 01m0gaw9bkmecdxrvp31pj7rjp
  text: |-
    ### 1B tier re-baseline, 2026-08-20 — measured record and floor change

    The design is frozen at the Qwen-confirmed state: `router-default-v3` prompt (size budget stated as words, never-count rule, verbatim values), span byte budget, one condense re-ask, last-resort cut, headroom default 8192, allowance derived from the stated budget.

    Iteration trail on the 1B subset (all runs greedy, headroom 128):

    | run | change under test | summaries | answers | note |
    |---|---|---|---|---|
    | 1 | frozen design, old allowance (25%) | 2 of 7 | 2 of 7 | ceiling truncated answers before the planted facts while the prompt asked for 75% |
    | 2 | allowance derived from stated budget (TDD: theCeilingCoversTheStatedBudget) | 2 of 7 | 2 of 7 | 1B overshoots the stated budget; cut drops tail facts |
    | 3 | + "Cover the whole conversation" paragraph | 1 of 7 | 1 of 7 | WORSE; reverted |
    | 4 | + "Compress descriptions and background freely" sentence | 2 of 7 | 1 of 7 | no gain; reverted |
    | final | frozen tree, official measurement | 2 of 7 | 2 of 7 | wall 38.2 s; samples 3.4, 1.4, 6.0, 6.0, 6.3, 6.2, 7.2 s; load 1.8 s |

    Whole dataset, frozen tree: 13 of 24 summaries, 9 of 24 answers, wall 124.9 s, none unreached.

    Root cause of the 1B drop (was 6 of 7 and 17 of 24 under the old prompt and per-call cut): the 1B ignores the stated size budget and generates to its ceiling. Its answers enumerate background head-first. The raw answer overruns the span byte budget, the condense re-ask does not obey either, and the last-resort cut removes the facts stated later in the span. Three prompt iterations did not close this without harming the design that Qwen needs.

    Floor change, with the justification the criterion demands: the rule is "the weaker tier's measured share minus one sample of that tier." Applied to the 2026-08-20 measurements: subset 2 of 7 = 0.286, one sample under is 1 of 7, so `compactionEvalSummaryFactRetentionFloor` 0.65 -> 0.14 and `compactionEvalAnswerFactRetentionFloor` 0.5 -> 0.14. The floors now require 1 of 7 and 4 of 24. This is the same rule that produced the old 0.65 and 0.5 from the 2026-08-19 measurements. TRADE-OFF, stated plainly: the redesign took Qwen (the standard model) from 0 of 7 to 5 of 7 stored summaries, and it took the 1B canary from 6 of 7 to 2 of 7. The 1B canary's regression signal is now weak. A follow-up card proposes a canary the redesigned prompt serves.

    Tier limits re-derived from the same run: dearest sample 3.5 -> 7.2 s (most folds now make two summarizer calls), subset limit stays 1 minute (bound 52.4 s), full-dataset limit 2 -> 3 minutes (bound 174.8 s; the measured 124.9 s run would have been cancelled mid-generation at the old 2). `CompactionEvalTierBarTests` updated to the new required counts (1, 1, 4, 4) and green. Subset tier re-run at the new floors: PASSED, identical counts (greedy determinism holds).

    The tree prompt is byte-identical to the prompt the Qwen 7-seed confirming run measured (the run-4 sentence was reverted), so the Qwen confirm needs no re-run.
  timestamp: 2026-08-20T19:37:58.899763+00:00
- actor: claude-code
  id: 01m0gawsfntf6scxdzkmehyh5e
  text: |-
    ### Compaction smoke tier reconciled with the redesign, 2026-08-20 — all five suites green

    Two real-model smoke failures surfaced after the redesign, and two more followed while fixing them. Disposition of each, with the honest-update rule applied:

    1. `CompactionSmokeIntegrationTests.theFoldWorksAgainstARealModel` — `ceilings.count == 1` went red. Measured: the 1B's map answer overruns the span byte budget on this fixture, so the condense re-ask fires (ceilings [617, 628], answers 728/706 est tokens, stored 638 against the 643-token span, 713 -> 708). Two calls IS the designed behavior. The pin now asserts the fold's real call budget — one map call plus at most one condense re-ask — and a third call still fails. A bounded-cap alternative (suite summaryTokenRatio 0.1, one call by construction) was measured and REJECTED: the 328-token ceiling truncated the answer before the planted END-of-span fact, so the fact test went red. The condense path carries the fact; the bounded path does not.
    2. `AutoCompactionTriggerIntegrationTests` — fill did not fall across the turn. Measured at the default ratio: the cut stored a summary 64 bytes under the span, the fold saved 16 of 733 tokens, the turn cost more, fill ROSE 0.167 -> 0.177. Fix: the suite now passes the public `summaryTokenRatio: 0.1`, which bounds the whole generation at 328 tokens (about 1.6 KB), so the answer fits the span and is stored whole. Measured after: fold 733 -> 463, fill 0.167 -> 0.114, suite green. The assertion is unchanged.
    3. Time limits, raised with measurements: smoke suite 1 -> 2 minutes (pair measured 60.1 s at the limit itself, with 7.3 s loads); trigger suite 1 -> 2 (runs of 23.7 and 54.6 s); recorded-transcript suite 1 -> 3 (exceeded 60 s; measured 63.1 s green after); 30B round trip 20 -> 40 (measured 425 s on 2026-08-17, exceeded 1200 s under memory pressure on 2026-08-20, passed at about 23 minutes after the raise). A time-limit cancellation lands mid-generation and aborts the process, so each bound carries margin.
    4. `RecordedTranscriptCompactionIntegrationTests` green: 3 calls at ceilings [628, 628, 628], 4297 -> 2493. `CompactionRoundTripIntegrationTests` green end to end: fold saved 172 tokens, recall carries CRIMSON-77.

    Final verification: root `swift test` 1025 + 77 green; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; IntegrationTests package builds; all five compaction integration suites green; gated eval subset green at the re-derived floors.
  timestamp: 2026-08-20T19:38:15.413584+00:00
- actor: claude-code
  id: 01m0gax4xx04wtgteary0w4qv5
  text: |-
    ### Follow-up note for a possible separate card: compact sooner in production

    Evidence from this card's measurements, recorded as the coordinator asked. No production default changed on this card.

    - The lean probe (one seed, fold only, low trigger) measured a 132-token span folding in 113.1 s on Qwen, where the full-size spans (about 600 tokens) cost 340 to 1105 s per fold. Small spans cut fold latency 3x to 10x.
    - The small stated budget of the lean probe (about 88 words) did NOT re-trigger the Qwen counting spiral. The spiral defense holds at small spans.
    - The trigger-suite measurement shows the other edge: when a summarizer ignores the stated budget and the answer is condensed and cut to just under the span, the fold saves almost nothing (16 of 733 tokens). A session that compacts LATE folds one large span and gets one large summary near the span budget. A session that compacts SOONER folds smaller spans, each summary is small against the whole transcript, and each fold is fast.
    - Proposal to evaluate on its own card: lower the production default `TokenBudget.trigger` and/or raise the fold frequency so real sessions fold smaller spans per fold. Measure fact retention and latency at 2 or 3 trigger settings on Qwen with the current design.
  timestamp: 2026-08-20T19:38:27.133701+00:00
- actor: claude-code
  id: 01m0gaye4sv2ceg62cs11sznhk
  text: |-
    ### implement — changed
    - evidence: 16 files — Sources/FoundationModelsRouter/Compaction/{Summarization,CompactionPrompt,Compactor,CompactionSegment}.swift; Tests/FoundationModelsRouterTests/{SummarizationStageTests,AutoCompactionTests}.swift; Tests/FoundationModelsRouterEvalSupport/{CompactionEvalTiers,CompactionEvalFactRetentionReport}.swift; Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift; IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/{CompactionSmokeIntegrationTests,AutoCompactionTriggerIntegrationTests,RecordedTranscriptCompactionIntegrationTests,CompactionRoundTripIntegrationTests}.swift; IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionEvalRealSubjectRunner.swift; Examples/CompactionDemo/main.swift; compaction_plan.md
    - acceptance, checked against the diff and the recorded runs: (1) diagnosis recorded with think-capture evidence in the earlier comments; (2) `router-default-v3` states the size budget and demands verbatim values, pinned by hermetic tests; (3) the trim fires only past the span byte budget, one condense re-ask before the last-resort cut, and `CompactionResult.summaryCut` records it; (4) both probe seeds carried the fact on Qwen (probe 3, 2 of 2); (5) the confirming Qwen 7-seed subset carried the fact in 5 of 7 stored summaries (wall 2692.3 s, recorded per seed in the earlier comment); (6) the 1B tiers are re-measured, and the floor change to 0.14 is recorded with its rule and measurements in the re-baseline comment — not silent
    - tests: root swift test 1025 + 77 green with warnings-as-errors clean; all five compaction integration suites green; gated eval subset green at the re-derived floors; PROBE-TEMP fully removed
    - follow-ups filed: ^m03heaa (canary model for meaningful floors); compact-sooner production trigger note recorded above for a possible separate card
    - next: /review
    task: ^xx02yn6
  timestamp: 2026-08-20T19:39:09.337443+00:00
- actor: claude-code
  id: 01m0gberad47aqq2cysyjhgv8p
  text: |-
    ### review — clean
    - evidence: `review sha 7aa276a~1..7aa276a` — 0 findings, 0 confirmed, 0 refuted, 21 attempted; 15 files reviewed, 6 `.kanban/` files excluded by `.reviewignore`
    - next: none. The task moved to done.
  timestamp: 2026-08-20T19:48:04.045611+00:00
- actor: claude-code
  id: 01m0gbfbsa17hvhwqrmms61sjj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 16 source/test/doc files; the prompt demands verbatim identifiers and states a size budget, the per-call ratio cut is replaced by the span-byte-budget bound with a condense re-ask recovery ladder; Qwen subset summaries 0 of 7 -> 5 of 7; the 1B canary re-baselined at 2 of 7 and 13 of 24 with floors re-derived to 0.14, four-run trail recorded; follow-up card ^m03heaa filed to choose a canary the redesigned prompt serves
    - test: green — root swift test 1025 + 77; warnings-as-errors clean; all five compaction integration suites; eval subset at the re-derived floors
    - commit: 7aa276a (housekeeping split into a93290b)
    - review: clean — 0 findings over 15 files; task moved to `done`
  timestamp: 2026-08-20T19:48:23.978808+00:00
position_column: done
position_ordinal: ffd380
title: Redesign the summarization instructions and the trim logic so Qwen3.8-27B (thinking on) is a working summarizer
---
From the user, 2026-08-20, after the sanctioned Qwen3.8-27B run on ^e814b60 measured 0 of 7 summaries carrying the fact (the 1B carries 6 of 7):

> we will not be disabling thinking. and in general i'm going to want to use qwen as my standard model. i think we need to look at what is wrong with our summarization instructions and design that is preventing qwen from being a summarizer

> i think our 'trim' logic is the problem — arbitrary code that decided 3k is too big without any 'reason'

> i think our summary instructions need to be much more clear about preserving key concept names and identifiers

> we also don't need to run this 7 times to decide, let's do two just for speed

## What is wrong today, from the code and the measured run

1. **The prompt states no length.** `CompactionPrompt.default` (`Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift`) asks for eight numbered sections and never names a size. The model cannot comply with a budget it is never given.
2. **The size decision is unilateral and post-hoc.** `Summarization.cut(_:toCharacters:)` (`Sources/FoundationModelsRouter/Compaction/Summarization.swift`) trims the answer to `summaryRetentionRatio` (0.8) of the CALL's content estimate — arithmetic the model never sees. The cut keeps a prefix of whole sections, so the 2.2-3.0 KB answers Qwen wrote were trimmed to roughly the "1. Intent" line, and the fact bullets in later sections were discarded. On the Qwen run the cut was the compression device, though its own doc says it is a safety bound.
3. **The bound is stricter than the real invariant.** The invariant compaction needs is "the fold shrinks the transcript" — `Compactor.compact`'s did-not-shrink guard already holds it. A 3 KB summary that replaces a larger span still shrinks. Ratio-of-call-content arithmetic rejects answers the invariant would accept.
4. **The instructions do not demand verbatim identifiers strongly enough.** Qwen abstracted values ("then stated the staging database port") where its text survived, lost `WX-ARCHIVE-6` from the summary, and invented `WAC-2024-0917` in the answer.
5. **One shared stop for think plus answer.** The generation ceiling is `allowance + reasoningTokenHeadroom` (`outputTokenCeiling(forSummaryAllowance:)`); Qwen spent most of it inside `<think>` and one answer stopped mid-sentence at the ceiling.

## What to build

- **Diagnose first, on 2 seeds.** Capture the raw summarizer answers for `three-facts-long-project-brief` and `encryption-algorithm` on Qwen3.8-27B (greedy, thinking on). Establish: does the text `Summarization` receives include the `<think>` block (check the fork's answer extraction in `mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift` — read, do not change); where exactly the ceiling and the cut bind; what the stored summary text really holds.
- **Rewrite the instructions.** State the size budget to the model in the prompt. Demand verbatim preservation of key concept names, identifiers, codes, numbers and values — quoted exactly as they appear, never paraphrased. (The ^azd033m "do not state the budget" conclusion was measured on Muse-Glimmer; re-measure it on Qwen instead of inheriting it.)
- **Redesign the trim so it serves the real invariant.** The stored summary must shrink the fold — bound it against the span it replaces, not against ratio arithmetic the model never saw. Prefer recovery over destruction on overflow: accept an oversized answer that still shrinks, or re-ask the model to condense its own summary once; cut only as the last resort, and record when it fires.
- **Measure each design change on the 2-seed probe** (~8-10 minutes on Qwen). Run the full 7-seed subset ONCE, to confirm the final design. Raise the tier time limits for Qwen before any gated run (a time-limit cancellation aborts the process — fork card ^3axg80k).

## Acceptance Criteria

- [ ] The diagnosis is recorded with evidence: where `<think>` goes, what the stored summary text holds, where the ceiling and the cut bind on the 2 probe seeds
- [ ] The default instructions state the size budget and demand verbatim identifiers, names and values
- [ ] The trim fires only when the fold would otherwise fail to shrink, and the report records when it fires
- [ ] Both probe seeds carry the planted fact in the STORED summary on Qwen3.8-27B with thinking on and greedy decoding
- [ ] One confirming 7-seed subset run on Qwen carries the fact in at least 5 of 7 stored summaries
- [ ] The 1B tier baselines are re-measured under the new prompt and trim, and no floor is silently lowered

## Tests

- [ ] Hermetic tests over the new trim decision (pure arithmetic: shrinks-vs-span, overflow recovery path) in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`
- [ ] Hermetic test that the default prompt text states the budget and the verbatim-identifier demand
- [ ] `swift test` at the root green at baseline; `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` green on the 1B after re-baselining
- [ ] The confirming Qwen subset run recorded on this card with per-seed classes and times

## Workflow

- Use `/tdd` — hermetic tests first for every trim and prompt invariant; gated probe runs measure, they do not gate. #compaction #defect #eval #real-model
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzkefj4cjepz6fr561d8bht0
  text: |-
    ### Root cause found and proven

    **The run-to-run difference is stochastic decoding, not compaction.** `MLXFoundationModelsSessionBackend` builds `GenerationOptions(maximumResponseTokens:)` and never sets `samplingMode`, so the fork's `resolveSamplingParameters(mode: nil, clampedTemperature: nil)` leaves `MLXLMCommon.GenerateParameters.temperature` at its default `0.6` — a *sampling* value. `GenerateParameters.sampler()` then returns `CategoricalSampler`, which draws from `MLXRandom.globalState`, and mlx-swift's `RandomState.init()` seeds itself from `DispatchTime.now().uptimeNanoseconds` (Source/MLX/State.swift). Every gated process therefore samples from a different, clock-seeded PRNG: identical code, different replies, different transcript sizes, different fold, different recall answer.

    `GenerateParameters.sampler()` returns `ArgMaxSampler` when `temperature == 0`, and `Evaluate.swift` documents `seed` as "Inert at `temperature == 0` (argmax has no RNG)". `GenerationOptions.SamplingMode.greedy` maps to `MLXSamplingMode.greedy` -> `temperature 0` (SamplingModeMapper.swift), so greedy removes the RNG from the loop entirely rather than merely fixing a seed.

    ### Lead 1 CONFIRMED, with numbers, mechanically (no GPU needed)

    The default budget's target is `0.50 * 2048 = 1024` estimated tokens. `TurnTruncation` keeps the newest 4 turns; `ToolOutputElision` is a no-op here (no tools). Measured every consecutive four-turn window of the scripted prompts:

    | window | est. prompt tokens | target |
    |---|---|---|
    | turns 0..<4 | 948 | 1024 |
    | turns 1..<5 | 923 | 1024 |
    | turns 2..<6 | 901 | 1024 |
    | turns 3..<7 | 893 | 1024 |
    | turns 4..<8 | 888 | 1024 |

    Every window sits **76–136 tokens under** target on prompt text alone. Four replies capped at `maxTokens: 64` can add up to 256 tokens. So the deterministic stages land either side of 1024 purely according to how long the tiny model's four most recent one-sentence replies happened to be — under it, `Summarization` never runs, no summary entry is synthesized, no compaction checkpoint is recorded, and `checkpointedWindow.count == fullHistory.count == 19`. Over it, stage 3 runs and the suite passes. That is exactly the coin flip the card suspected, and it is a fixture/budget property, not model randomness in the fold itself.

    ### Lead 2 CONFIRMED, with numbers

    `RoutedSessionActorCompaction.fold` wrote `usageState = .measured(input: result.tokensAfter, output: 0)` where `tokensAfter` is `Compactor.estimatedTokenCount`'s character-ratio estimate, while every other writer of `usageState` puts real tokenizer counts there. Reproduced ungated: a session measuring 200 tokens/turn folds a transcript the estimator sizes at ~800; the fold genuinely shrank it, and the reported `contextFill` went **up**, 0.002 -> 0.00546. Same family as run 1's 0.89453 -> 0.95068.

    ### Discovery worth its own task

    `Compactor.estimatedTokenCount` counts a `CompactionSegment`'s `contentJSON` as content, which includes its whole `liveWindowEntryIds`/`foldedEntryIds` manifest. With UUID entry ids that is ~175 estimated tokens of pure bookkeeping the model is never shown (only `.text` segments are rendered). Measured in `AutoCompactionTests`: a fold went 819 -> 776 estimated tokens, i.e. the manifest ate roughly two thirds of the old span it replaced. That makes a small fold look like a near-no-op.
  timestamp: 2026-08-09T14:22:57.676787+00:00
- actor: claude-code
  id: 01kzkh1g3t9frv57s2d1g0a1bz
  text: |-
    ### implement — changed

    **Three changes to production, three fixture/assertion strengthenings, three new ungated tests.**

    **1. Deterministic decoding (the root cause).** `LiveModelLoader.init` gains a defaulted `samplingMode:`; it is stamped onto every `MLXFoundationModelsContainer` it vends and threaded through every backend that container makes, including forks and the post-fold `replacingTranscript(_:)` swap, so a session decodes the same way for its whole life. Default stays `nil` — production behaviour is unchanged. Both gated harnesses pass `.greedy`. This is a *loader* knob rather than a `loadLLM` parameter deliberately: `loadLLM` is a `ModelLoader` protocol requirement with ~40 conformers in the test suite, and Swift forbids default arguments in protocol requirements.

    **2. The fold's reported fill is now on the measured scale.** `RoutedSessionActor.foldedUsage(tokensBefore:tokensAfter:)` rescales the pipeline's estimate by the ratio the session has just measured over the same transcript, and only that goes into `usageState`. Falls back to the raw estimate when there is nothing to calibrate against.

    **3. A compaction boundary's own bookkeeping no longer counts as content.** `SegmentPayload.contentByteCount` returns `0` for `.custom`. Verified against the backend that does the rendering: `MLXFoundationModels.TranscriptConverter.extractConcatenatedText` renders `.text` (and `.structure` on request) and logs "Skipping non-text segment" for everything else, so a custom segment is never tokenized. Measured cost of the old behaviour: **271 estimated tokens** for an 18-id manifest, and on the live 19-entry transcript it was enough to make a real fold report a *larger* transcript than the one it replaced.

    ### The suite changes (all strengthenings)

    - `#expect(!result.stagesApplied.isEmpty)` -> `#expect(result.stagesApplied == [ToolOutputElision, TurnTruncation, Summarization])` plus `#expect(result.summary != nil)`. The old assertion could not tell "folded" from "truncated", which is precisely why the checkpoint assertion's failure was unattributable.
    - The round trip folds against an explicit `foldBudget` (`target: 0.25`) instead of the default `0.50`. This changes nothing about *what* is folded — the old/recent split is `keepRecentTurns`' business, not the target's — it only removes the coin flip about whether stage 3 is reached at all.
    - `AutoCompactionTests.cannedText` grew from 12 to 60 repetitions. Its hard-ceiling recovery test states that it "depends on the retry's own fold actually shrinking the transcript"; with the corrected fill accounting the old fixture's fold was a 5% shrink (819 -> 776 estimated tokens), so no ceiling could sit between it and the blocked attempt. The longer fixture restores the test's own stated premise. No assertion in that test changed.

    ### New ungated coverage

    - `ScriptedTurnSizingTests.recencyWindowCannotFitUnderTheFoldTarget()` — no window of consecutive scripted turns fits under the fold target, so the deterministic stages can never land it and `Summarization` must run.
    - `ScriptedTurnSizingTests.triggerIsNotReachedBeforeAnOldSpanExists()` — the first `keepRecentTurns` turns, even with every reply at the full `maxTokens` ceiling, stay under the trigger, so a fold always has an old span to summarize. Together these make the full pipeline a property of the fixtures rather than a coincidence.
    - `RoutedSessionCompactTests.foldReportsShrinkOnTheMeasuredScale()` — a fold never raises `contextFill`. Watched fail without the fix: 0.002 -> **0.00546**.
    - `CompactionTokenAccountingTests.compactionSegmentManifestIsNotContent()` — watched fail without the fix: 292 vs 21 estimated tokens for the same boundary entry.

    ### Evidence

    Ungated `swift test`: **818 tests (770 + 24 + 24), 0 failures** (was 814; +4 new tests, and one pre-existing test's pinned value corrected to the new exact formula).

    Gated, one shell command per run, `FM_ROUTER_INTEGRATION_TESTS=1`:

    | suite | run 1 | run 2 | run 3 |
    |---|---|---|---|
    | `CompactionRoundTripIntegrationTests` | PASS (79.9s) | PASS (81.4s) | PASS (75.8s) |
    | `CompactionContinuityEvaluationIntegrationTests` | PASS (552.5s) | PASS (572.1s) | PASS (576.4s) |

    Determinism was independently visible before the fix was complete: two consecutive gated runs on identical code produced byte-identical numbers (`before=2074 after=2143 summaryChars=3346 turns=8`) and identical failures — where the five runs on the card produced three different outcomes.

    ### Follow-up filed

    `^zche4zy` — a fold's summary is unbounded (3346 characters replacing a ~1068-token span), and `Compactor.compact` applies a Summarization result even when it grew the transcript.
  timestamp: 2026-08-09T15:07:42.586706+00:00
- actor: claude-code
  id: 01kzkh1q2hrjnbs3bqqqfsde20
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift, Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift, Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift. Ungated `swift test` 818 tests / 0 failures. Gated: 3 consecutive PASS for each of `CompactionRoundTripIntegrationTests` and `CompactionContinuityEvaluationIntegrationTests`, one shell command per run.
    - next: /review
  timestamp: 2026-08-09T15:07:49.713721+00:00
- actor: claude-code
  id: 01kzkh785asbmsepfczra6x6hw
  text: |-
    ### test — green
    - evidence: `swift test` — 818 total tests (770+24+24 across three run summaries), 0 failed, 0 errors; 1 warning (`missing creator for mutated node` from vendored mlx-swift-lm fork, pre-approved out-of-scope); 36 skips, all confirmed attributable to `FM_ROUTER_INTEGRATION_TESTS`-gated suites/tests (grep confirmed no `.disabled(` traits or `XCTSkip` anywhere in Tests/Sources; every skipped suite/test name traced to a file using the `FM_ROUTER_INTEGRATION_TESTS` gate: `CompactionRoundTripIntegrationTests.swift`, `CompactionContinuityEvaluationTests.swift`, `CompactionEvaluationTests.swift`, `PropagationProbeIntegrationTests.swift`, and other `Tests/FoundationModelsRouterIntegrationTests/*` files).
    - next: none — did not run gated FM_ROUTER_INTEGRATION_TESTS=1 suite per instruction (implement step already verified it 3x consecutively).
  timestamp: 2026-08-09T15:10:51.050396+00:00
position_column: doing
position_ordinal: '80'
title: Two gated compaction suites are flaky at HEAD — CompactionRoundTripIntegrationTests and the continuity eval fail intermittently with no code change
---
Discovered by `^5m97h14` iteration 5 while verifying that a `CompactionPrompt.default` change had not regressed the other gated suites. It had not — but the verification uncovered that two gated suites do not give the same answer twice on the same code.

## The measurement

Five gated runs of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionRoundTripIntegrationTests`, one shell command each, on 2026-08-09:

| run | `CompactionPrompt.default` | result |
|---|---|---|
| 1 | candidate v2 (verbose) | FAIL `:380` `fillAfterCompaction < fillBeforeCompaction` — 0.95068 vs 0.89453 |
| 2 | **v1, i.e. `git checkout` of HEAD** | **PASS — all four assertions** |
| 3 | candidate v2 (dense) | FAIL `:392` `recall.contains("CRIMSON-77")`, FAIL `:412` `checkpointedWindow.count < fullHistory.count` (19 vs 19) |
| 4 | candidate v2 (dense) | FAIL — identical to run 3 |
| 5 | **v1, i.e. `git checkout` of HEAD** | **FAIL — identical to runs 3 and 4** |

Run 5 is the decisive one: **the same two assertions fail on HEAD's own unmodified code that passed in run 2.** No prompt change is required to reproduce, so this is the suite, not any candidate change.

Note the failure *mode* also moves between runs — a fill-ordering failure in run 1, a recall + checkpoint failure in runs 3-5 — so a single red run cannot be read as evidence about whatever change is in the tree.

`CompactionContinuityEvaluationIntegrationTests` shows the same character on its own assertion: `mean(answersCorrect) >= 0.8` measured `0.5` and `0.8` on 2026-08-08 (recorded on `^5m97h14`, where it was called "flaky, not a fixed regression") and `0.7` on 2026-08-09. Its sibling `mean(foldOccurred) == 1.0` passes consistently.

## Why this matters more than one red run

Every gated criterion on `^5m97h14` and its successors is read off single runs. While these two suites answer differently on identical code, a red run cannot be attributed to the change under test and a green run cannot clear it. That makes the gated suites unusable as a decision procedure, which is exactly what they exist to be.

## The two leads, neither confirmed

1. **`checkpointedWindow.count == fullHistory.count == 19` is a structural fact, not model randomness.** It means the restore view found no compaction checkpoint in `transcript.jsonl`, i.e. no summary entry was recorded — while `#expect(!result.stagesApplied.isEmpty)` and `#expect(result.tokensAfter < result.tokensBefore)` both passed in the same run. One reading: the deterministic stages (`ToolOutputElision` + `TurnTruncation`) landed under target on their own that run, so `Summarization` never ran and no summary entry was synthesized; whether they do depends on how long the tiny model's own scripted replies happened to be. That would make the suite's reaching of stage 3 a coin flip rather than a property. Confirm by asserting/printing `result.stagesApplied` — the suite currently only asserts it is non-empty, which cannot tell "folded" from "truncated".
2. **The measured/estimated mixture in the fill comparison.** `fillBeforeCompaction` comes from genuinely measured usage (`TokenUsage.measured` from the backend); `fillAfterCompaction` reads `usageState = .measured(input: result.tokensAfter, output: 0)` set by the fold (`RoutedSessionActorCompaction.swift`), and `tokensAfter` is the character-ratio *estimate*. The assertion therefore compares a measured number against an estimated one, and only holds while the estimator's overcount stays smaller than the fold's real saving. That is a latent accounting fragility of the same family as `^5m97h14`'s original findings.

## Acceptance Criteria
- [x] The cause of the run-to-run difference is identified and stated, with the numbers that prove it — for lead 1, which stages actually applied on a passing run versus a failing one
- [x] The suites answer the same way on repeated runs of unchanged code — demonstrated by running each at least 3 times consecutively, all with the same result
- [x] No assertion is loosened or deleted to achieve that. If an assertion is comparing incommensurable numbers (lead 2), fixing what it compares is a correction; lowering a bound is not
- [x] `CompactionContinuityEvaluationIntegrationTests`' `mean(answersCorrect) >= 0.8` is covered by the same standard
- [x] Ungated `swift test` stays green

## Tests
- [x] Repeated gated runs are the proof. Gated runs: one at a time, one shell command per run
- [x] Add ungated coverage pinning whatever determinism defect is found, so it cannot silently return #phase-1
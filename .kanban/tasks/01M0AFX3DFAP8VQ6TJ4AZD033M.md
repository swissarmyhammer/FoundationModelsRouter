---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ahn11pszenrcyd14q5gcvy
  text: |-
    Measured. The directive is not merely slow — it BREAKS the fold on the production model.

    Method: the `^w1cz46m` smoke suite, one fold, one generation, greedy decoding, `FM_ROUTER_COMPACTION_SMOKE=1` only. Never `FM_ROUTER_INTEGRATION_TESTS`, never `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET`.

    The card names two things to control for, and both were controlled:

    - **Headroom.** The suite's own `reasoningTokenHeadroom` of 128 gives a ceiling of 281, which the card correctly says makes a runaway impossible. Every measurement below was taken at `reasoningTokenHeadroom = 4096` — production's own value — so the ceiling was **4249**, within 25 tokens of the gated tier's 4224. The suite's context was raised from 4096 to 8192 so the ceiling fits inside the window. All four measurements are temporary local edits, now reverted.
    - **The model.** The 1B was measured FIRST, and it did not answer the question. Then the same one-fold experiment was run against `mlx-community/Muse-Glimmer-30B-4bit` — the gated tier's own model — which did.

    ## The 1B: no signal, and the reason is instructive

    | directive | answer, estimated tokens | generation |
    |---|---|---|
    | present | 4829 | 28.7 s |
    | absent | 4766 | 28.7 s |

    A 1.3% difference, which is noise. `Llama-3.2-1B-Instruct-4bit` writes to the hard stop under EVERY condition tried: 4829 and 4766 estimated tokens against a ceiling of 4249 real tokens, and 304 estimated against a ceiling of 281 at the suite's own headroom. It never stops on its own, so it cannot show a change in when a model stops. This is exactly the "informative but not conclusive" case the card names, and on its own it would NOT have cleared the directive.

    ## The 30B: the regression, reproduced in one fold

    Same fixture, same 4249-token ceiling, same greedy decoding, one generation each.

    | directive | answer | generation |
    |---|---|---|
    | absent | **839 estimated tokens** (3356 bytes) | **205.3 s** |
    | present | **0 characters — `SummarizationError.emptySummary`** | **283.6 s** |

    Two findings, and the second is the one that matters.

    **The directive makes the call 38% slower.** 283.6 s against 205.3 s, +78.3 s on one call, on an idle box with the model resident (load 3.5 s both times).

    **The directive makes the call produce NOTHING.** With the directive the model spent the whole 4249-token ceiling and generation stopped before it ever left the `<think>` block. `summarizeOnce`'s empty-summary guard caught it and threw. That is `^bgxtdk3`'s defect exactly — the empty summary that guard exists for — re-created by the directive, on the model the gated tier runs.

    ## What this explains

    `^azd033m`'s trail is now fully accounted for. Seven folds started, zero returned, in about 1796 s. A fold that hits the ceiling costs 283.6 s alone; `^9cw5g6n` records that the seven samples run CONCURRENTLY on one GPU, so seven such folds serialize into roughly 1985 s of GPU time. That is over the 1800-second limit, and it needs no unmeasured extra: the two numbers above are enough on their own. The card asked me not to assume the slowdown was large, and it is not — 38% per call is modest. Seven of them sharing one GPU is what crosses the limit.

    ## What is refuted

    The card's proposed mechanism was that the directive pushes the model's OUTPUT to the ceiling. It does not. The output goes to ZERO. The ceiling is spent on reasoning about the constraint — "write at most 512 characters", "a summary that is not clearly shorter is thrown away", "compress hard" — which reads as an optimisation problem, and the model optimises until the hard stop. The direction of the cost is right; the mechanism is reasoning, not summary text.

    ## What the control run also says, and it is not about the directive

    Without the directive the 30B wrote 839 estimated tokens against the 600-token span it was replacing — 1.40x — so `Compactor` discarded the fold, exactly as `^fm5ddk9` measured for all 7 gated seeds. **Reverting the directive alone restores a fold that gets thrown away.** That is the defect `^fm5ddk9` opened and it stays open under a bare revert.
  timestamp: 2026-08-18T13:40:54.454499+00:00
- actor: claude-code
  id: 01m0am31ytscwvb4fy8wc707z7
  text: |-
    Fixed, and re-measured against the model the regression was measured on.

    ## What I chose, and why

    **Both** of the card's first two options: revert `c26fbbe`'s directive, AND make the bound real in code. The measurement says neither alone is enough.

    **Revert the directive.** It was never verified to work, and against `Muse-Glimmer-30B-4bit` it does not merely cost — it spends the whole 4249-token ceiling inside the `<think>` block and answers with NOTHING, which is `^bgxtdk3`'s empty-summary defect. A length stated as a requirement reads as an optimisation problem, and a reasoning model optimises to the hard stop. There is no wording fix worth trying here (the card's third option): the failure is not that the words were too strong, it is that a per-call arithmetic bound is not a thing to ask a decoder for. The prompt now states no length at all, and a test pins the whole assembled prompt so a directive cannot come back unnoticed.

    **Cut in code.** A bare revert restores a fold that gets THROWN AWAY: the control run measured the 30B answering 839 estimated tokens against the 600-token span it was replacing, so `Compactor` discards it, exactly as it discarded 7 of 7 gated seeds in `^fm5ddk9`. `Summarization.cut(_:toCharacters:)` takes every answer down to the allowance its own call earned, in the UTF-8 content bytes the did-not-shrink guard itself measures, so "a fold's summary occupies at most its allowance" is now a property of one file rather than a hope about a generation.

    The cut falls on a boundary rather than on the byte the budget runs out on, with three fallbacks in order: the last sentence terminator or line end inside the budget; failing that the last word boundary; failing that the budget itself. A terminator counts only at the end of the text or before whitespace, which keeps the cut off the period inside `.env.example`, `3.5`, `v1.2`.

    ## The three constraints from `^bgxtdk3`, each held

    - **A reasoning model still gets its `<think>` room.** `outputTokenCeiling(forSummaryAllowance:)` is untouched — still `allowance + reasoningTokenHeadroom`, still 4224 on the gated path. The cut reads the ANSWER after the call returns and takes nothing off the generation.
    - **An empty summary is still refused.** `SummarizationError.emptySummary` is byte-identical and still runs on the model's own answer BEFORE the cut, so a fold that produced nothing is reported as such rather than cut to nothing. The cut's last fallback is the budget itself, and it hands `summary` back untouched rather than return something empty — one ungated test drives an answer with no boundary in it at all.
    - **`Compactor`'s did-not-shrink guard is untouched.** Not one line of `Compactor` changed. It is still the backstop, and it still has a reachable job: `minimumSummaryTokens` floors every allowance at 128, so a span SMALLER than that floor still buys a summary larger than itself. `foldThatDoesNotShrinkTheTranscriptIsNotApplied` now folds a fixture of that shape, and asserts the same five things it always did.

    ## Re-measured — the number moved

    **The 1B smoke test, its committed configuration, before and after:**

    | | answer | stored summary | transcript |
    |---|---|---|---|
    | before | 304 estimated tokens | 304 (the answer, whole) | 670 -> 374 |
    | after | 332 estimated tokens | **136** | 670 -> **206** |

    The fold is now 2.3x better on the same fixture, and the difference is entirely the cut.

    **The 30B, one fold, production headroom (ceiling 4249), greedy — the same experiment that produced the regression:**

    | | answer | fold | generation |
    |---|---|---|---|
    | directive, as shipped | 0 characters (`emptySummary`) | threw | 283.6 s |
    | no directive, no cut (pre-`c26fbbe`) | 839 est. tokens | DISCARDED, 839 > 600 | 205.3 s |
    | **no directive + cut (this fix)** | 824 est. tokens | **APPLIED, 670 -> 206** | 221.4 s |

    That third row is the first time in this thread of cards that a fold against the production model has been APPLIED rather than discarded or thrown. `stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`.

    The 221.4 s against the control's 205.3 s is one greedy run each and I do not claim the 8% as a real difference; what the fix demonstrably removes is the directive's 283.6 s.

    ## The ungated cover

    Eight new tests in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`, every one RED first against the real production path:

    - `theAssembledPromptAsksTheModelForNoLength` — the assembled prompt is the caller's instructions, the separator, and the content, and nothing else. This is the regression lock: any directive re-inserted anywhere fails it.
    - `aSummaryOverItsAllowanceIsCutToIt` — over-long answer, stored summary within the allowance, and a prefix of what was answered.
    - `theCutFallsOnASentenceBoundary`
    - `aSummaryInsideItsAllowanceIsStoredUnchanged` — the cut is a bound, not a rewrite.
    - `aSummaryWithNoSentenceBoundaryIsCutAtAWordBoundary` — whole words, never a split one.
    - `theCutNeverStoresAnEmptySummary` — 900 characters with no whitespace and no terminator still store text.
    - `eachCallOfAChunkedFoldIsCutToItsOwnAllowance` — read through the reduce round's own content, which is what the map calls really stored.
    - `aFoldWhoseSummaryOverranItsAllowanceIsStillApplied` — the `Compactor`-level property, and the direct answer to `^fm5ddk9`.

    The four tests that asserted the directive's text are gone, because the thing they asserted is gone.

    ## Two existing tests the change moved, and why

    Neither is a weakened assertion; each is the same property exercised where it is still reachable.

    - `foldThatDoesNotShrinkTheTranscriptIsNotApplied` folded a fixture whose summarizer answered a summary bigger than the whole transcript. The cut makes that unreachable through the stage, so the test now folds a SMALL fixture where the allowance floor exceeds the span. Same five assertions, and a sanity check that states the span really is under the floor.
    - `reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk` needed `summaryTokenRatio: 0.6`. With every chunk summary now cut to `ratio * maxChunkTokens`, `chunkStrings` can pair two of them under `maxChunkTokens` for any ratio at or below one half, so at the default 0.25 a fold cannot reach the no-progress fallback through a chunk that size. The branch is NOT dead: `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible` still reaches it through a chunk smaller than `minimumSummaryTokens`, where the allowance floor exceeds the chunk ceiling. The comment on the ratio states both halves.
    - `AutoCompactionTests.proactiveFoldFallsBackToOwnModelWhenFlashFails` asserted `result.summary == cannedText`. The canned answer runs past its allowance, so the stored summary is now a prefix of it. The assertion is a non-empty prefix ending on a canned sentence — still distinguishes the own-model tier from flash, which is the only thing that test is about.

    ## Documentation the change falsified, corrected rather than left standing

    `CompactionSmokeIntegrationTests` claimed the assembled prompt carries a length directive, and tabulated the 304/374 fold numbers. Both now state the measured 332/136/206 and say what moved them.

    ## What I could NOT correct here, and the card that carries it

    `RealisticSummaryLengthSummarizer` and `CompactionEvalSeedSizingTests.worstCaseSummaryEstimatedTokens` both still describe the bound as something a well-behaved model honours rather than something the code applies. They live in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`, which was already dirty in the working tree from `^w1cz46m`'s session, and this card was told to leave it alone. Filed as `^hx1smew`. Neither breaks a test — the cut only ever makes a summary smaller, so the hermetic gate still passes.

    ## What is still not claimed

    The gated tier was NOT run. `^fm5ddk9`'s AC1 and AC2, and `^bgxtdk3`'s criterion 5, still need a gated run to close. What this card can say is narrower and measured: the mechanism they were blocked on — the fold being discarded, and then the summarizer answering nothing at all — is closed against the same model, on one fold, in 225 seconds.
  timestamp: 2026-08-18T14:23:31.290523+00:00
- actor: claude-code
  id: 01m0am3kacf2vr052fxd3kw8cw
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift. `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` is dirty from `^w1cz46m`'s session and was NOT touched.
    - the two measured numbers the card asked for, generated summary length with the directive and without it, all else equal, at production headroom (ceiling 4249, greedy, one fold): **WITH the directive the model answered 0 characters** and threw `SummarizationError.emptySummary` after 283.6 s; **WITHOUT it the model answered 839 estimated tokens** after 205.3 s. Both against `mlx-community/Muse-Glimmer-30B-4bit`.
    - controls the card named: headroom was raised from the smoke suite's 128 to production's 4096 (context 4096 -> 8192 so the ceiling fits), so the ceiling was 4249 against the gated tier's 4224. The 1B was measured first and did NOT reproduce — 4829 with the directive against 4766 without, both at the hard stop, because `Llama-3.2-1B-Instruct-4bit` never stops on its own under any condition tried. On the 1B alone the directive would have looked innocent.
    - fix: revert the directive AND cut the answer to its allowance in code (`Summarization.cut(_:toCharacters:)`), because the control run shows a bare revert restores a fold `Compactor` discards. `Compactor`'s did-not-shrink guard is untouched; the reasoning ceiling is untouched; the empty-summary refusal still reads the model's own answer before the cut.
    - re-measurement: the 1B smoke test at its committed configuration moved from `summaryTokens=304 tokensAfter=374` to `summaryTokens=136 tokensAfter=206`. The 30B one-fold experiment with the fix APPLIED the fold — `stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`, 670 -> 206 — for the first time in this thread of cards.
    - verification: `swift build` complete; `swift build --build-tests -Xswiftc -warnings-as-errors` complete, zero warnings; `swift test` — 982 + 28 + 58 = 1068 tests, 0 failures, 1 pre-existing known issue (`BoundedWait.swift` `withKnownIssue`). FoundationModelsRouterTests 978 -> 982.
    - not spent: `FM_ROUTER_INTEGRATION_TESTS` and `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` were never set. Only `FM_ROUTER_COMPACTION_SMOKE=1`.
    - new cards: `^hx1smew` — two eval-target doc comments still describe the bound as a hope rather than a cut; they live in the file this card was told to leave alone.
    - next: `/review ^azd033m`. The gated tier still has to run before `^fm5ddk9` AC1/AC2 and `^bgxtdk3` criterion 5 can close.
  timestamp: 2026-08-18T14:23:49.068825+00:00
position_column: doing
position_ordinal: '8280'
title: The c26fbbe length directive stalls the compaction summarizer — 7 of 7 folds unfinished in 1796 s, where 7 folds plus 7 answers took 1686 s before it
---
Measured by the instrumented gated run of 2026-08-18, the one run `^h2xxsse` sanctioned. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-run-3.log`.

## The measurement

`FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` at HEAD `523689b`, `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` NOT set. The whole progress trail the run emitted:

```
[compaction-eval] model load started ref=mlx-community/Muse-Glimmer-30B-4bit
[compaction-eval] model load returned ref=mlx-community/Muse-Glimmer-30B-4bit took=3.6s
[compaction-eval] sample=1/7 seed=budget-cap-tool-and-owner fold started elapsed=0.0s
[compaction-eval] sample=2/7 seed=db-port fold started elapsed=0.0s
[compaction-eval] sample=3/7 seed=encryption-algorithm fold started elapsed=0.0s
[compaction-eval] sample=4/7 seed=env-file fold started elapsed=0.0s
[compaction-eval] sample=5/7 seed=license-key-and-region fold started elapsed=0.0s
[compaction-eval] sample=6/7 seed=three-facts-long-project-brief fold started elapsed=0.0s
[compaction-eval] sample=7/7 seed=three-facts-support-escalation fold started elapsed=0.0s
```

Then the 1800-second limit, `0 of 7 seeds measured`, and a failure at 1800.260 s.

**Seven `fold started` lines. Zero `fold returned` lines. Zero `answer started` lines.** Not one of the seven summarizer calls completed in about 1796 seconds of model time.

## What this refutes

`^h2xxsse` listed three explanations. Two are now dead, by measurement rather than by argument:

- **The model load did not stall.** It took **3.6 seconds**. It is not a meaningful part of the tier's cost at all.
- **No sample hung in its answering turn.** No sample ever REACHED its answering turn. The answering turn ran zero times.

## What is left, and why it points at the directive

Every one of the seven samples was inside its summarizer call when the limit fired. The summarizer call is the only thing `c26fbbe` changed, and the change is bounded:

- `maxTokens` is unchanged. `outputTokenCeiling(forSummaryAllowance:)` returns `allowance + reasoningTokenHeadroom`, identical arithmetic to the old `summaryTokenAllowance(condensing: content) + reasoningTokenHeadroom`. The ceiling is still 4224.
- The number of summarizer calls is unchanged, and chunking is unchanged.
- The only difference is the directive paragraph inserted between the caller's instructions and the content — about 330 characters of extra INPUT, which is prefill measured in milliseconds.

So the extra time is spent on what the model GENERATES in response to the directive, and nothing else in the diff can produce it.

## The size of the regression, stated honestly

| run | what completed | wall clock |
|---|---|---|
| 2026-08-17 21:42, before `c26fbbe` | 7 folds AND 7 answering turns | 1685.9 s |
| 2026-08-18, after `c26fbbe` | 0 folds | > 1796 s, cut off |

The fold step ALONE now costs more than the fold step and the answering step together did before.

**No upper bound can be given from this run, and that must not be papered over.** Not one fold finished, so the trail gives a floor and no ceiling: the true per-fold cost is somewhere above "more than the whole previous run", and could be far above it. A started/returned pair bounds a step only when the step returns.

## What the next run needs

Getting the magnitude needs either a bound the run can actually reach, or a finer signal:

- Measure the directive's effect on GENERATED LENGTH directly, on one seed, rather than on the whole tier. The question is how many tokens the model emits for one summarizer call with the directive versus without it, and one seed answers it.
- Or emit an in-flight heartbeat from the summarizer so a call that never returns still states how long it has been running and how much it has produced.

Prefer the first: it is one seed, it is cheap, and it measures the mechanism rather than the symptom.

## What must NOT be done

Do not raise `compactionEvalSubsetTimeLimitMinutes` to make the run fit. The limit is measured and its basis is documented, and a directive that makes one summarizer call outlast a whole previous run is a product defect, not a limit that is too small.

## Related

- `^h2xxsse` — the instrumentation that produced this measurement.
- `^fm5ddk9` — the card that added the directive. Its two open criteria stay open; this run measured no summary at all.
- `^9cw5g6n` — the concurrency finding from the same trail, which changes how every per-sample figure on this tier must be read.
- `^bgxtdk3` — its acceptance criterion 5 stays open for the same reason.

#compaction #eval #real-model #defect
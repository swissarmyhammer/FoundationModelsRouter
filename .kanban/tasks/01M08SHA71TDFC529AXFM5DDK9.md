---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m08tghj2kp28h1v4yhrmvah0
  text: |-
    Picked up. Research done before any edit — what the code shows.

    ## The guard, and the two currencies it spans

    `Compactor.compact` applies a fold only when `estimatedTokenCount(of: folded.transcript) < tokensBefore`. `estimatedTokenCount` is UTF-8 CONTENT bytes over `Compactor.charsPerTokenEstimate` (4.0), and `^vjf3mdm` already established that a router manifest segment counts ZERO content bytes — so the synthesized summary entry costs exactly its summary TEXT. The guard reduces to: old-span content bytes > summary text bytes.

    `Summarization.outputTokenCeiling(condensing:)` = `summaryTokenAllowance(condensing:)` + `reasoningTokenHeadroom` (4096). The allowance is `max(128, ceil(contentEstTokens * 0.25))` clamped to `maximumSummaryTokens` (500). Every eval seed's span is small enough to take the FLOOR, 128. So every gated summarizer call was made with `maxTokens = 128 + 4096 = 4224`, and NOTHING in the path bounds the answer at 128 — the ceiling is a hard stop on the whole generation. That is the hypothesis the card states, and it is consistent with the code as written.

    ## Why the hermetic gate cannot see it

    `RealisticSummaryLengthSummarizer` answers at exactly `maxTokens - reasoningTokenHeadroom` real tokens — the allowance alone, about 616 bytes at the measured 4.81 bytes/token. `CompactionEvalSeedSizingTests` holds every seed's span at >= 1.5x that (measured 319-444 estimated tokens against a 154-token worst case, tightest seed 2.07). So the hermetic model assumes the real model stops at its allowance. If the real model instead writes toward the 4224-token ceiling, the model and the measurement disagree exactly where the run says they do.

    ## What the run cannot say today, and why

    `CompactionResult.summary` is `nil` on the shortfall exit, so `CompactionEvalSampleDiagnostic.summary` is `nil` and the table prints `<discarded>`. The size of the summary that lost is never recorded anywhere: `CompactionResult` reports `tokensAfter == tokensBefore` on that path by design (it names the size of what is RETURNED, which is the original transcript), and the discarded fold's own `tokensAfter` is thrown away inside `compact`.

    ## Plan for step 1, decided

    Capture the evidence entirely in the Evals target — no production change, no widening of `CompactionResult` for a diagnostic:

    - `BlankSlateSummarizer` (in `CompactionEvalRealSubjectRunner.swift`) already counts its calls. It will record each call's `maxTokens` and its answer instead of only a count; `summarizerCallCount` becomes derived from that list, so the two cannot drift.
    - The report joins each diagnostic to its seed already, and a seed carries its own `entries`, so the foldable span is derivable at report time — no new runner plumbing for it. `foldableSpanEstimatedTokens` moves out of `CompactionEvalSeedSizingTests`' private helper onto `CompactionEvalSeed` itself so the sizing gate and the table read ONE implementation.
    - The stanza gains a line, only for a discarded fold, stating the summary's bytes, its estimated tokens, the span's estimated tokens, and the ceiling the call was given — plus a bounded prefix of the text.
  timestamp: 2026-08-17T21:37:15.842303+00:00
- actor: claude-code
  id: 01m08tv1khc82x3apfws095229
  text: |-
    Step 1 landed and is green. The evidence is now visible, and the ungated suite covers it.

    ## What was added

    `CompactionEvalSummarizerCall` (`Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift`) records what one summarizer call ASKED FOR and what it GOT — `maxTokens` beside `answer`. `BlankSlateSummarizer` now appends one of these per completed call instead of bumping a counter, and `CompactionEvalSampleDiagnostic.summarizerCallCount` is derived from that list, so the count and the text cannot drift apart.

    `CompactionEvalSampleDiagnostic.discardedSummary` reads the LAST call's answer when `foldDiscarded` — the last call is the summary a fold stores, whether the span took one call or a map-reduce tree.

    `CompactionEvalFactRetentionFinding.foldableSpanEstimatedTokens` comes from the seed the sample joined back to. The partitioning moved out of `CompactionEvalSeedSizingTests`' private helper onto `CompactionEvalSeed.foldableSpanEstimatedTokens`, so the sizing gate and the table read one implementation of the split.

    The stanza gains two lines, and only for a discarded fold:

    ```
      discarded=<bytes> bytes summaryTokens=<n> spanTokens=<n> ceiling=<n>
      discardedText=<the text, cut at 1000 characters with a <cut> marker>
    ```

    Those are the three numbers `Compactor.compact`'s did-not-shrink guard turns on, printed beside each other.

    ## The ungated cover

    `renderedTableStatesTheDiscardedSummarysSize` reads a REAL dataset seed rather than the empty probe seeds the other classification tests use, so the span it asserts is a span a fold really replaces. `renderedTableStillNamesAFoldThatNeverRan` gained the other half: a sample with no summarizer call prints no `discarded=` line at all.

    RED was real and mechanical: `swift build --build-tests` rejected the tests with `cannot find type 'CompactionEvalSummarizerCall' in scope` before the type existed.

    ## Verification

    `swift build --build-tests -Xswiftc -warnings-as-errors` — build complete, zero warnings. `swift test` — 974 + 27 + 46 tests, zero failures, 1 pre-existing known issue. The Evals target went 45 -> 46 tests.

    Now running the ONE sanctioned gated run: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`.
  timestamp: 2026-08-17T21:42:59.953704+00:00
- actor: claude-code
  id: 01m08xfys1nv24twtsvg41v913
  text: |-
    Step 2 done — the ONE sanctioned gated run — and step 3 decided from it. Here are the numbers.

    ## The run

    `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`, 1685.9 s wall clock (28.1 minutes), 7 of 7 seeds measured, `unreached: <none>`. Run ONCE, as instructed. `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` was NOT set.

    It exited 1. Mean `FactRetention` was 6/7 = 0.857, under the 0.9 floor. That is a separate matter and is filed as `^xscp198` — see below.

    ## The hypothesis was RIGHT in direction and WRONG in mechanism

    `^bgxtdk3`'s recorded risk was "a summarizer that emits no reasoning may spend the headroom on summary text — worst-case summary text goes from 500 tokens to 4596". The measurement:

    | seed | summary bytes | summary est. tokens | span est. tokens | ratio | ceiling |
    |---|---|---|---|---|---|
    | db-port | 1800 | 450 | 345 | 1.30 | 4224 |
    | env-file | 1953 | 489 | 359 | 1.36 | 4224 |
    | three-facts-support-escalation | 2492 | 623 | 444 | 1.40 | 4224 |
    | budget-cap-tool-and-owner | 2634 | 659 | 406 | 1.62 | 4224 |
    | three-facts-long-project-brief | 3357 | 840 | 438 | 1.92 | 4224 |
    | license-key-and-region | 3031 | 758 | 371 | 2.04 | 4224 |
    | encryption-algorithm | 2959 | 740 | 358 | 2.07 | 4224 |

    Every summary is 1.30x to 2.07x the span it replaces, so the guard discarded every one and was right to. In real tokens (at the dataset's measured 4.81 bytes/token) the summaries are 374 to 698 tokens.

    So the model is **NOT** spending the headroom. It uses 9% to 17% of its 4224-token ceiling and stops on its own. What it overruns is the **ALLOWANCE**: 374 to 698 real tokens against 128, which is 2.9x to 5.5x. This is a PRODUCT defect, and the cause is one sentence — nothing in the assembled prompt ever named the allowance. `maxTokens` was the only length signal that reached the model, and it said 4224.

    ## The summaries are good summaries. They are transcriptions.

    `env-file`'s discarded summary, whose stanza the new diagnostic printed in full:

    ```
    1. Intent
    - Provide background about service configuration loading and request acknowledgment.
    - Inform that the API key for this project lives in `.env.example`, never in a real `.env` file.

    2. Stated facts
    - the service reads its whole configuration from environment variables at startup
    - the deployment scripts assemble those variables from three layers
    - the base defaults are checked into the repository
    ...
    ```

    The planted fact IS in it, verbatim. The fold did not lose anything — it just wrote one bullet per stated sentence, which on a fact-dense span is a near-transcription rather than a compaction. `CompactionPrompt.default` section 2 asks for "every concrete fact stated in the conversation, each with its value written out", and with no length bound stated beside it, exhaustiveness wins.

    ## The fix

    `Summarization.summarizeOnce` now assembles the caller's instructions, then a length directive, then the separator and the content. The directive names two numbers this call really has:

    ```
    Length limit: write at most 512 characters. The conversation below is 1620 characters, and this
    summary REPLACES it — a summary that is not clearly shorter than what it replaces saves nothing
    and is thrown away. Compress hard: keep every stated value word for word, and cut the prose
    around the values first.
    ```

    Four decisions behind it, each for a reason:

    1. **Characters, not tokens.** `Compactor.compact`'s guard measures UTF-8 content bytes over `Compactor.charsPerTokenEstimate`. Stating the bound in that unit means the number the model is given is the number its answer is judged by, with no currency conversion between them. The estimated-token/real-token mismatch that runs through this whole area simply does not apply to a character bound.
    2. **The span's size beside it.** A bound alone is a number with no scale, and the shrink requirement is what makes it worth honoring.
    3. **What to cut first.** The caller's instructions ask for every stated value; the directive says to keep the values and cut the prose around them. Without that, a model resolving the tension the wrong way drops the values — which is the `summaryLostFact` defect, and worse than a discarded fold.
    4. **On the stage, not in `CompactionPrompt.default`.** The numbers are per call, from `summaryTokenAllowance(condensing:)` over that call's own content, at every level of the map-reduce tree. A caller's own prompt is sent verbatim and cannot restate arithmetic it has no access to, so every prompt gets the bound and none has to know it exists.

    `outputTokenCeiling(condensing:)` became `outputTokenCeiling(forSummaryAllowance:)` so the allowance is computed once and both the ceiling and the directive read the same value.

    ## How this keeps `^bgxtdk3`

    Both of its properties are untouched, by construction:

    - **A reasoning model still gets its `<think>` room.** The ceiling is still `allowance + reasoningTokenHeadroom` — 4224 tokens, unchanged, and the measured 4096 headroom is untouched. The directive is text in the prompt; it takes nothing off the generation ceiling. A model that reasons for 3000 tokens and then writes 512 characters fits exactly as it did before.
    - **An empty summary is still refused.** `summarizeOnce`'s `SummarizationError.emptySummary` guard is byte-identical and still stands after every call, map and reduce alike.

    And `Compactor.compact`'s did-not-shrink guard is untouched, as the card requires. It stays the backstop: a model that ignores the directive costs a wasted call, never a worse transcript.

    ## The ungated cover, and the RED that proved it

    Four new tests in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`, all RED first against the real production path (`Expectation failed: assembled.contains("at most 512 characters")` and `assembled.contains("... characters")`):

    - `summarizerCallIsToldItsSummaryCharacterBound` — the bound is stated, and it equals `minimumSummaryTokens` at `charsPerTokenEstimate`.
    - `eachCallOfAChunkedFoldIsToldItsOwnCharacterBound` — 3 calls of a chunked fold, each told its OWN chunk's bound, so a directive computed once over the whole span fails.
    - `summarizerCallIsToldTheSizeOfTheSpanItMustBeat` — the span's own size is stated.
    - `aCustomPromptStillCarriesTheLengthBound` — a caller-supplied prompt gets the bound too.

    ## Two stale claims corrected rather than left standing

    The run refuted them, and a doc a future agent trusts is worse than no doc:

    - `RealisticSummaryLengthSummarizer` said an answer filling the allowance "is the largest a real summarizer writes". Measured false by 2.9x to 5.5x. It now records the measurement, states that the claim holds for a summarizer TOLD its allowance, and notes that it deliberately answers about 20% over the stated character bound (allowance in real tokens at 4.81 bytes/token is 616 bytes against a stated 512).
    - `CompactionEvalSeedSizingTests.worstCaseSummaryEstimatedTokens` said "the largest summary a real summarizer writes for a span this size". Same correction: it is the largest one honoring its stated allowance writes, and the run measured 450-840 against its 154.

    ## What is NOT claimed

    **AC1 and AC2 stay open.** Whether the real model honors the directive is a model behaviour, and only a gated run can answer it. Per the card's instruction I stopped rather than spend a second gated run. AC3 is met and checked: a discarded fold now states the size it missed by.

    The change is safe to leave un-gated-verified: if the model ignores the directive, the folds are discarded exactly as they are today — the guard is unchanged, the empty-summary refusal is unchanged, and the reasoning room is unchanged. Nothing regresses; the open question is only whether it improves.

    ## New card filed

    `^xscp198` — the 7-seed subset can only pass at 7 of 7, because 6/7 = 0.857 is under the 0.9 floor. My run got 6/7 and failed where `^fz49qds`'s run of the same fold behaviour got 7/7 and passed; the one seed that moved (`env-file`) answered "I don't have access to that project's files or secrets" this time. `^fz49qds` recorded that this runner leaves the provider's sampling in place; what it did not record is that a 7-sample tier turns any single sampled refusal into a suite failure. That is independent of this card and will bite every future run.

    ## Full log

    The whole gated run, table included, is at `scratchpad/gated-run.log` (235 lines).
  timestamp: 2026-08-17T22:29:22.337341+00:00
- actor: claude-code
  id: 01m08xgdfzpc03xbanyjt67gmv
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/CompactionEvalSeed.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift
    - measurement: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` — run ONCE, 1685.9 s, 7 of 7 seeds, exit 1 (mean 0.857 < 0.9). Discarded summaries 450-840 estimated tokens against spans of 345-444, ratio 1.30x to 2.07x, every call at ceiling 4224 against an allowance of 128.
    - verification: `swift build --build-tests -Xswiftc -warnings-as-errors` — build complete, zero warnings. `swift test` — 978 + 27 + 46 = 1051 tests, zero failures, 1 pre-existing known issue. FoundationModelsRouterTests 974 -> 978 (+4), Evals 45 -> 46 (+1).
    - acceptance: AC3 met and checked. AC1 and AC2 NOT claimed — both need a second gated run, which the card forbids spending.
    - new cards: `^xscp198` — the 7-seed subset can only pass FactRetention at 7 of 7
    - next: a person decides whether to spend a second gated run to verify the directive against the real model, then `/review`
  timestamp: 2026-08-17T22:29:37.407590+00:00
- actor: claude-code
  id: 01m08xneyvywgvn8619rgdspea
  text: |-
    ### test — green
    - evidence: `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift test` (ungated, no `FM_ROUTER_INTEGRATION_TESTS`/`FM_ROUTER_COMPACTION_EVAL_FULL_DATASET`) — 3 targets, 978+27+46 = 1051 tests, 0 failed, 0 new warnings, 1 known issue (pre-existing `BoundedWait.swift` `withKnownIssue`, expected)
    - next: none
  timestamp: 2026-08-17T22:32:22.747315+00:00
position_column: doing
position_ordinal: '80'
title: The real model still discards every compaction eval fold — 7 of 7 gated seeds report factInSummary=false with an empty stage list
---
Found by the sanctioned gated measurement run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` on 2026-08-17, while measuring the time limit for `^fz49qds`.

## What happens

The run passed. `factRetention` was 1.0 over all seven subset seeds, well over the 0.9 bar. Every one of the seven reports this shape:

```
- seed=db-port class=retained factInSummary=false folded=false summarizerCalls=1 stages=
  answer=6543.
  summary=<discarded>
```

- 7 of 7 seeds: `summarizerCalls=1`, an EMPTY stage list, `summary=<discarded>`.
- 7 of 7 seeds: `factInSummary=false`.
- 7 of 7 seeds: `class=retained`.

`summarizerCalls=1` with no stage applied is `Compactor.compact`'s shortfall exit. The summarizer ran, the summarizer answered, and the fold was then thrown away because `tokensAfter >= tokensBefore`. The transcript the resumed session was handed is the ORIGINAL one.

## Why the pass is a pass for the wrong reason

`class=retained` says the answer carried the key phrase. It did — because the planted fact was still sitting in the transcript verbatim. No summary was involved in any of the seven answers. A metric of 1.0 over seven discarded folds measures the model's ability to read a transcript it was given whole, and says nothing at all about compaction.

This is the same condition `^vjf3mdm` closed, reappearing against the real model. That card's third acceptance criterion — "The gated eval reports `factInSummary=true` on the large majority of seeds" — is still open, and this is the measurement that shows it.

## Why the hermetic gate did not catch it

`CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` folds every seed against `RealisticSummaryLengthSummarizer`, and it passes: every seed's `stagesApplied` is `[ToolOutputElision, TurnTruncation, Summarization]`. So the hermetic gate says the fold survives, and the real model says it does not. One of the two is wrong about what a real summary costs.

`RealisticSummaryLengthSummarizer` answers with exactly `maxTokens - reasoningTokenHeadroom` tokens' worth of bytes, at `compactionEvalMeasuredBytesPerToken`. The real model's summary is evidently larger than that once it is a stored entry, or the entry's own metadata costs more than the estimate allows for. `CompactionEvalSeedSizingTests` states the arithmetic the gate rests on, and one of its two inputs — the worst-case summary size, or the bytes-per-token rate — does not match what the run really produced.

## What to find out first

The run prints `<discarded>` and nothing else about the summary that was discarded, because `CompactionResult.summary` is `nil` on the shortfall path. So the run cannot say HOW MUCH too large the fold was. That number is the first thing to get: `Compactor.compact`'s `tokensBefore` and `tokensAfter` on the discarded path, printed per sample, would say whether the miss is a few percent or a multiple.

## The measurement, 2026-08-17 21:42

The table now states it. 7 of 7 seeds, one summarizer call each, every call at `ceiling=4224`:

| seed | summary bytes | summary est. tokens | span est. tokens | ratio |
|---|---|---|---|---|
| db-port | 1800 | 450 | 345 | 1.30 |
| env-file | 1953 | 489 | 359 | 1.36 |
| three-facts-support-escalation | 2492 | 623 | 444 | 1.40 |
| budget-cap-tool-and-owner | 2634 | 659 | 406 | 1.62 |
| three-facts-long-project-brief | 3357 | 840 | 438 | 1.92 |
| license-key-and-region | 3031 | 758 | 371 | 2.04 |
| encryption-algorithm | 2959 | 740 | 358 | 2.07 |

The summary is 1.30x to 2.07x the span it was meant to replace, so `Compactor.compact` was right to discard every one. In real tokens the summaries run 374 to 698 — 2.9x to 5.5x the 128-token allowance, and 9% to 17% of the 4224-token ceiling.

## The hypothesis, corrected

`^bgxtdk3`'s recorded risk was that a model emitting no reasoning "may spend the headroom on summary text — worst-case summary text goes from 500 tokens to 4596". The direction is right and the mechanism is not. This model DOES reason, and it stops far short of the ceiling. It overruns its ALLOWANCE, not its ceiling, because nothing in the assembled prompt ever named the allowance: `maxTokens` was the only length signal reaching the model and it said 4224.

## Acceptance Criteria

- [ ] The gated eval reports `factInSummary=true` on the large majority of seeds, so `factRetention` measures a summary rather than the original turns
- [ ] The hermetic gate agrees with the real model: a seed the hermetic suite says folds is a seed the gated run folds
- [x] A discarded fold states the size it missed by, not only that it was discarded
#compaction #defect #real-model #eval
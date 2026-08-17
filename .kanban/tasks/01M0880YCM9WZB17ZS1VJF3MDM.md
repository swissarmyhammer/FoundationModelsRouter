---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m08bhja8xsh5qvdgydr3aeqf
  text: |-
    Research done. The arithmetic that decides whether a fold survives `Compactor.compact`'s did-not-shrink guard:

    - `SegmentPayload.contentByteCount` counts a router manifest segment as ZERO, so the summary entry costs exactly its summary TEXT bytes. The `CompactionSegment` metadata (liveWindowEntryIds, foldedEntryIds, counts, stage names) is free. The card's description of the fold trading a span "for an entry whose own metadata costs bytes" is not what the code measures — the metadata is not measured at all.
    - So the guard reduces to: old-span content bytes > summary text bytes.
    - `Summarization.summaryTokenAllowance(condensing:)` = `max(128, ceil(contentEstTokens * 0.25))` clamped to 500. Every eval seed is small, so every one of them gets the FLOOR: 128 tokens.
    - 128 real tokens of this model's English prose is about 128 * 4.9 = 627 bytes. Every seed's old span today is one fact turn plus its acknowledgement — roughly 150 to 400 bytes. So the worst-case real summary is 1.5x to 4x the span it replaces, and the fold is discarded. `codename` folded only because the real model happened to write about 80 bytes that run.
    - Above about 2000 bytes of old span the floor stops binding and the 0.25 ratio takes over; a summary is then about 0.31 of the span in estimated tokens, so the fold always shrinks. The whole problem lives in the floor regime.

    Fix follows the card's decision (option 1): grow each fixture's foldable head with one authored background paragraph on that fixture's own subject, sized so the old span clears the 627-byte worst case with margin. Facts stay short and crisp in their own turns so the summary still has a chance to carry the key phrase.

    Sizing method reused from `^wnj3ka3` / commit f92e78e: state the bound in the tokens a live run really counts, not in the bytes/4.0 estimate, and pin the measured bytes-per-token as a documented constant in an UNGATED test.
  timestamp: 2026-08-17T17:15:40.744358+00:00
- actor: claude-code
  id: 01m08cp5wh9d6933n4kq2zry08
  text: |-
    Implementation landed. What was done, and the measurements behind it.

    ## Acceptance criterion 1 — every seed's fold is APPLIED

    The seeds grew, exactly as the card decided (option 1). `CompactionEvalFixtureSpec` gains a `context` field: one authored background paragraph per fixture, on that fixture's own subject, stated as the FIRST turn of the foldable head so the planted facts stay short, crisp, and last in the folded span. `CompactionEvalSeed.build(from:)` prepends it with its own acknowledgement, `compactionEvalContextAcknowledgement`, which no other pool repeats.

    The hermetic gate sits beside `defaultBudgetForcesSummarizationStage` as the card asked:
    `CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` holds every seed to `stagesApplied == [ToolOutputElision, TurnTruncation, Summarization]` against `RealisticSummaryLengthSummarizer`, whose answer is the length the summary allowance really buys — `maxTokens - reasoningTokenHeadroom` real tokens, rendered at the measured bytes-per-token. Both fold tests now go through one shared helper, `expectEverySeedFoldsThroughSummarization(with:answering:)`.

    **Proof the gate can fail.** The context turn was temporarily dropped from `build(from:)`, restoring the pre-change seeds:

    - `everySeedFoldSurvivesARealisticSummary` — RED on all 24 seeds.
    - `everySeedsFoldableSpanOutweighsARealSummary` — RED on all 24 seeds.
    - `defaultBudgetForcesSummarizationStage` — still GREEN.

    That last line is the blind spot this card exists to close, reproduced on demand: the stub suite reported the pipeline reaching `Summarization` on a dataset whose every fold the real model then had discarded.

    ## The sizing method (reused from `^wnj3ka3` / f92e78e)

    Measured against the real tokenizer, not the estimate. `AutoTokenizer.from(modelFolder:)` over the Muse Glimmer snapshot in the local Hub cache, run against this dataset's whole prose corpus — every context paragraph and fact, every acknowledgement, every filler prompt and reply:

    ```
    corpusBytes=31541 corpusTokens=6564 bytesPerToken=4.8051
    ```

    Pinned as `compactionEvalMeasuredBytesPerToken = 4.81`, rounded UP so no summary size it feeds is under-stated.

    `CompactionEvalSeedSizingTests` (ungated) states both bounds in that currency:

    - Lower: every seed's foldable span must be at least `summaryShrinkClearance` (1.5) times the largest real summary of it. The worst case is `Summarization.minimumSummaryTokens` (128) converted back at the measured rate — 154 estimated tokens. Measured spans run 319 to 444, so the tightest seed sits at 2.07.
    - Upper: every span stays under `Summarization.maxChunkTokens`, so a fold still makes exactly ONE summarizer call and cannot silently become a map-reduce tree.

    The doc records why the floor is the only branch that can fail: the ratio branch gives a summary of `0.25 * 4.81 / 4.0` of the span it condensed — under a third — so it shrinks the transcript by construction.

    A dataset guard came with it: `everySeedStatesItsKeyPhraseExactlyOnce` counts each seed's key phrase across its whole transcript, case-insensitively, and requires exactly one. Background prose that stated the key phrase would let a summary of the filler satisfy `FactRetention` without the planted fact surviving at all.

    ## Acceptance criterion 2 — a discarded fold is legible

    `CompactionEvalSampleDiagnostic.foldDiscarded` reads the pair only a discarded fold can produce: `summarizerCallCount > 0` with no `Summarization` in `stagesApplied`. The summarizer is called from `Summarization` and nowhere else, and an applied `Summarization` always names itself, so nothing else makes that pair.

    `CompactionEvalFactRetentionReport.discardedSummaryMarker` renders it as `summary=<discarded>`, beside the `<empty>` marker `^bgxtdk3` added and the `<none>` it already had. Two tests pin both sides: `renderedTableNamesADiscardedFold` and `renderedTableStillNamesAFoldThatNeverRan`.

    The classification stays `foldProducedNoSummary` — a discarded fold does leave the resumed session nothing to answer from, which is what that case means — and its doc now names the discarded path so a reader is not misled.

    ## Acceptance criterion 3 — NOT claimed

    The gated eval reporting `factInSummary=true` on the large majority of seeds is NOT met and was not attempted. It cannot be measured until `^fz49qds` settles the gated time limit: that suite currently stops at 9 of ~20 samples on its 1200 s limit. The gated suite was deliberately not run.

    ## Discovered along the way

    The card's stated mechanism was not quite what the code measures. `SegmentPayload.contentByteCount` counts a router manifest segment as ZERO, so a fold's `CompactionSegment` metadata — `liveWindowEntryIds`, `foldedEntryIds`, counts, stage names — costs nothing at all. The summary entry costs exactly its summary TEXT. So the guard reduces to "old-span content bytes > summary text bytes", and the whole defect lived in `minimumSummaryTokens`: a 128-token floor is about 615 bytes of this model's prose, against heads of 150 to 400 bytes.

    ## Effect on the gated eval runtime

    Whole seeds went from about 100-185 estimated tokens to 419-520. The generation ceilings did not move and the fold still makes one summarizer call, so the growth is prefill rather than generation, but `^fz49qds` must re-measure against the grown dataset rather than against its recorded 9-samples-in-1200-s figure. That is written on `^fz49qds`.

    ## Existing tests that changed

    - `defaultBudgetForcesSummarizationStage` — now calls the shared helper instead of its own loop, and reads the stage names from `ToolOutputElision.stageName` / `TurnTruncation.stageName` / `Summarization.stageName` instead of the same three string literals. Same values, same assertion, nothing weakened; its comment block is unchanged.
    - `assistantReplies(of:)` — its inline segment flattening moved into the shared `text(of:)` the new `transcriptText(of:)` also uses. Same result.

    Two stale doc comments were corrected rather than left lying: `compactionEvalDefaultBudget` said the seeds run "around 100-185 estimated tokens" and `CompactionEvalSeed`'s type doc did not name the background turn.

    The description's acceptance-criteria checkboxes are left untouched on purpose. `update task` is recorded as flattening a long description and zeroing its tags, and this description is long; the state is stated here instead.
  timestamp: 2026-08-17T17:35:40.433738+00:00
- actor: claude-code
  id: 01m08cpdfxns8smf0nc7preg9z
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift, CompactionEvalSeed.swift, CompactionEvaluationTests.swift, CompactionEvalFactRetentionReport.swift, CompactionEvaluation.swift. swift build clean; swift build --build-tests -Xswiftc -warnings-as-errors clean; swift test 973 + 27 + 33 tests, 0 failures, 1 pre-existing known issue. Evals target 27 -> 33 tests.
    - acceptance: AC1 met, AC2 met, AC3 NOT met and not claimed — it needs the gated run, which is blocked on `^fz49qds`.
    - next: /review
  timestamp: 2026-08-17T17:35:48.221436+00:00
- actor: claude-code
  id: 01m08ct2dtn2bp0h11v70yn9gp
  text: |-
    ### test — green
    - `swift build` — Build complete, exit 0
    - `swift build --build-tests -Xswiftc -warnings-as-errors` — Build complete, exit 0, zero warnings
    - `swift test` (ungated) — three test-run summaries, zero failures:
      - `Test run with 973 tests in 91 suites passed after 5.301 seconds with 1 known issue.` (the pre-existing `withKnownIssue`, expected)
      - `Test run with 27 tests in 11 suites passed after 0.001 seconds.`
      - `Test run with 33 tests in 6 suites passed after 0.027 seconds.`
    - 39 skipped items, all gated real-model integration suites (require `FM_ROUTER_INTEGRATION_TESTS=1`, not run per constraint; tracked separately under ^fz49qds)
    - next: gated real-model run still owed (blocked on ^fz49qds's 20-minute limit fix), otherwise clean
  timestamp: 2026-08-17T17:37:47.962124+00:00
- actor: claude-code
  id: 01m08cvztkkn83y2g95pj924ea
  text: |-
    ### commit — changed
    - evidence: 1397279 fix(evals): grow compaction eval seeds so real summaries actually shrink them (^vjf3mdm)
    - next: /review
  timestamp: 2026-08-17T17:38:50.835304+00:00
- actor: claude-code
  id: 01m08d6r75snxy70xargvq421s
  text: |-
    ### review — findings
    - evidence: 1 finding (1 confirmed, 1 refuted, 7 attempted) — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:341
    - scope: review sha HEAD~1..HEAD (checkpoint 1397279 only)
    - next: remove the `text(of:)` duplication cause across the file — call `Summarization.text` directly if it is visible to tests, or extract one shared utility. Acceptance criterion 3 (gated `factInSummary=true`) stays open until ^fz49qds settles the gated 20-minute limit.
  timestamp: 2026-08-17T17:44:43.493650+00:00
- actor: claude-code
  id: 01m08d7c2tjbktft9rnrknykj8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files in Tests/FoundationModelsRouterEvals/; 24 background paragraphs added, sized against the real tokenizer at 4.81 bytes per token; two new ungated gates; a `<discarded>` marker in the table
    - test: green — swift build clean, swift build --build-tests -Xswiftc -warnings-as-errors clean, swift test 973 + 27 + 33 tests, 0 failures, 1 pre-existing known issue
    - commit: 1397279
    - review: findings — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:341, reuse/reuse, the new `text(of:)` helper repeats production logic at 0.99 similarity
    - note: acceptance criterion 3 stays open by design. It needs `^fz49qds`.
  timestamp: 2026-08-17T17:45:03.834029+00:00
- actor: claude-code
  id: 01m08dpbpfjjkbw0959x2812s4
  text: |-
    Review finding fixed. What was decided and why.

    ## The choice: raise the production helper's visibility

    The finding offered two answers — call `Summarization.text` directly if it is visible to tests, or extract one shared utility. I took the first: `Summarization.text(of:)` went from `private static` to `static` (internal), and the eval target now calls it through the `@testable import FoundationModelsRouter` it already carries.

    Three reasons this beats a new shared utility:

    1. **It is already the prevailing pattern of that exact file.** `Summarization.chunk(_:maxTokens:)`, `chunkStrings(_:maxTokens:)` and `estimatedTokens(of:)` are all internal statics for precisely this reason, and `SummarizationStageTests` says so in a comment on `chunkStrings`: "the same function production code uses". `text(of:)` was the odd one out.
    2. **`Summarization` is the right owner.** `transcriptText(of:)`'s own doc calls what it builds "the text a summarizer reading the folded span is shown". `Summarization.text(of:)` is the function that really builds that text, reached through `renderLine(_:)`. Calling it is not borrowing a lookalike — it is reading the same function under test.
    3. **A new utility adds production surface for no production caller.** Extracting `TranscriptSegments.flattenedText(_:)` would move the code away from its one production user and leave a type nothing in the module needs.

    The `swift` validator's `access-control` rule states the standard this rests on word for word: "A test target is a caller. A Swift test target reads a library's `internal` members through `@testable import` ... That `internal` is load-bearing and correct as written." The doc comment now records it, so nobody re-privatizes the function and forces a copy back into the test target.

    ## The sweep

    The finding named line 341. The cause was swept across the whole file and the whole target, not that line alone:

    - `CompactionEvaluationTests.swift` — the copied `text(of:)` is deleted; BOTH callers (`assistantReplies(of:)` and `transcriptText(of:)`, three call sites between them) now go to `Summarization.text(of:)`.
    - Every other file of `Tests/FoundationModelsRouterEvals` was searched for segment/entry text flattening — `case .text(let`, `.segments`, `flatten`, `compactMap`, `joined(separator:` — and holds none. The two calls above are now the target's only flattening.

    Out of scope and deliberately untouched: `TranscriptDiffer.swift` flattens `instructions.segments` inline into a `[String]`, and several pre-existing suites in `FoundationModelsRouterTests`/`FoundationModelsRouterTestSupport` carry their own small flatteners. All are production or pre-existing test code outside this change and outside the finding's file.

    ## TDD

    RED first, and it was a real red. `SummarizationStageTests/flatteningJoinsTextSegmentsAndDropsTheRest` was written before the visibility changed, and `swift build --build-tests` rejected it:

    ```
    SummarizationStageTests.swift:319:31: error: 'text' is inaccessible due to 'private' protection level
    FoundationModelsRouter.Summarization.text:2:21: note: 'text(of:)' declared here
    ```

    The test asserts the contract the eval target now depends on: text segments joined in order by a newline, and a `.structure` segment between them dropped. Two callers make that worth stating outright instead of inferring it from an assembled prompt. No existing test was deleted and no assertion was weakened — the only edits to existing code are the three call sites and their doc comments.

    ## Acceptance criteria

    AC1 and AC2 are now checked. Both were met by the previous iteration and are proved by the ungated suite; the previous agent left them unchecked only out of caution about `update task` corrupting a long description. That update was made and verified this time: newlines intact, all three tags intact.

    AC3 stays open, unchanged. It needs the gated run, which is blocked on `^fz49qds`.
  timestamp: 2026-08-17T17:53:14.959827+00:00
- actor: claude-code
  id: 01m08dpkztmsjvthdqheqrjhc5
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift (`text(of:)` `private static` -> `static`, doc records why the width is load-bearing), Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift (duplicate `text(of:)` deleted; `assistantReplies(of:)` and `transcriptText(of:)` call `Summarization.text(of:)`), Tests/FoundationModelsRouterTests/SummarizationStageTests.swift (new `flatteningJoinsTextSegmentsAndDropsTheRest`, RED first on `'text' is inaccessible due to 'private' protection level`)
    - finding: `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:341` `reuse/reuse` — fixed and checked on the card. Cause swept across the whole file and the whole Evals target; no segment/entry text flattening remains in the target outside the two calls into production.
    - verification: `swift build` exit 0; `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0, zero warnings; `swift test` — 974 tests in 91 suites (was 973, +1 new) with 1 pre-existing known issue, 27 tests in 11 suites, 33 tests in 6 suites. Zero failures.
    - acceptance: AC1 and AC2 checked. AC3 open and not claimed — it needs the gated run, blocked on `^fz49qds`. The gated suite was deliberately not run.
    - next: /review
  timestamp: 2026-08-17T17:53:23.450663+00:00
- actor: claude-code
  id: 01m08dt69w22302s97mc01s6es
  text: |-
    ### test — green
    - evidence: `swift build` — build complete, 0 errors. `swift build --build-tests -Xswiftc -warnings-as-errors` — build complete, 0 warnings. `swift test` (ungated) — 1034 tests in 108 suites passed (974/91 + 27/11 + 33/6), 1 known issue (pre-existing, expected). 0 failures, 0 skipped outside the gated real-model suite (not run, per policy).
    - next: ready for review.
  timestamp: 2026-08-17T17:55:20.508796+00:00
- actor: claude-code
  id: 01m08dvgsga2gzczb19wpsbnbv
  text: |-
    ### commit — changed
    - evidence: a1bb7fc refactor(compaction): call Summarization.text(of:) instead of copying it (^vjf3mdm)
    - next: local commit only, not pushed.
  timestamp: 2026-08-17T17:56:04.016579+00:00
- actor: claude-code
  id: 01m08e377b1zqgwf51kdgkpt7m
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (checkpoint a1bb7fc) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed; 3 files reviewed, 2 skipped by `.reviewignore`
    - verified: the prior `reuse/reuse` finding is really corrected. `Summarization.text(of:)` is now `static` (internal) in `Sources/FoundationModelsRouter/Compaction/Summarization.swift`, the copy in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` is deleted, both call sites call the production function, and a new test in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` holds the flattening contract
    - next: the third acceptance criterion stays open — the gated eval cannot report `factInSummary` until `^fz49qds` corrects the 20-minute limit. It is an open criterion, not a code finding, and no review finding is open on this card.
  timestamp: 2026-08-17T18:00:16.363946+00:00
- actor: claude-code
  id: 01m08e43vvsah2vqah54w4wgj5
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files. `Summarization.text(of:)` raised from `private static` to `static`; the copy in the eval target deleted; a new test pins the flattening contract
    - test: green — swift build clean, swift build --build-tests -Xswiftc -warnings-as-errors clean, swift test 1034 tests, 0 failures, 1 pre-existing known issue
    - commit: a1bb7fc
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted; the prior reuse/reuse finding verified corrected at Summarization.swift:709, not taken on trust
    - card: `done`. Acceptance criteria 1 and 2 are met and checked. Criterion 3 stays open by design and needs `^fz49qds`.
  timestamp: 2026-08-17T18:00:45.691332+00:00
position_column: done
position_ordinal: ffb180
title: Compaction eval seeds are too small for a real summary to shrink them, so 8 of 9 gated folds are discarded and factInSummary cannot be measured
---
Found by the targeted gated run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` while verifying `^bgxtdk3`.

`^bgxtdk3` closed the empty-summary defect: the summarizer now writes real text. That change made a second condition visible, and this task is that condition.

## What happens

Of the 9 samples that completed, 8 report:

```
- seed=<name> class=retained factInSummary=false folded=false summarizerCalls=1 stages=
  summary=<none>
```

`summarizerCalls=1` with an EMPTY `stages` list is `Compactor.compact`'s shortfall exit: `Summarization` ran, the summarizer answered, and the fold was then discarded because `tokensAfter >= tokensBefore`. `CompactionResult.summary` is `nil` on that path, so the table prints `<none>` and `folded=false`.

The one seed that did fold — `codename` — behaved correctly end to end:

```
- seed=codename class=retained factInSummary=true folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
  summary=2. Stated facts
- the internal codename for the new feature is "Project Longbow".
```

## Why

The guard is correct and is doing its job. `Compactor.compact` refuses a fold that leaves the transcript no smaller, because swapping real conversation for a paraphrase that costs the same buys nothing.

The seeds are what changed meaning. A folded transcript is the header, the synthesized summary entry — text plus a `CompactionSegment` carrying `liveWindowEntryIds`, `foldedEntryIds`, the token counts and the stage list — and the untouched recency window. On a seed this small the recency window is most of the transcript, so the fold trades one or two old turns for an entry whose own metadata costs bytes. The margin was always thin. It only ever cleared because the stored summary held zero characters.

So `retained=9` is a pass for the wrong reason on 8 of the 9: the transcript came back UNCHANGED, and the resumed session answered from the original turns rather than from a summary. The dataset cannot measure what it exists to measure.

## Why this is its own task

Two answers are open and neither belongs to `^bgxtdk3`, which records no decision about either:

1. Grow the seed transcripts so a real summary is genuinely smaller than the span it replaces. `compactionEvalDefaultBudget` and the fixtures move together, and `defaultBudgetForcesSummarizationStage` already pins that the budget forces the stage — it does not pin that the fold is APPLIED.
2. Let the eval state the difference. A sample whose fold was discarded is neither `summaryLostFact` nor `foldProducedNoSummary`; it is a fold that was never applied, and no case names that today.

Prefer 1, and add a hermetic assertion beside `defaultBudgetForcesSummarizationStage` holding every seed to `stagesApplied.last == Summarization.stageName` under a fake summarizer whose answer is realistic in length — the ungated suite then fails the moment a seed stops folding, instead of a gated run discovering it.

## Acceptance Criteria

- [x] Every seed's fold is APPLIED, not discarded: a hermetic test holds each seed to `stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"]` against a summarizer whose answer is the length a real one writes, not a two-word stub
- [x] A discarded fold is legible in the eval table rather than reported as `<none>`, which reads the same as a stage that never ran
- [ ] The gated eval reports `factInSummary=true` on the large majority of seeds

## Review Findings (2026-08-17 12:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:341` `reuse/reuse` — Function `text(of:)` reinvents existing functionality that already exists in production code. The function extracts text segments using identical logic to an existing implementation. Verify if `Summarization.text` is accessible to tests and call it directly, or extract a shared utility. At 0.99 similarity, this appears to be the same operation in different contexts.

### Open criterion (not a code finding)

The third acceptance criterion — the gated eval reporting `factInSummary=true` on the large majority of seeds — cannot be measured yet. The gated eval exceeds its 20-minute limit, which is card `^fz49qds`. This criterion stays open until `^fz49qds` settles the time limit. #compaction #defect #real-model
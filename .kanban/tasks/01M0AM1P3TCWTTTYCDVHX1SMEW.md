---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjr6qyyvxsg9q0km7k1zvr
  text: |-
    ## Audit at `dd55fcd2c` — LIVE, and the gap became larger

    Commit `6fc9bb1` reverted the length directive and put a cut in code. `Sources/FoundationModelsRouter/Compaction/Summarization.swift:593` now states: "The assembled prompt states no length of its own."

    Both eval docs still say the opposite. Each names a length directive that no longer exists:

    - `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:167-168`
    - `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:1140-1141`

    There is a third correction. Line 1143 still calls the bound "what the fold ASKS for". `Summarization.swift:631` makes it a cut applied to the answer, so it is a ceiling now, not a request.

    Three corrections, not two.
  timestamp: 2026-08-18T23:19:21.598470+00:00
- actor: claude-code
  id: 01m0br70mn2bed3e3p3phen6aa
  text: |-
    ## Research — read `Summarization.swift` at HEAD, verified every figure

    What the stage ACTUALLY does now, read off the source rather than off this thread:

    **Bound 1 — the generation ceiling.** `summarizeOnce` computes `allowance = summaryTokenAllowance(condensing: content, atRatio: summaryTokenRatio)` and passes `outputTokenCeiling(forSummaryAllowance: allowance)` = `allowance + reasoningTokenHeadroom` as `maxTokens`. Defaults: `summaryTokenRatio` `0.25`, `reasoningTokenHeadroom` `4096`. It is in REAL tokens and it bounds the reasoning and the answer TOGETHER, so it never bounds the answer on its own.

    **Bound 2 — the cut.** The same method computes `retained = summaryTokenAllowance(condensing: content, atRatio: Self.summaryRetentionRatio)` and returns `Self.cut(summary, toCharacters: Self.characters(forEstimatedTokens: retained))`. `summaryRetentionRatio` is `0.8`. `characters(forEstimatedTokens:)` multiplies by `Compactor.charsPerTokenEstimate` (`4.0`), and `cut` measures `summary.utf8.count` — so this bound is in the UTF-8 content bytes the did-not-shrink guard reads. It cuts at the last sentence terminator or line end inside the budget, else the last word boundary, else the budget, and it never gives back empty text.

    Both bounds go through `summaryTokenAllowance`, so both are floored at `minimumSummaryTokens` (`128`) and capped at `maximumSummaryTokens` (`summaryTokenRatio` of `maxChunkTokens`, so `500` at the defaults).

    The prompt tells the model nothing: `Summarization.swift` states "The assembled prompt states no length of its own."

    **Why the eval's 154-token worst case still stands.** The fake writes `summaryTokens * compactionEvalMeasuredBytesPerToken` bytes; at the floor allowance that is `128 * 4.81` = 616 bytes = 154 estimated tokens. The cut binds on that answer only when `retained * 4.0 < 616`, that is `retained <= 153`, that is content of 191 estimated tokens or fewer. `everySeedsFoldableSpanOutweighsARealSummary` already requires every seed's span to be at least `ceil(154 * 1.5)` = 231 estimated tokens, and rendering only adds. So the cut cannot bind on any seed, and the fake's own answer size is the binding bound for this suite.

    **Figures re-checked against the source, none carried over:** 4224 = `128 + 4096`; 2.9x and 5.5x = `374/128` and `698/128`; 450 and 840 estimated tokens = `374 * 4.81 / 4.0` and `698 * 4.81 / 4.0`; 154 = `ceil(128 * 4.81 / 4.0)`; 616 = `ceil(128 * 4.81)`; 512 = `128 * 4.0`; 20% = `616/512`.
  timestamp: 2026-08-19T00:54:49.749351+00:00
- actor: claude-code
  id: 01m0brj2ytfv1ecy7gpzyfkwmn
  text: |-
    ## Corrections landed — 6 sites in 2 files, not 3 in 1

    The three the audit named, plus three the sweep found. The audit sampled; this enumerated.

    **`Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`**

    1. `RealisticSummaryLengthSummarizer`'s doc block — the named correction. It now states that the prompt names no length at all and never did, so the gated run's 374 to 698 real tokens are what a model writes with no length stated to it. It then names both bounds separately: `summaryTokenRatio` sizes the summary allowance, which the stage adds `reasoningTokenHeadroom` to and hands down as `maxTokens` (a ceiling on the GENERATION, in real tokens, covering reasoning and answer together), and `summaryRetentionRatio` sizes the cut `Summarization.cut` applies to the answer (a ceiling on the TEXT, in UTF-8 content bytes). The "20% over" paragraph now measures against the flat `charsPerTokenEstimate` conversion rather than against a directive.
    2. The `sentence` doc — "the length asked for is the length produced" now names the size the type computes for itself, and states that nobody asks the model for it.
    3. The comment in `everySeedFoldSurvivesARealisticSummary` — "the stated summary allowance" and "when the allowance is never stated to it" now read as the permanent state rather than as a contrast with a directive.
    4. `worstCaseSummaryEstimatedTokens`'s doc — the named correction, both halves. "Honoring its stated allowance" is gone, and "what the fold ASKS for" is now "what a summarizer WRITES, and not what the fold asks for, because the fold asks for nothing".

    **`Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift`**

    5. `CompactionEvalSummarizerCall`'s doc — "what one summarizer call of a fold asked the model for" now names the ceiling the call ran under, and states that nothing in the prompt states a length.
    6. `summarizerCalls`'s doc — the same phrase, same correction.
    7. `discardedSummaryPrefixCharacters`'s doc — it now states that the cut does not bound the printed text, because `CompactionEvalRealSubjectRunner`'s summarizer records the answer as the call returns it, before the stage cuts anything. Without that the reader cannot tell why a printed summary can pass the cut's bound. "A summary that stayed inside its allowance" became "an answer that came back inside that size".

    ## Two claims of mine were wrong, and I caught them before the second run

    I first wrote that the cut is a bound "no answer can exceed" and "a true ceiling on a stored summary". `Summarization.cut` ends `return budgeted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : budgeted` — an answer whose budgeted prefix holds no text is handed back WHOLE rather than erased. Both sites now state that exception.

    ## Left alone, deliberately

    - `discardedSummaryPrefixCharacters` says a discarded summary "is bounded only by the ceiling the whole generation ran under". That is still TRUE and needed no correction: the recorded text is the raw model answer, appended in `Support/CompactionEvalRealSubjectRunner.swift` inside `summarize(_:maxTokens:)` before the caller cuts it.
    - "Every seed's span earns the FLOOR of the summary allowance" — a numeric branch, no claim about a directive.
    - `CompactionEvalDataset.swift` says the 128-token floor costs "roughly 627 bytes", while `128 * 4.81` is 616 and two other sites in the target say 615 and 616. Stale, but it names no directive and no bound the model was told, so it is outside this card's sweep. Filed as `^a2x0ksj`.
  timestamp: 2026-08-19T01:00:52.570436+00:00
- actor: claude-code
  id: 01m0brj8d0wkw6y7xr27qf53mw
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift. `swift test` exit 0: 995 + 32 + 58 = 1085 tests in 114 suites, 0 failures. The 1 known issue is the pre-existing `withKnownIssue` at BoundedWait.swift:114, in a target this card does not touch.
    - next: /review. New card `^a2x0ksj` filed for the stale 627-byte figure in `CompactionEvalDataset.swift`.
  timestamp: 2026-08-19T01:00:58.144791+00:00
- actor: claude-code
  id: 01m0brxq12caqpc7s3v1xq1fh5
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (d682364) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 2 files reviewed; 4 `.kanban/` files excluded by `.reviewignore`.
    - Every corrected sentence was re-checked against `Sources/FoundationModelsRouter/Compaction/Summarization.swift` at HEAD, and each one is true:
      - `summaryTokenRatio` default is `0.25` and sizes the summary allowance (`summarizeOnce`, `allowance`).
      - `outputTokenCeiling(forSummaryAllowance:)` returns `allowance + reasoningTokenHeadroom` (`4096`) and that sum is the `maxTokens` given to the call, so the ceiling covers reasoning and answer together and bounds neither alone.
      - `summaryRetentionRatio` is `0.8`, sizes `retained`, and `cut(_:toCharacters:)` is applied to the RETURNED text. It measures `summary.utf8.count` against `UTF8Budget.prefix(of:keepingAtMostBytes:)`, and `lastSentenceBoundary(in:)` accepts a line end or a `.` `!` `?` at the end or before whitespace — so "UTF-8 content bytes, at a sentence or line boundary" is correct.
      - Both bounds go through `summaryTokenAllowance(condensing:atRatio:)`, which is `min(maximumSummaryTokens, max(minimumSummaryTokens, ceil(...)))`. `minimumSummaryTokens` is `128`; `maximumSummaryTokens` is `0.25` of `maxChunkTokens` `2000`, so `500`.
      - The assembled prompt is `prompt.text` + `---` + content, and `CompactionPrompt.default` ("router-default-v2") states no length. The two eval prompts state none either. So "the prompt names no length at all" holds.
      - `cut` ends `return budgeted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : budgeted`, so an answer whose budgeted prefix holds no text comes back whole. The exception both docs state is real.
    - Arithmetic recomputed, not accepted: 4224 = 128 + 4096. 616 = ceil(128 x 4.81) = ceil(615.68), and `RealisticSummaryLengthSummarizer.summarize` writes exactly that many ASCII bytes. 512 = 128 x 4.0. 154 = ceil(128 x 4.81 / 4.0) = ceil(153.92). 231 = ceil(154 x 1.5).
    - The 191-token claim recomputed: the cut binds when 616 > 4.0 x retained, so retained <= 153, so ceil(0.8 x T) <= 153, so T <= 191. At T = 191, retained = 153 and the limit is 612, so the cut binds. At T = 192, retained = 154 and the limit is 616, so it does not. "191 estimated tokens or fewer" is exact. `everySeedsFoldableSpanOutweighsARealSummary` asserts `span >= ceil(154 x 1.5)` = 231 for every seed, so the cut cannot bind on any seed.
    - next: none. Task moved to done.
  timestamp: 2026-08-19T01:07:13.570049+00:00
position_column: done
position_ordinal: ffb980
title: The eval target's two worst-case-summary docs understate the bound now that Summarization cuts every answer
---
`^azd033m` made the summary allowance a bound enforced in CODE — `Summarization.cut(_:toCharacters:)` cuts every summarizer answer down to the allowance its call earned, so a summary can no longer exceed it at all.

Two doc comments in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` still describe the world before that, where the bound was a hope:

- `RealisticSummaryLengthSummarizer` — records that an answer filling the allowance "is the largest a summarizer TOLD its allowance writes", and that it deliberately answers about 20% over the stated character bound (the allowance at 4.81 real bytes per token against a 4.0 estimate). Nothing is told an allowance any more, and an answer 20% over the bound is now cut back to it, so what this summarizer stands in for has changed.
- `CompactionEvalSeedSizingTests.worstCaseSummaryEstimatedTokens` — same correction. Its 154-token worst case is now a real ceiling rather than a claim about a well-behaved model, and the sizing gate it feeds can state that.

Neither is wrong about arithmetic and neither breaks a test — the whole ungated suite is green, and the hermetic gate `everySeedFoldSurvivesARealisticSummary` still passes, because the cut only ever makes a summary smaller. This is a documentation correction, and the reason it is a card rather than part of `^azd033m` is that `CompactionEvaluationTests.swift` was already dirty in the working tree from `^w1cz46m`'s session when `^azd033m` ran, so that card left it alone.

## What to do

Re-read both doc comments against `Summarization.cut(_:toCharacters:)` and state what the bound now IS: a cut applied to the answer, in the UTF-8 content bytes `Compactor`'s did-not-shrink guard measures, at a sentence boundary, never producing an empty summary.

Consider while you are there whether `RealisticSummaryLengthSummarizer` should stop answering 20% over the bound. It was sized that way to model a model that overruns a request; overrunning is no longer possible downstream of the cut, so the fake is now modelling a case the production path cannot produce.

## Related

- `^azd033m` — the card that added the cut, and the 30B measurement behind it.
- `^fm5ddk9` — the card whose 7-of-7 discarded folds the cut closes.

#compaction #eval #docs
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzkk8d73rxrjn9chrpk9e6an
  text: |-
    Picked up; research done.

    Where the two defects live:
    - `Sources/FoundationModelsRouter/Compaction/Summarization.swift` — `CompactionSummarizer.summarize(_:)` took a prompt and nothing else; `summarizeOnce` assembled the prompt and made the call.
    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift` — `BackendCompactionSummarizer` called `respond(to:maxTokens: nil)`, which `LiveModelLoader` resolves to its private `defaultMaxTokens` of 8192.
    - `Sources/FoundationModelsRouter/Compaction/Compactor.swift` — the `if let summarizer, let folded = ...` branch returned `Summarization`'s output unconditionally.

    Design decision on AC1. The card allows the bound to come from "the budget's target, or the size of the span being folded"; I took the span-size route and did NOT plumb `TokenBudget` through `Summarization.apply`. Reasons: (a) the ceiling is computed per summarizer call against that call's own content, so it holds at every level of the map-reduce tree rather than only over the whole span — a chunk's summary is a quarter of that chunk, each reduce round's summary a quarter of what it joins; (b) `maxChunkTokens` already bounds what any one call ingests, so the final summary of an arbitrarily long span is bounded too; (c) it leaves `apply`'s signature (and every DocC reference to it) untouched. Concretely: `summaryTokenRatio` (public var, default 0.25) and `Summarization.minimumSummaryTokens` (128, the floor so a small span still gets a usable summary rather than a fragment cut off mid-sentence).

    Protocol change: `summarize(_ prompt: String, maxTokens: Int)`. Non-optional deliberately — a summarizer call is never unbounded again by construction.

    Not done, and deliberately: no assertion was loosened anywhere. `defaultBudgetForcesSummarizationStage` (evals) still passes because its fake summary is tiny, so the new shrink guard does not reject that fold.
  timestamp: 2026-08-09T15:46:26.147924+00:00
- actor: claude-code
  id: 01kzkknyvkdsc096eve2vbx1ky
  text: |-
    Implementation landed, both defects.

    **AC1 — the bound.** `CompactionSummarizer.summarize(_:maxTokens:)`; `Summarization.summarizeOnce` computes the ceiling per call via a new private `outputTokenCeiling(condensing:)` = `max(Summarization.minimumSummaryTokens, ceil(estimatedTokens(content) * summaryTokenRatio))`, measured on the *content* alone rather than the assembled prompt (charging a summary for the length of the instructions asking for it would let a short span buy a long summary). `BackendCompactionSummarizer` now calls `respond(to:maxTokens: maxTokens)` instead of `nil`; `CancellableCompactionSummarizer` forwards it through the cancellation boundary.

    **AC2 — the shrink guard.** `Compactor.compact` computes `tokensAfter` off the folded transcript and returns it only when `tokensAfter < tokensBefore`; otherwise it falls through to the pre-existing shortfall exit (original transcript, empty `stagesApplied`, `tokensAfter == tokensBefore`, `summary == nil`). The exit's comment now names both routes it serves.

    **AC3 — ungated coverage**, in `SummarizationStageTests`:
    - `foldThatDoesNotShrinkTheTranscriptIsNotApplied` — new `OversizedSummarizer` fake returns a summary sized off `tokensBefore` itself, so it stays oversized however the fixtures are resized. Written first and watched fail on all four assertions (`resultTranscript == transcript`, `stagesApplied.isEmpty`, `summary == nil`, `tokensAfter == tokensBefore`) before the guard existed.
    - `summarizerCallIsBoundedByTheContentItCondenses`, `shortSpanIsBoundedAtTheMinimum`, `everyCallOfAChunkedFoldIsBounded` — `ScriptedSummarizer` now records `receivedMaxTokens`; the expected ceiling is restated in a test helper rather than read off the stage, so the arithmetic is pinned rather than compared against itself.

    **AC4 — gated, three consecutive runs**, `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionRoundTripIntegrationTests`, one at a time:

    | run | tokensBefore | tokensAfter | saved | result |
    |---|---|---|---|---|
    | 1 | 2074 | 1379 | 695 (33.5%) | 5 tests passed, 53.4s |
    | 2 | 2074 | 1379 | 695 (33.5%) | 5 tests passed, 52.9s |
    | 3 | 2074 | 1379 | 695 (33.5%) | 5 tests passed, 48.5s |

    Identical to the token, which is `^f80n046`'s greedy decoding doing its job. Against the card's measurement: `tokensBefore` is unchanged at 2074, and `tokensAfter` moved from ≈1843 (an 11% shrink) to 1379 (a 33.5% shrink) — the saving roughly tripled.

    **Read the margin with this caveat.** `^f80n046` changed the harness from `session.compact()` to `session.compact(budget: Self.foldBudget)`, where `foldBudget` is `TokenBudget(limit: 2048, target: 0.25)`. The production default target is 0.50. So 33.5% is the margin under the *tighter* target, not the production-default margin — the gated round trip no longer exercises the default end to end. That is a property of the harness, not of this change: the fold's ceiling here is derived from the span's own size, and no budget figure reaches the summarizer, so the same span would produce the same summary under either target. What a 0.50 target would change is only whether the deterministic stages land under target on their own and skip `Summarization` entirely.

    The margin was made visible by a `print` in the gated test (the same `[testName] key=value` shape `LanguageModelSessionBackendTests` and `PropagationProbeIntegrationTests` already use) — the bare `tokensAfter < tokensBefore` assertion passes identically for a fold that saved 5 tokens and one that saved 695, which is exactly how this defect stayed invisible.
  timestamp: 2026-08-09T15:53:50.195916+00:00
- actor: claude-code
  id: 01kzkkp6t0w9kjb1zdvk61sevr
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Compaction/Compactor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift
    - ungated: `swift test` — 822 tests passed (774 + 24 + 24), 0 failures, 0 warnings (818 before; +4 new tests)
    - gated: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionRoundTripIntegrationTests` x3, one at a time — all green, tokensBefore=2074 tokensAfter=1379 saved=695 (33.5%) on every run, under `foldBudget`'s 0.25 target rather than the production-default 0.50
    - no assertion was loosened or deleted anywhere in the diff
    - next: /review
  timestamp: 2026-08-09T15:53:58.336978+00:00
position_column: doing
position_ordinal: '80'
title: A fold's summary is unbounded, so compaction can save far less than the span it replaces — and the pipeline applies a fold that grew the transcript
---
Discovered by `^f80n046` while making the gated compaction suites deterministic. Not a determinism defect — the numbers below are now reproducible run to run — but a compaction-quality one, measured on real hardware for the first time.

## The measurement

`CompactionRoundTripIntegrationTests` with greedy decoding, `RealModels.standard`, 2048-token working context, 8 scripted turns:

- `tokensBefore` = 2074 estimated tokens
- old span (4 turns outside the recency window) ≈ 1068 estimated tokens
- the summary the fold produced: **3346 characters ≈ 837 estimated tokens**
- `tokensAfter` = 2143 (with the boundary's id manifest still counted) / ≈1843 once `^f80n046` stopped counting that manifest

So the summary was roughly **four fifths the size of the span it replaced**. After `^f80n046`'s estimator correction the fold nets an 11% shrink; before it, the fold reported a *larger* transcript than the one it replaced.

## Two gaps behind it

1. **No output budget on a summarizer call.** `CompactionSummarizer.summarize(_:)` takes a prompt and nothing else. `BackendCompactionSummarizer` calls `backend.respond(to: prompt, maxTokens: nil)`, which resolves to `LiveModelLoader`'s `defaultMaxTokens` of 8192. A fold knows its `TokenBudget` and knows the estimated size of the span it is folding; nothing carries either into the generation that produces the summary, so a model is free to answer at any length and routinely does.

2. **The pipeline applies a fold that made things worse.** `Compactor.compact` returns `Summarization`'s output whenever the stage produced one, without checking `tokensAfter` against `tokensBefore`. The oversized-tail path already knows how to return the original transcript unchanged with an empty `stagesApplied`; a fold that grew the transcript should take the same exit. As shipped, a session can swap its backend for a *larger* transcript and record a checkpoint saying so.

## Acceptance Criteria
- [x] A summarizer call is bounded by something the fold knows — the budget's target, or the size of the span being folded — rather than by the generation path's generic 8192-token default
- [x] `Compactor.compact` never returns a folded transcript larger than the one it was given; a fold that fails to shrink reports the shortfall the same way the oversized-tail case does
- [x] Ungated coverage for both, with a summarizer fake that returns an oversized summary
- [x] The gated round trip still passes three consecutive runs, and its `tokensAfter < tokensBefore` margin is reported

## Tests
- [x] Ungated first (a fake summarizer needs no GPU); gated runs one at a time to confirm the real margin #phase-1
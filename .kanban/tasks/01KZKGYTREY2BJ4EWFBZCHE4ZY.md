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
- actor: claude-code
  id: 01kzkmdaeqfk50rydqx2n4ye9a
  text: |
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (c23842f), task-mode
    - evidence: 3 open findings — Compactor.swift:144, Compactor.swift:213 (engine, 2 confirmed / 0 refuted of 18 attempted); Summarization.swift:104 (driver verification of the design questions in scope)
    - engine findings: both copies of the shortfall `CompactionResult` construction are verbatim duplicates. `git blame` puts both at 0663204e (2026-07-23), so the duplication predates this delta, but the delta gave the second exit a new caller path (the fold-shortfall fall-through) and documents the two as the same exit — in scope, and source code, so the pre-existing-test exception does not apply.
    - design questions judged on the merits: per-call bound is sound at every level of the map-reduce tree EXCEPT `reduce`'s no-progress fallback, which deliberately hands one call more than `maxChunkTokens` ("over budget or not"), making that call's ceiling `0.25 x joined` and therefore span-dependent — the `summaryTokenRatio` doc claims the bound is unconditional, which the same file contradicts. `minimumSummaryTokens` verified independently as unable to reintroduce defect 2: the shrink check is whole-transcript and strict, and neither the ratio nor the floor enters it. `summaryTokenRatio` as a public var matches the two public vars already on the struct; note `Compactor.compact` builds `Summarization()` with defaults, so no knob is settable from the production path.
    - next: implement the 3 findings, then re-review. Task stays in `review`.
  timestamp: 2026-08-09T16:06:35.735940+00:00
- actor: claude-code
  id: 01kzkn2g1822zrwkqs4vhprygh
  text: |-
    Iteration 2 — all three findings worked.

    **Findings 1 & 2 (Compactor.swift:144 and :213), the duplicated shortfall result.** Extracted `shortfallResult` as a local at the top of `compact`, exactly as the finding prescribes, and both exits now `return (transcript, shortfallResult)`. The comment on the local names both routes it serves, so the already-under-target exit and the shortfall exit are visibly one value rather than two constructions that happen to agree.

    **Finding 3 (Summarization.swift:104), the substantive one.** Took the stronger of the two options the finding allows: made the claim TRUE rather than weakening it.

    The finding names the `reduce` no-progress fallback as the hole. Reading the whole file, that is not the only one — the same cause reaches a second path. `chunk(_:maxTokens:)` never splits a turn, so a span that is a single turn larger than `maxChunkTokens` produces exactly one, oversized chunk; `summarize` then takes its `chunks.count > 1` guard's else branch and hands the whole rendered turn to one `summarizeOnce`. That call ingests more than `maxChunkTokens` too, and its ceiling grew with the span in exactly the same way. Fixing only the flagged line would have left it.

    The cause in both is one expression: `outputTokenCeiling(condensing:)` scaled the input with nothing above it. So the fix is at the cause, not at either call site:

    - `outputTokenCeiling(ingesting:)` — the ratio-and-floor arithmetic, now in one place.
    - `maximumOutputTokens` = `outputTokenCeiling(ingesting: maxChunkTokens)` — what a full chunk earns.
    - `outputTokenCeiling(condensing:)` = `min(maximumOutputTokens, outputTokenCeiling(ingesting: estimatedTokens(of: content)))`.

    That closes both paths at once and every future one: no call, whatever it is handed, answers above what a full chunk earns. With the defaults that is `max(128, ceil(2000 * 0.25))` = 500 tokens. The clamp is a no-op for every call at or under `maxChunkTokens`, so nothing that already honored the bound changes.

    Why bounding beats documenting here, since the finding offered both: the fallback exists for *termination*, and termination is a property of the recursion, not of the summarizer's output length. Capping how much the model may WRITE cannot make `reduce` recurse — it returns directly from that branch. So the unbounded-input path stays exactly as it was (it must, to guarantee progress) while the unbounded-OUTPUT consequence, which is the actual defect, is gone. Nothing was traded away.

    Docs corrected to match, all in the same file, since the same untrue claim appeared in four places: `summaryTokenRatio`'s "Since `maxChunkTokens` bounds what any one call ingests…"; `maxChunkTokens`'s "so no summarizer call ever has to ingest more than this, however long the folded span is"; `reduce`'s "*no* summarizer call in this fold … ever has to ingest more than `maxChunkTokens`"; and `summarizeOnce`'s bound note. Each now states plainly that two paths DO ingest more, names them, and says the output cap is what holds regardless.

    **Tests (TDD, both watched fail first).**
    - `reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk` — 3 old turns, each its own chunk, each chunk summary twice `maxChunkTokens` so `chunkStrings` can pair none of them and the no-progress fallback fires over the joined set. RED: ceiling 7661 against an expected 1277, and `ceiling < unbounded` false at 7661 == 7661.
    - `unsplittableTurnCallIsBoundedDespiteIngestingMoreThanAChunk` — the map-side path the finding did not name: one old turn, `maxChunkTokens` an eighth of it, one oversized chunk, one call. RED: 1280 == 1280.

    Both are sized so the assertion pins the CAP rather than the `minimumSummaryTokens` floor — with small fixtures the floor would have swallowed the difference and the test would have passed against the bug.

    `expectedCeiling` in the test helper gained `maxChunkTokens` and now restates the full clamped arithmetic. That is a correction of WHAT the assertion compares, not a loosening: it went from restating two thirds of the formula to restating all of it, and the three pre-existing call sites still pass unchanged because their content is within `maxChunkTokens`.

    **Out of scope, filed rather than fixed:** `^2c46sd7` — `Compactor.compact` builds `Summarization()` with defaults, so `keepRecentTurns`, `maxChunkTokens`, `summaryTokenRatio` (and now `maximumOutputTokens`) are unreachable from the production path. The review noted it; the card asked for it to be filed.

    No assertion was loosened or deleted anywhere in this delta.
  timestamp: 2026-08-09T16:18:09.576441+00:00
- actor: claude-code
  id: 01kzkn2sjdrfdm15pn9rs4s1vn
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Compaction/Compactor.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift
    - findings: 3 of 3 worked and checked (Compactor.swift:144, Compactor.swift:213, Summarization.swift:104)
    - ungated: `swift test` — 824 tests passed (776 + 24 + 24), 0 failures, 0 compiler warnings (822 before; +2 new tests)
    - gated: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionRoundTripIntegrationTests` — 5 tests passed, `tokensBefore=2074 tokensAfter=1379 saved=695`, identical to iteration 1, confirming the new output cap is a no-op on the production fixture (its old span is well under the default maxChunkTokens of 2000)
    - no assertion loosened or deleted; `expectedCeiling` in the test helper was widened to restate the full clamped formula
    - filed out of scope: `^2c46sd7`
    - next: /review
  timestamp: 2026-08-09T16:18:19.341466+00:00
- actor: claude-code
  id: 01kzknrc35h6139hpd8n8qj6xh
  text: |-
    ### review — findings
    - evidence: engine `review sha HEAD~1..HEAD` (d5155c8) clean — 0 findings, 9 validators attempted, 0 failed. 1 finding from the directed doc verification — Sources/FoundationModelsRouter/Compaction/Summarization.swift:301, with the same cause at :85 and :418.
    - verified sound: shortfallResult is one construction used by both Compactor.compact exits; the output cap cannot affect reduce's termination (count-based measure, fallback returns without recursing, smaller summaries only pack better); no caller loops or re-summarizes (compact calls apply once, and a smaller tokensAfter moves away from the shortfall exit); the cap is a no-op for content at or under maxChunkTokens and preserves the 128 floor; summaryTokenRatio and summarizeOnce docs now state something true.
    - next: correct the "two paths" enumeration at Summarization.swift:85, :301, :418 — a lone summary over maxChunkTokens becomes its own oversized group via chunkStrings/binPack, so a reduce round that groups (and recurses) can still over-ingest. Code is correct; the claims are not.
  timestamp: 2026-08-09T16:30:06.437027+00:00
- actor: claude-code
  id: 01kzkp187wfw0yg76krd52frjh
  text: |-
    Iteration 3 picked up; pulled back to `doing`. Research done before editing.

    **The finding reproduces exactly as written.** Walked it through the code rather than taking it on the record:

    - `binPack` (the shared loop behind both chunkers) starts a new group only when `!current.isEmpty && currentTokens + itemTokens > maxTokens`, so a lone item already over `maxTokens` is appended to an empty `current` and becomes its own oversized group. At `maxChunkTokens: 2000` with summaries `[2400, 300, 300]`: A is appended alone; B would push 2400+300 over, so `[A]` is pushed and B starts a new group; C fits with B. Result `[[2400], [300, 300]]` — `groups.count` 2 `< summaries.count` 3, so `reduce`'s no-progress guard does NOT fire, the round groups and recurses, and the loop still calls `summarizeOnce` on the 2400-token summary alone. A round that *groups* can over-ingest. The doc claiming otherwise is false.

    **The universal property, verified against the code.** `summarizer.summarize` is called from exactly one place in all of `Sources` — inside `summarizeOnce` — and every summarizer call this stage makes goes through `summarizeOnce` (the single-chunk map call, the map loop, the fits-in-one-call reduce, the no-progress fallback, and the grouping round's loop). That one call site always passes `maxTokens: outputTokenCeiling(condensing: content)`, which is `min(maximumOutputTokens, outputTokenCeiling(ingesting:))`. So the clamp applies to every call unconditionally; nothing about the property depends on knowing which calls over-ingest.

    **A fourth site carries the same defect, which the finding did not name.** `summaryTokenRatio`'s doc says "because **two calls** have to ingest more than `maxChunkTokens`". That is the same false count as the three named sites (`maxChunkTokens`'s "Two paths cannot honor it", `reduce`'s "every reduce round that can group ingests at most `maxChunkTokens`", and `maximumOutputTokens`' "the two calls that cannot be kept there"). Fixing only the three named would leave the cause in the file.

    **A fifth, of the same family.** The inline comment on `reduce`'s no-progress branch asserts "every summary is already, on its own, at or over maxChunkTokens" as the reason grouping produced singletons. That is not the only way: `[1500, 600, 1500, 600]` at 2000 packs into four singletons with no item over the ceiling. `reduce`'s own doc already says so ("but also possible with several under-ceiling summaries that simply don't pair up"), so the comment contradicts the doc six lines above it.

    Plan, per the card's stated preference: state the universal property (every call's output is clamped to `maximumOutputTokens` regardless of what it ingests) and describe the *mechanism* that lets a call over-ingest (neither packer ever splits a single item), marking any specific path as an example rather than a complete set. No third enumeration.

    No ARCHITECTURE.md in this repo, so nothing to reconcile there.
  timestamp: 2026-08-09T16:34:57.404343+00:00
- actor: claude-code
  id: 01kzkpbby9ydft3jnqf2ctzwwd
  text: |-
    Iteration 3 landed. Doc-only; no code line changed (the whole diff is `///` and `//` lines).

    **The option taken.** The finding offered two: name the third over-ingesting path, or drop the enumeration and state only what holds. Took the second, because the first is what iterations 1 and 2 already tried and what a fourth review would falsify again. Iteration 1 asserted an unconditional bound (false). Iteration 2 replaced it with a two-path enumeration (also false — this finding). A third enumeration would be the same mistake at a different arity. The enumeration was never what made the property true; `outputTokenCeiling(condensing:)`'s `min(maximumOutputTokens, …)` is, and it applies to every call whether or not anyone has listed it.

    **What each site now says, and the line that makes it true.**

    - `maxChunkTokens` — was "Two paths cannot honor it". Now states it is a chunking target, not a promise about what any one call ingests, and gives the *mechanism*: both packers share `binPack`, which never splits a single item, so an item already larger than the ceiling becomes its own oversized group. An unsplittable turn and `reduce`'s no-progress fallback are named as **examples of a call ingesting more than this, not a complete list of them** — the phrase is explicit so no future reader reads it as exhaustive. True by `binPack`'s `if !current.isEmpty && currentTokens + itemTokens > maxTokens` — an oversized item appended to an empty `current` is never split.
    - `summaryTokenRatio` — was "because **two calls** have to ingest more than `maxChunkTokens`", the same false count the finding names at the other three sites, which the finding did not list. Now "a call can be handed more than `maxChunkTokens` … `maximumOutputTokens` closes it without having to know which calls those are". Also dropped "a chunk's summary **is a quarter of** that chunk" for "is sized against that chunk" — with the floor and the clamp both in play, the literal quarter is not exact, and an inexact arithmetic claim is the next thing a review would catch.
    - `reduce` — was "every reduce round that can group ingests at most `maxChunkTokens`". Now says re-chunking aims each call at the ceiling without guaranteeing it, and states plainly that an oversized lone summary is condensed as it stands **in a round that groups and recurses, not only in the no-progress fallback** — the exact case the finding proved. Closes with the universal: every call here goes through `summarizeOnce`, whose ceiling is clamped to `maximumOutputTokens`.
    - `maximumOutputTokens` — was "It exists for the two calls that cannot be kept there". Now "It is applied to every call all the same — `outputTokenCeiling(condensing:)` clamps to it, and every call reaches that through `summarizeOnce` — rather than to a listed set of calls … without the bound depending on any such list being complete."

    **A fifth site, same family, not in the finding.** `reduce`'s no-progress inline comment claimed "every summary is already, on its own, at or over maxChunkTokens" as the reason grouping produced singletons. `[1500, 600, 1500, 600]` at 2000 packs into four singletons with nothing over the ceiling, and `reduce`'s own doc six lines above already said so. Now reads "grouping produced one singleton group per summary, so no two adjacent summaries fit together under maxChunkTokens" — which is exactly what `groups.count == summaries.count` means, since `binPack` emits at most one group per item.

    **Verification of the replacement prose against the code, not against the record.** `summarizer.summarize` has exactly one call site in all of `Sources` — inside `summarizeOnce`. Every summarizer call this stage makes routes through it: the single-chunk map call, the map loop, the fits-in-one-call reduce, the no-progress fallback, and the grouping round's loop. That site always passes `maxTokens: outputTokenCeiling(condensing: content)` = `min(maximumOutputTokens, outputTokenCeiling(ingesting:))`. Every sentence written above points at one of those.

    **Not done, deliberately.** No behavior changed, so no new test. The constraint was explicit that a behavior change would mean the finding was misdiagnosed; it was not — the code was already correct, and the two existing tests (`reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk`, `unsplittableTurnCallIsBoundedDespiteIngestingMoreThanAChunk`) already pin the clamp. No gated run: a comment cannot move `saved=695`.

    Left alone on purpose: the fixture comment in `SummarizationStageTests` reading "the one call that must ingest more than maxChunkTokens". It is scoped to that fixture, where the three map calls each ingest exactly one chunk and only the fallback exceeds it, so it is true as written and is in a different file from the finding.
  timestamp: 2026-08-09T16:40:28.873969+00:00
- actor: claude-code
  id: 01kzkpbkkm4yw9b4k30zqkszar
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Compaction/Summarization.swift (doc-only; `git diff` shows only `///` and `//` lines, no code line touched)
    - findings: 1 of 1 worked and checked (Summarization.swift:301, with the same cause corrected at :85 and :418 as the finding directs, plus two more instances of the same cause the finding did not name — `summaryTokenRatio`'s "two calls" and `reduce`'s no-progress inline comment)
    - ungated: `swift test` — 824 tests passed (776 + 24 + 24), 0 failures, unchanged from the baseline as expected for doc-only. The lone `warning:` in the log is SwiftPM's build-graph note about the vendored mlx-swift Cmlx resource bundle, not a compiler warning from any source file
    - gated: not run — a comment cannot move `saved=695`, and the card's constraints said none was needed
    - no test added: no behavior changed. The clamp is already pinned by `reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk` and `unsplittableTurnCallIsBoundedDespiteIngestingMoreThanAChunk`
    - no assertion loosened or deleted
    - next: /review
  timestamp: 2026-08-09T16:40:36.724393+00:00
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
- [x] Ungated first (a fake summarizer needs no GPU); gated runs one at a time to confirm the real margin

## Review Findings (2026-08-09 10:58)

- [x] `Sources/FoundationModelsRouter/Compaction/Compactor.swift:144` — CompactionResult construction is verbatim duplicated at line 213 — same arguments in two code paths, risks drift if one is changed without the other. Extract to a local variable at the top of the function: `let shortfallResult = CompactionResult(summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [])`, then return `(transcript, shortfallResult)` from both the guard at line 142 and the final return at line 211.
- [x] `Sources/FoundationModelsRouter/Compaction/Compactor.swift:213` — CompactionResult construction is verbatim duplicate of line 144 — same arguments in two code paths, risks drift if one is changed without the other. Extract to a local variable at the top of the function: `let shortfallResult = CompactionResult(summary: nil, tokensBefore: tokensBefore, tokensAfter: tokensBefore, stagesApplied: [])`, then return `(transcript, shortfallResult)` from both the guard at line 142 and the final return at line 211.

## Design-Question Verification (2026-08-09 10:58)

Answers to the three design questions the review was asked to judge on the merits, verified against the delta rather than accepted from the record.

- [x] `Sources/FoundationModelsRouter/Compaction/Summarization.swift:104` — the `summaryTokenRatio` doc claims the bound holds unconditionally: "Since `maxChunkTokens` bounds what any one call ingests, the final summary of an arbitrarily long span is bounded too." `reduce`'s no-progress fallback contradicts that in the same file — when `chunkStrings` cannot merge any two summaries it calls `summarizeOnce(joined, ...)` on the full joined set, "over budget or not", so that call ingests more than `maxChunkTokens` and its ceiling is `0.25 x joined`, which grows with the number of chunk summaries. Reachable because `chunk(_:maxTokens:)` never splits a turn: a span of single turns each over ~4x `maxChunkTokens` yields chunk summaries too large to pair under `maxChunkTokens`. Correct the claim to state the bound holds at every level except that fallback, or bound the fallback call's ceiling by `maxChunkTokens` independently of its input size.

Verified sound, no change required:

- **Per-call rather than per-fold bound is otherwise sound.** Every map call and every normal reduce round ingests at most `maxChunkTokens`, so its ceiling is at most `max(minimumSummaryTokens, ceil(maxChunkTokens * summaryTokenRatio))` = 500 tokens, at every level of the tree. Not plumbing `TokenBudget` through `Summarization.apply` costs nothing here: a per-fold budget would still have to be divided across an unknown-width tree, and the whole-transcript shrink check in `compact` is the backstop either way. The single exception is the fallback recorded above.
- **`minimumSummaryTokens` (128) cannot reintroduce defect 2.** Verified independently, not accepted from the prior tester. `Compactor.compact` computes `tokensAfter` over the whole folded transcript and requires strict `tokensAfter < tokensBefore`; neither `summaryTokenRatio` nor `minimumSummaryTokens` appears in that comparison — they only size a summarizer call's ceiling. A 128-token floor applied to a span smaller than 512 tokens can indeed license a summary larger than the span it replaces, and the resulting transcript then fails the strict `<` check and takes the shortfall exit (original transcript, empty `stagesApplied`, `summary == nil`, `tokensAfter == tokensBefore`). The strict `<` also rejects a break-even fold. The floor is contained by construction.
- **`summaryTokenRatio` as a public var, default 0.25.** Consistent with the two public vars already on the same struct (`keepRecentTurns`, `maxChunkTokens`) — it introduces no new surface shape. Note that `Compactor.compact` constructs `Summarization()` with all defaults, so none of the three knobs is settable from the production path; all three are reachable only by constructing the stage directly. 0.25 is defensible: it is a hard stop rather than a target, floored at 128, and measured against the 0.8-of-span summary that motivated the task.

Evidence on record for this pass: ungated `swift test` 822 tests (774+24+24), 0 failures; gated round trip 3 consecutive runs at `tokensBefore=2074 tokensAfter=1379 saved=695`, identical across runs — that margin is against the harness `foldBudget` of 0.25, not the production default of 0.50.

## Review Findings (2026-08-09 11:23)

- [x] `Sources/FoundationModelsRouter/Compaction/Summarization.swift:301` — the `reduce(_:prompt:summarizer:)` doc's replacement claim is false: "so every reduce round that can group ingests at most ``maxChunkTokens`` worth of content, however many chunks the original span needed. The one round that cannot group — the no-progress fallback below — hands a single call everything left". A round that *does* group can still ingest more than `maxChunkTokens`, because `chunkStrings(_:maxTokens:)` never splits a single summary, so a lone summary already over `maxChunkTokens` becomes its own oversized group — stated by `chunkStrings`' own `- Returns:` ("each (except a lone oversized summary) at or under `maxTokens`") and by `binPack` ("a lone already-oversized item becomes its own (over-`maxTokens`) group"). Concretely at `maxChunkTokens: 2000`, chunk summaries estimated `[2400, 300, 300]`: `binPack` yields `[[2400], [300, 300]]`, so `groups.count` (2) `< summaries.count` (3), the no-progress guard does not fire, the round groups and recurses — and `summarizeOnce` is nonetheless called on the 2400-token summary alone. `reduce`'s own doc already concedes this state exists ("always true when every summary is individually at or over the ceiling"), so the comment contradicts itself. Same cause makes two more sites incomplete: `Summarization.swift:85` ("Two paths cannot honor it") and `Summarization.swift:418` ("It exists for the two calls that cannot be kept there") both enumerate only the unsplittable turn and the no-progress fallback, omitting this third path. The code is correct — `outputTokenCeiling(condensing:)` clamps every call rather than only the enumerated ones — so fix the claims at all three sites: either name the third over-ingesting path, or drop the enumeration and state only what holds, that no call's output exceeds `maximumOutputTokens` however much it ingests.

## Design-Question Verification (2026-08-09 11:23)

Judged on the merits against the delta, not accepted from the record.

- **Findings 1 and 2 are genuinely one construction now.** `Compactor.compact` builds `shortfallResult` once at the top and returns it from both the already-under-target guard and the final shortfall return. The two remaining `CompactionResult(...)` constructions in the function are distinct values (a stage-target hit, and an applied fold), not the shortfall. Verified.
- **The termination argument is sound.** `reduce`'s recursion measure is `summaries.count`, made strictly decreasing by `guard groups.count < summaries.count`; it is a count, wholly independent of how many tokens any call answers, so capping output cannot affect it. The no-progress fallback `return`s the `summarizeOnce` result directly with no recursion after it, so capping that branch cannot make it recurse. Further, a smaller summary can only let `binPack` fit *more* per group, so groups.count is smaller or equal — the cap makes progress more likely, never less.
- **No caller loops or re-summarizes on a shorter summary.** `Compactor.compact` calls `Summarization().apply` exactly once, inside an `if let`, with no retry. A truncated summary lowers `tokensAfter`, which makes the strict `tokensAfter < tokensBefore` check *more* likely to pass — a cap can only move the outcome away from the shortfall exit, never toward a re-attempt.
- **The cap does not bind on any in-budget call, so it trades away nothing on the normal path.** `outputTokenCeiling(ingesting:)` is monotone nondecreasing in its argument, so for content at or under `maxChunkTokens` the new `min(maximumOutputTokens, ...)` is a no-op. The `minimumSummaryTokens` floor also survives the `min`: both operands are at least 128.
- **Not one defect traded for another.** The capped fallback does compress harder than the unbounded version, but the unbounded version is precisely the defect this task exists to close, and `maxTokens` as a hard generation stop is the same mechanism already applied to every in-budget call — the commit lowers a ceiling on two paths, it does not introduce a new loss mechanism.
- **`summaryTokenRatio` (line 111) and `summarizeOnce` (line 381) now state something true.** Every call reaches the summarizer through `summarizeOnce` -> `outputTokenCeiling(condensing:)`, and the final summary is always some call's output (or `summaries[0]`, itself a call's output), so "the bound holds for every call a fold makes, and therefore for the final summary of a span of any length" holds. The two remaining doc sites are the subject of the finding above.

Evidence on record for this pass: ungated `swift test` 824 tests (776+24+24), 0 failures; gated round trip 5 passed at `saved=695`, unchanged from iteration 1 (the cap is a no-op on that fixture, whose span is under `maxChunkTokens`). #phase-1
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky8c3mhj3y0r0h9cy6mvgf8x
  text: |-
    Implemented via TDD:
    - Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift — new `CompactionPrompt` struct (name/text) with `.default` = "router-default-v1", text verbatim from compaction_plan.md §2 (seven numbered sections).
    - Sources/FoundationModelsRouter/Compaction/Summarization.swift — new `CompactionSummarizer` protocol (minimal `summarize(_:) async throws -> String`, deliberately narrower than `LanguageModelSessionBackend`) and `Summarization` struct: renders the "old" (foldable) span to text via `TranscriptTurns`, map-reduce summarizes (turn-aligned chunking via `maxChunkTokens`, re-summarizing chunk summaries when >1 chunk), synthesizes a `.response` entry carrying the summary text segment + a `CompactionSegment`.
    - Sources/FoundationModelsRouter/Compaction/Compactor.swift — `compact` signature extended to `compact(_:prompt:budget:summarizer:) async throws`; wires `Summarization` in as the last-resort stage when a summarizer is supplied and the deterministic stages alone don't land under target. No summarizer -> unchanged model-free behavior.
    - Design note: `Summarization.apply` always operates on the *original* transcript (never the post-TurnTruncation `current`), since TurnTruncation would already have dropped the old turns' content — nothing left to render otherwise. Recomputes its own old/recent split via the same `TranscriptTurns` helper at the same `keepRecentTurns: 4` default, so the recency window stays byte-identical.
    - `tokensAfter` in the synthesized `CompactionSegment` uses a two-pass build (placeholder 0, then corrected) since the segment's own JSON size affects the transcript's measured size — an accepted ~1-token approximation, consistent with this pipeline's documented "estimate, never exact" character-ratio approach.
    - Updated Tests/FoundationModelsRouterTests/CompactorPipelineTests.swift call sites to `try await` (signature change only, no assertion changes).

    New test file: Tests/FoundationModelsRouterTests/SummarizationStageTests.swift (11 tests) covering: CompactionPrompt.default verbatim match, segment contents (foldedEntryIds/liveWindowEntryIds/tokensBefore/tokensAfter/stagesApplied/promptName), prompt assembly (default + custom, verbatim), map-reduce chunking boundaries, short-span no-chunking, no-old-span returns nil, summarizer-failure propagation, and Compactor-level integration (both with and without a summarizer, plus laziness — summarizer never invoked when deterministic stages alone suffice).

    really-done: `swift build` clean, full `swift test` green — 462 tests passed, 0 failures (gated real-model integration suites skipped as expected, unrelated to this change). Adversarial double-check dispatched for sign-off before handoff.
  timestamp: 2026-07-23T20:54:09.202431+00:00
- actor: claude-code
  id: 01ky8ddnyz24713ps9rzvm7s9p
  text: |-
    Adversarial double-check (round 1) returned REVISE with one medium-severity finding, addressed:

    Finding: `Summarization`'s reduce step did a single flat join+summarize over all chunk summaries with no bound check, contradicting the documented "never ingest more than maxChunkTokens in one call" invariant — for a long enough folded span, the joined chunk summaries themselves could overflow maxChunkTokens in that one reduce call. The passing test at the time only exercised 2 chunks with tiny canned strings, never triggering the gap.

    Fix: `Summarization.swift` now has a recursive `reduce(_:prompt:summarizer:)` that re-chunks (via a new `chunkStrings(_:maxTokens:)`, sharing a new generic `binPack` helper with `chunk(_:maxTokens:)`) and re-reduces whenever the joined summaries would themselves exceed `maxChunkTokens`, with a no-progress guard (falls back to one flat call, never infinite-recurses) for the edge case where every individual summary is already oversized on its own. Added `Summarization.estimatedTokens(of: String)` for plain-text sizing (vs. the transcript-JSON-based `Compactor.estimatedTokenCount`).

    Two new TDD tests cover this: `reduceRecursesWhenJoinedChunkSummariesExceedMaxChunkTokens` (forces multi-round tree-shaped reduction, predicts grouping via the same `chunkStrings` function to stay robust to byte-size nuances, asserts call count and per-call prompt contents prove real recursion) and `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible` (forces the no-progress guard, proving termination).

    `swift build` clean; `swift test` green: 464 tests, 0 failures (13 in SummarizationStageTests, up from 11).

    The double-check's second (low-severity, explicitly non-blocking) observation — that `keepRecentTurns: 4`'s agreement across `ToolOutputElision`/`TurnTruncation`/`Summarization` defaults is coincidental, not threaded from a single source — is accepted as a documented follow-up rather than fixed now: `Compactor.compact` doesn't currently expose a configurable `keepRecentTurns` at all (out of this task's scope per its "What"/Acceptance Criteria), so there is no live call site today where the three could actually diverge. Worth revisiting if/when the pipeline gains a configurable recency window.

    Re-spawned double-check (round 2, bounded per really-done's contract) to confirm the fix; awaiting its verdict before final handoff.
  timestamp: 2026-07-23T21:17:06.911053+00:00
- actor: claude-code
  id: 01ky8dkga56hg5eg2c9yvrm62r
  text: |-
    Adversarial double-check (round 2) returned PASS: verified the recursive `reduce` genuinely terminates (traced the pigeonhole argument — every successful recursive call strictly shrinks the summary count, or the no-progress guard fires), confirmed the two new tests are not tautological/circular, confirmed `binPack` refactor didn't change `chunk(_:maxTokens:)`'s prior behavior (all existing chunk-dependent tests still pass), and ran a fresh build+test itself (464 tests, 0 failures).

    One trivial non-blocking observation from round 2: the no-progress guard's doc comment described its trigger condition ("every summary already at or over maxChunkTokens") more narrowly than reality (it also fires when several under-ceiling summaries just don't pair up under the ceiling). Fixed the wording in Summarization.swift's `reduce` doc comment to describe the actual trigger condition accurately — no logic change.

    Final verification (fresh, this message): `swift build` → Build complete. `swift test` → Test run with 464 tests in 50 suites passed, 0 failures (16 gated real-model integration tests correctly skipped, unrelated to this change, consistent with every prior compaction task).

    Task is done and green. Leaving in `doing` for `/review`.
  timestamp: 2026-07-23T21:20:17.733611+00:00
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
- 01KXTFSH9RM2WAYMXD9VVJFKFB
position_column: doing
position_ordinal: '80'
title: Summarization stage + CompactionPrompt.default
---
## What
Add the model-assisted final stage (compaction_plan.md §1.3 stage 3, §2) in `Sources/FoundationModelsRouter/Compaction/`:

- `CompactionPrompt.swift` — `public struct CompactionPrompt: Sendable { var name: String; var text: String; static let `default`: CompactionPrompt }`. The default's text is the researched prompt in compaction_plan.md §2, verbatim (7 numbered sections: Intent / Constraints & decisions / Completed / In progress / Files & code / Errors & fixes / Next steps; security-relevant instructions preserved VERBATIM; no padding). Default name e.g. "router-default-v1" so evals can attribute quality by name. (This task owns the `CompactionPrompt` type — the model-free pipeline task deliberately has no prompt parameter.)
- `Summarization.swift` — renders the folded span to text, summarizes it with the compaction prompt via an injected summarizer model (default: the session's own model; profile `flash` slot as documented override), synthesizes the summary entry carrying the text segment + `CompactionSegment` (live-window entry ids, folded ids, tokens before/after, stages, prompt name). Long spans summarize in chunks then summarize the summaries (map-reduce) so the summarizer never overflows its own context.
- Extend `Compactor.compact` to `compact(_ transcript: Transcript, prompt: CompactionPrompt = .default, budget: TokenBudget)` (adding the prompt parameter the model-free skeleton omitted) and wire the stage in as the last stage; `CompactionResult.summary` carries the summary text.

## Acceptance Criteria
- [x] Summary entry carries text segment + fully-populated `CompactionSegment`
- [x] Map-reduce: a folded span exceeding the summarizer's budget is chunked, chunk summaries are re-summarized, and the final summary is a single entry
- [x] Custom `CompactionPrompt` is used verbatim and its `name` lands in the segment; `.default` matches §2 text
- [x] No summarizer available → pipeline degrades to the deterministic stages (model-free fallback)

## Tests
- [x] `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` — scripted/fake summarizer model returns canned summaries; asserts chunking boundaries, prompt assembly (default and custom), segment contents, fallback path
- [x] `swift test --filter SummarizationStage` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
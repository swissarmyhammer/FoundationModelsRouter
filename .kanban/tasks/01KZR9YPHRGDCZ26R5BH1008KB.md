---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kztwj7evh5ps26dcc6fj8jse
  text: |-
    ### implement — research

    Findings from the code:

    - `Compactor.compact` has three exits. The deterministic exit (a stage lands under target) returns the folded transcript with no boundary entry. Only `Summarization.apply` makes a boundary entry (a `.response` with a text segment and a `.custom(CompactionSegment)`).
    - `RoutedSessionActor.fold` records new entries with `TranscriptDiffer.diffByEntryId`. `ToolOutputElision` rewrites segments under the entry's original id, and `TurnTruncation` removes entries. Thus a deterministic-only fold shows zero new ids and records nothing. This confirms the problem statement.
    - `TranscriptTree.restoredUsageState` tier 2 reads `checkpoint.content.tokensAfter` directly as a measured number. `fold` writes `usageState` from `foldedUsage(tokensBefore:tokensAfter:)`, which rescales the pipeline estimate onto the measured scale. To make restored `contextFill` equal the live post-fold fill, the new checkpoint must carry that same rescaled number.

    Plan:

    1. In `fold` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift), after an applied fold with `result.summaryEntryId == nil`, synthesize one boundary entry: a `.response` with one empty text segment, an optional pending-runs text segment (same shape as `Summarization`), and a `.custom(CompactionSegment)`. Append it to the folded transcript before the id-diff, the backend swap, and the `persistedEntryCount` update. The manifest carries the fold's measured `tokensBefore`/`tokensAfter` (the `foldedUsage` rescale), the folded ids (ids present before the fold and absent after), and `liveWindowEntryIds` = folded entry ids plus the boundary's own id.
    2. The `Summarization` path stays unchanged. Its checkpoint still carries the pipeline estimate — a pre-existing condition outside this card's acceptance.
    3. The recording schema does not change: the boundary entry is one more `.response` event of the existing shape. This stays inside the v2 additive rule.
    4. Tests go in RoutedSessionCompactTests: (a) a deterministic-only fold records exactly one new event with a decodable checkpoint; (b) a restore of that session seeds the post-fold live window and restores the post-fold `contextFill`. Acceptance point 3 (a no-op fold records nothing) is already pinned by `compactWithNothingToFoldReturnsUnchanged`.

    Note: the bare-session recipe (`RecordingLanguageModel.noteCompaction`) has the same gap for deterministic-only folds, but it has no measured usage to carry. That path is out of this card's scope. `promptName` on the deterministic checkpoint is set to the empty string because no summarizer read a prompt.
  timestamp: 2026-08-12T11:43:46.139198+00:00
- actor: claude-code
  id: 01kztyd7fn3qre7hk5xscvn4ya
  text: |-
    ### implement — what landed

    TDD sequence: two new tests went in first and failed for the correct reasons (no new recorded event after a deterministic-only fold; a restore rebuilt the full 12-entry pre-fold history). The fix then made them pass.

    Changes:

    1. Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift
       - `fold` now computes the measured post-fold size (`foldedUsage` rescale) before it mutates `usageState`.
       - When an applied fold has `result.summaryEntryId == nil` (deterministic-only), `fold` appends one synthesized boundary entry to the folded transcript: a `.response` with one empty text segment, an optional pending-runs text segment (same shape as `Summarization`), and the `.custom(CompactionSegment)` manifest. The manifest carries measured-scale `tokensBefore`/`tokensAfter`, the stage names, the folded entry ids (pre-fold ids absent from the live window), and `liveWindowEntryIds` that name the boundary itself last. `promptName` is the empty string because no summarizer read a prompt.
       - The id-diff, the backend swap, and `persistedEntryCount` all use the transcript with the boundary included, so the live model context equals what a restore rebuilds from the checkpoint.
       - The `Summarization` path is unchanged. Its checkpoint still carries the pipeline estimates — a pre-existing condition outside this card's acceptance.

    2. Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift
       - New test: a deterministic-only fold records exactly one new entry with a decodable checkpoint, on the measured scale, and the prior events stay untouched.
       - New test: a restore of that session seeds the post-fold live window plus the boundary — not the pre-fold history — and the restored `contextFill` equals the live post-fold value.
       - Fixture updates: `makeRouter` accepts an optional router id and recordings directory; the stub container also tracks the backend it vends from `makeSession(transcript:)`.
       - Acceptance point 3 (a no-op fold records nothing) was already pinned by `compactWithNothingToFoldReturnsUnchanged`, which still passes.

    3. Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift — comment text only. Two doc comments said a deterministic-stop fold records no checkpoint; that statement is now false, so they were corrected. No gating change, no run.

    Schema note: the recording schema does not change. The boundary is one more `.response` event of the existing entry shape, so this stays inside the v2 additive rule.

    Discovered follow-up: `RecordingLanguageModel.noteCompaction` (the bare-session recipe) has the same gap for deterministic-only folds. Filed as its own task.
  timestamp: 2026-08-12T12:15:59.477571+00:00
- actor: claude-code
  id: 01kztydqv0m72ftm1v2v8c5dx7
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift (comments only). Verification: one ungated `swift test` run — 881 tests in 82 suites passed (1 known issue: the accepted BoundedWait one), 27 ungated integration-target tests passed, 24 eval tests passed, 0 failures. The only warning is the accepted mlx-swift "missing creator" noise.
    - next: /review
  timestamp: 2026-08-12T12:16:16.224789+00:00
- actor: claude-code
  id: 01kztyth5vbnmm4tq3reprm1q7
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 1 finding confirmed, 0 refuted. Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:518 — extract the shared boundary-entry construction that `appendingDeterministicBoundary` and `Summarization::makeSummaryEntry` each contain.
    - next: implement the fix for the open finding, then run the review again.
  timestamp: 2026-08-12T12:23:15.387096+00:00
- actor: claude-code
  id: 01kztyvfmkm6m5afbmc3dv1thw
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files, every applied fold now leaves a checkpoint boundary entry
    - test: green — swift test, 881 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 78338d0
    - review: findings — Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:518 (appendingDeterministicBoundary duplicates the boundary-entry creation in Summarization's makeSummaryEntry; extract a shared helper parameterized by summary content)
  timestamp: 2026-08-12T12:23:46.579703+00:00
- actor: claude-code
  id: 01kzv0pnf6awjhpf0ky0ncam8r
  text: |-
    ### implement iteration 2 — the review finding is repaired

    The finding: `appendingDeterministicBoundary` and `Summarization`'s `makeSummaryEntry` each made the same boundary entry by hand.

    What changed:

    1. Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift — a new internal static function, `CompactionSegment.boundaryEntry(id:summaryText:content:)`, now makes the boundary entry. It makes a `.response` entry with the summary text segment, the optional pending-runs text segment (only when `content.pendingRuns` is not nil), and the `.custom` manifest segment. The `renderedPendingRuns` doc note now names this function as its caller.
    2. Sources/FoundationModelsRouter/Compaction/Summarization.swift — `makeSummaryEntry` now calls the shared function with the synthesized summary text. The unused segment-id locals are removed.
    3. Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift — `appendingDeterministicBoundary` now calls the shared function with an empty summary text. Each call site keeps its own `CompactionSegment.Content` values; the content is the parameter that makes the two paths different.

    Sweep: a search for `.custom(CompactionSegment` and for the boundary entry-id prefixes found only the two sites. No third site makes a boundary entry by hand.

    Behavior is not changed. The segment ids, the segment order, and the entry shape are the same as before. The two checkpoint tests pass unchanged.
  timestamp: 2026-08-12T12:56:05.862790+00:00
- actor: claude-code
  id: 01kzv0pz0svcf682s0jkqebt28
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift, Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift. Verification: `swift build --build-tests` clean, then one ungated `swift test` run — 881 tests in 82 suites passed (1 known issue: the accepted BoundedWait one), 27 integration-target tests passed, 24 eval tests passed, 0 failures, exit 0. The only warning is the accepted mlx-swift "missing creator" noise. The finding in the description is now `- [x]`; tags re-supplied and verified as ["transcript"].
    - next: /review
  timestamp: 2026-08-12T12:56:15.641224+00:00
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: doing
position_ordinal: '8180'
title: Compaction appends a checkpoint entry on every applied fold
---
## Design rule

Compaction is append-only. A fold appends exactly one boundary entry to the conversation history. It does not change the history, and it does not change the history's entry count. A fold only changes what the engine puts into the model context from that point. The engine rebuilds context "from" the newest checkpoint. The UI treats the boundary entry as one more normal entry (the projection already has a `.compaction` row kind; the cold-seed task ^5aky6xr maps `CompactionSegment` to that row).

## Problem

Today a fold that lands under budget with only the deterministic stages (`ToolOutputElision`, `TurnTruncation`) records nothing at all. Elision rewrites segments under the entry's original id, so the id-diff sees zero new entries (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:399-417). No `CompactionSegment` checkpoint reaches disk. Nothing logs. On restore, `newestCompactionCheckpoint` finds nothing (Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:145-147), so the restored session gets its entire pre-fold history back — folded turns and full un-elided tool outputs included. The restored context is larger than the live one was at save time. `restoredUsageState` also falls back to a pre-fold stamp, so `contextFill` restores wrong.

The tests steer around this shape on purpose: `RoutedSessionCompactTests.swift:190` and `:250` hit it but never inspect the recorder, and `CompactionRoundTripIntegrationTests.swift:428-433` pins `stagesApplied` to end in summarization to avoid it.

## Proposed solution

1. Make every applied fold append one boundary entry that carries the `CompactionSegment` manifest (`liveWindowEntryIds`, token counts, stage names) — with or without a summarizer, and with or without new summary text. A deterministic-only fold appends a boundary entry whose text part is empty or minimal.
2. Record that entry through the normal recording path, so the checkpoint always reaches disk when a fold applied.
3. Carry the fold's measured usage/fill on the checkpoint, so `restoredUsageState` reads the post-fold numbers instead of a pre-fold stamp.
4. Keep the backend swap: seeding the model with the folded transcript is exactly "what we put into the context." The history and its count stay untouched (see task on history coordinates).

## Acceptance

- Fold a live session with a target the deterministic stages alone land under. Assert: exactly one new recorded entry, carrying a decodable `CompactionSegment` checkpoint.
- Restore that session. Assert: the restored live transcript equals the post-fold live window, not the pre-fold history, and `contextFill` matches the post-fold measurement.
- A fold that changes nothing (already under target) still records nothing — pin that too.

## Review Findings (2026-08-12 07:17)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:518` — The new function `appendingDeterministicBoundary` reimplements boundary-entry creation logic that already exists in `Summarization::makeSummaryEntry`. Both construct response entries with text segments and CompactionSegment manifests, differing only in summary content. The shared structure should be extracted into a parameterized helper or Summarization should be extended to handle both deterministic and model-assisted boundaries. Extract the common boundary-entry-creation logic into a shared helper function parameterized by summary content (empty for deterministic, actual summary for model-assisted). Alternatively, refactor Summarization::makeSummaryEntry to accept an optional summary parameter, allowing both code paths to call a single entry-construction function. #transcript
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzv9hxcpg8fwpwn3tdhkaxdz
  text: |-
    Research results:
    - `RecordingLanguageModelState.noteCompaction(_:)` (Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift) diffs by entry id through `diffAndRecordCompaction`. A deterministic-only fold adds no new entry ids, so the diff records nothing.
    - The session path (task ^h1008kb) solves this in `RoutedSessionActorCompaction.appendingDeterministicBoundary`: it makes one boundary entry with `CompactionSegment.boundaryEntry(id:summaryText:content:)`, an empty summary, an empty prompt name, and `pendingRuns` nil when there are none.
    - `CompactionResult` carries `summaryEntryId`, `tokensBefore`/`tokensAfter` (estimates), and `stagesApplied`. `summaryEntryId == nil` with `stagesApplied` not empty identifies a deterministic-only applied fold.
    - Plan: add a public overload `noteCompaction(_ compacted:result:) async -> Transcript` on `RecordingLanguageModel`. The overload returns the applied transcript (compacted plus the boundary) so the caller can seed the rebuilt session with it. The old method stays unchanged — the change is additive. Hoist the shared deterministic-boundary construction and the empty prompt-name constant into `CompactionSegment`, and make the session path call the same construction, so no near-copy helper exists.
    - Tests: extend Tests/FoundationModelsRouterTests/NoteCompactionTests.swift. Use a 6-turn fixture, `deterministicFoldBudget(for:)` from the shared fold fixtures, and a real `Compactor.compact` run with no summarizer. Assert one new recorded event with a checkpoint that `TranscriptTree.newestCompactionCheckpoint` finds and decodes; assert a no-op result records nothing.
  timestamp: 2026-08-12T15:30:47.318973+00:00
- actor: claude-code
  id: 01kzvaf0v234v5jk2sdbx5mj0t
  text: |-
    Implementation is complete (TDD, red first):
    - RED: two new tests in Tests/FoundationModelsRouterTests/NoteCompactionTests.swift did not compile — "extra argument 'result' in call" — because the overload did not exist. GREEN after the change.
    - New public API (additive): `RecordingLanguageModel.noteCompaction(_ compacted:result:) async -> Transcript`. When `result.summaryEntryId == nil` and `result.stagesApplied` is not empty, the method synthesizes one boundary entry and records it with the id-diff. The method returns the applied transcript (compacted plus boundary), and the caller seeds the rebuilt session with it. A summarized fold and a no-op result record exactly as before. The old `noteCompaction(_:)` is unchanged; its docs now point to the new overload for deterministic-only folds.
    - One shared construction: `CompactionSegment.appendingDeterministicBoundary(to:preFoldEntryIds:tokensBefore:tokensAfter:stagesApplied:pendingRuns:)` (plus `CompactionSegment.deterministicFoldPromptName`) now holds the deterministic-boundary build on top of `boundaryEntry(id:summaryText:content:)`. Both fold paths call it: `RoutedSessionActorCompaction.appendingDeterministicBoundary` is now a thin delegation, and the bare-recipe path calls it with the pipeline's ESTIMATED token counts (`result.tokensBefore`/`tokensAfter` — the bare recipe has no measured usage) and `pendingRuns: nil` (no mailbox below the session). No third hand-built boundary exists.
    - The handle's `lastSeen` (the pre-fold transcript, read inside the generation gate) names `foldedEntryIds`. The boundary entry id keeps the `compaction-boundary-<UUID>` transcript-entry id space; `CompactionResult.id` (a ULID) is never stamped into an entry-id field.
    - Tests assert: exactly one new recorded event; `TranscriptTree.newestCompactionCheckpoint` finds and decodes it; stages/token estimates/empty prompt name/nil pendingRuns; live window = folded ids + boundary id (boundary last); folded ids = the dropped pre-fold ids. The no-op test runs the real pipeline under a large budget and asserts zero new events and an unchanged transcript.
    - Test fixture: `makeTwoTurnFixture` became `makeFixture(turnCount:)` so a six-turn history can force a real `TurnTruncation` fold through the shared `deterministicFoldBudget(for:)` helper. All five old call sites updated.
    - Note: the board tooling also modified .kanban/tasks/01KZR9Z6QH9WVXVSX9T6Z1MSG1.* in the working tree; this task did not touch that card.
  timestamp: 2026-08-12T15:46:41.122535+00:00
- actor: claude-code
  id: 01kzvafcqmg0sev0ahf0fz7wj6
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift, Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/NoteCompactionTests.swift. `swift build --build-tests` clean (zero errors, zero warnings). One ungated `swift test` run: 886 + 27 + 24 tests passed across the three test products, zero failures (the one "known issue" is the pre-existing deliberate `withKnownIssue` in the BoundedWait suite). Both acceptance tests pass.
    - next: run /review; the task stays in doing.
  timestamp: 2026-08-12T15:46:53.300822+00:00
position_column: doing
position_ordinal: '8180'
title: noteCompaction records no checkpoint for a deterministic-only fold
---
## Problem

Task ^h1008kb makes the session fold path (`RoutedSessionActor.fold`) append one boundary entry for a deterministic-only fold, so the `CompactionSegment` checkpoint always reaches disk. The bare-session recipe has the same gap: `RecordingLanguageModel.noteCompaction(_:)` diffs the compacted transcript by entry id. A caller who runs `Compactor.compact` without a summarizer, and whose fold lands with only `ToolOutputElision`/`TurnTruncation`, hands `noteCompaction` a transcript with no new entry ids. The diff records nothing, and `newestCompactionCheckpoint` finds nothing on restore.

## Constraints

- The bare recipe has no session and no measured usage. The checkpoint can only carry the pipeline's estimated token counts.
- Keep the recording schema inside the v2 additive rule.

## Acceptance

- A deterministic-only fold noted through `noteCompaction` records exactly one new entry with a decodable `CompactionSegment` checkpoint.
- A no-op transcript (identical to what was already recorded) still records nothing. #transcript
---
assignees:
- claude-code
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: todo
position_ordinal: '9180'
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
- A fold that changes nothing (already under target) still records nothing — pin that too. #transcript
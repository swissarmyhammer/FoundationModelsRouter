---
assignees:
- claude-code
position_column: todo
position_ordinal: a380
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
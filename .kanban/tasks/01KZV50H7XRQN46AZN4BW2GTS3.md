---
assignees:
- claude-code
position_column: todo
position_ordinal: a480
title: Record the resume-handle cut in append-only history coordinates
---
## Problem

Task ^6z1msg1 corrected the fork cut for `RoutedSessionActor`: a new fork writes `forkedAtHistoryOrdinal`, the cut in the recorded history's append-only coordinates. The resume-handle path does not write this field. `RoutedModel.makeLanguageModel(resuming:registry:)` (Sources/FoundationModelsRouter/RoutedLLM.swift, the `forkedAtEntryCount: restoredTranscript.count` argument) records the reconstructed transcript count. That count comes from the checkpoint-filtered restore view. When the resumed session was compacted, that count is smaller than the raw effective entry-event count. A reader that applies it as a prefix of the parent's raw events then selects the oldest pre-fold span, the same defect ^6z1msg1 removed for actor forks.

## Proposed solution

1. In `makeLanguageModel(resuming:)`, compute the raw effective entry-event count for the resumed session (`tree.effectiveEntryEvents(forSession:).count`).
2. Add a `forkedAtHistoryOrdinal` parameter to `RecordingLanguageModel` and thread it to `writeSidecarIfNeeded`, which now passes `nil` (see the comment in `RecordingLanguageModel.writeSidecarIfNeeded`).
3. Write both fields, as the actor fork path does.

## Acceptance

- Test: resume a compacted session with `makeLanguageModel(resuming:)`, drive a turn, then reconstruct the handle's effective transcript. Assert the result equals the checkpoint's live window plus the handle's own entries, with no pre-fold span.
- Old recordings without the field keep the current fallback behavior. #transcript
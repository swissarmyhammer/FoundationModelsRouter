---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37m4svg5t74yw1z35akzwpz
  text: |-
    ### implement — research and the fix chosen
    - Cause: the snapshot is the instructions, then the summary entry (`CompactionSegment.boundaryEntry`), then the protected entries. The summary entry is a `.response`. The MLX `TranscriptConverter` (mlx-swift-lm, MLXFoundationModels) renders a `.response` as an assistant message; `TranscriptChatMessages` does the same for the count. So the model sees: system, assistant("<summary>"), user("Which port ...?"). The model did not write that assistant turn, and no user turn comes before it. The model does not read it as context about this user, and answers from general knowledge.
    - The converter is in the package dependency. The router cannot change how a role renders. The router can only choose the entry kind.
    - Choice: the summary entry becomes a `.prompt` (user role). Its text starts with a header text segment "Summary of the conversation so far:" (id `<entryId>-header`), then the summary text segment (id `<entryId>-text`), the pending-runs text, and the `CompactionSegment` checkpoint (`.structure`, which the converter does not render). The id, the checkpoint and the live-window ids do not change.
    - Why not the instructions entry: the restore rebuilds the live window from recorded entry ids. The instructions entry is recorded once, before the compaction. A changed instructions entry with the same id restores without the summary; a new id changes the recorded history and every "instructions come first" rule. The user-role entry keeps the checkpoint, the restore and the recorded history as they are: the recorder, the mapper and `TranscriptReconstruction` read any entry kind, and a `.prompt` round-trips its segments.
    - The places that read the boundary as a `.response` now accept a `.prompt` too, and still read an old `.response` checkpoint: `CompactionSegment.restatingSizes`, `SessionProjection.compactionRow`, `SessionProjection.transcriptRows` and `supersededTextEntryIds` (a boundary prompt is a compaction row, not a turn start).
    - Every compaction path appends a new prompt after the snapshot (turn start: the turn prompt; inside a turn: `compactionContinuationPrompt`), so the model never generates right after the boundary prompt.
  timestamp: 2026-09-23T17:13:50.704753+00:00
- actor: claude-code
  id: 01m37n3qsbp9qe0axnazdvxe3f
  text: |-
    ### implement — changed
    - Cause: the summary entry was a `.response`. The MLX `TranscriptConverter` renders it as an assistant message with no user message before it. The model did not read it as context.
    - Fix (chosen): the summary entry (`CompactionSegment.boundaryEntry`) is now a `.prompt` (user role). Its text segments: `CompactionSegment.summaryHeader` ("Summary of the conversation so far:", id `<entryId>-header`), the summary (id `<entryId>-text`), the pending-runs text. The checkpoint `.structure` segment does not change. Reason: the router cannot change the converter; it can choose the entry kind. The instructions option breaks the restore (the instructions entry is recorded once, before the compaction).
    - Readers of the checkpoint accept `.prompt` and still read an old `.response` checkpoint: `TranscriptTree.compactionSegmentContent` (restore), `CompactionSegment.restatingSizes`, `SessionProjection.compactionRow`, `transcriptRows` and `supersededTextEntryIds` (a boundary prompt is a compaction row, not a turn start). The summary of a row is the `<entryId>-text` segment, so the header is not in it.
    - Files: Sources/.../Compaction/CompactionSegment.swift, Compaction/Summarization.swift (doc), Recording/TranscriptReconstruction.swift, Session/SessionProjection.swift; Tests/.../CompactionSummaryRoleTests.swift (new: user role with the header, cold row, restated sizes), Helpers/CompactionFixtures.swift (`summaryEntrySegments`, `summaryEntryTexts`), OneCallCompactionTests.swift, RoutedSessionCompactTests.swift; IntegrationTests Qwen38CompactionIntegrationTests.swift and Qwen38ToolResultCompactionIntegrationTests.swift (`expectOneCompactionAndAnAnswer(_:holding:)`: the answer must hold "6543" in case 3 and "KESTREL-42" in case 2).
    - No number added in `Sources/`.

    ### test — green
    - `swift test`: 1330 tests in 150 suites passed (2 designed known issues), 1 test passed, 19 tests passed. `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - `swift test --package-path IntegrationTests --filter Qwen38CompactionIntegrationTests`: 3 of 3 pass. Model load 2.7 s. Case 1 5.9 s (load included), summary keeps "Key value: Port `6543`". Case 3 7.1 s, compaction 334 -> 74, answer "The staging database listens on port 6543." Case 2 16.6 s, compaction 919 -> 353, answer "The returned record key is KESTREL-42." Suite 29.6 s.
  timestamp: 2026-09-23T17:30:44.395106+00:00
position_column: doing
position_ordinal: '80'
title: After a turn-start compaction, Qwen3.8-27B does not use the summary to answer
---
## Finding (from ^yyjvyga, 2026-09-23)

In the gated test "a long context compacts" (`Qwen38CompactionIntegrationTests`), a seeded context compacts before the turn. The summary keeps the fact: "Key value: Port 6543." The turn prompt asks "Which port does the staging database listen on?". The model answers: "I do not have access to your specific infrastructure configuration, so I cannot tell you which port your staging database listens on."

The test passes, because it asserts only that the answer is not empty.

## Do this

1. Find how the summary entry reaches the model after a compaction (the entry type, the chat template role, the text around the summary).
2. Find why the model does not treat the summary as its own context.
3. Fix the cause, and add an assertion to the gated test that the answer holds "6543".

#compaction
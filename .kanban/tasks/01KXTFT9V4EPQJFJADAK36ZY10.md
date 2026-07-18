---
assignees:
- claude-code
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
position_column: todo
position_ordinal: '8680'
title: 'noteCompaction on RecordingLanguageModel: append-only fold recording'
---
## What
Add `public func noteCompaction(_ compacted: Transcript)` to `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` (compaction_plan.md §1.5 bare-session path, §3):

- The handle's differ is count-based append-only. `noteCompaction` appends the *never-before-recorded* entries of the compacted transcript to that session's `transcript.jsonl` — unseen-ness is a set lookup by `Transcript.Entry.id` (payloads already carry `entryId` via `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`). This is how the synthesized summary entry (with its `CompactionSegment`) reaches disk.
- Resets the differ baseline (`Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift` state held by the handle) so post-fold turns record as ordinary appends: retained tail entries keep their entry ids, so they are recognized as already recorded — no divergence, no double-recording.
- Recording stays append-only: nothing before the fold is touched (requirement 2); session id unchanged on every event (requirement 4).
- Document the caller contract: after `noteCompaction`, rebuild `LanguageModelSession(model: same handle, tools:, transcript: compacted)`.

## Acceptance Criteria
- [ ] `noteCompaction` appends exactly the unseen entries (the summary entry; nothing retained is re-written) and resets the baseline
- [ ] Subsequent turns after the fold record as normal appends with no duplicated events
- [ ] All pre-fold events remain intact in `transcript.jsonl`; session id identical on every event

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift` or add `NoteCompactionTests.swift`: compact a fixture transcript, call `noteCompaction`, assert exact-append semantics, baseline reset (drive a follow-up turn via the existing handle test harness), pre-fold events untouched, repeated compactions
- [ ] `swift test --filter 'RecordingLanguageModel|NoteCompaction'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
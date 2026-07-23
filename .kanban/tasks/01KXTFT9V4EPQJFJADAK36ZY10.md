---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky805epk2bcytvwt6heh2me9
  text: 'Research done. Confirmed Transcript.Entry.id is a public String (Identifiable) via the installed macOS 27 SDK''s FoundationModels.swiftinterface. Wrote Tests/FoundationModelsRouterTests/NoteCompactionTests.swift first (TDD): 6 tests covering exact-append semantics, pre-fold-untouched, baseline reset (follow-up turn), idempotent repeat, and nested (second, later) compaction. Confirmed RED: swift build --build-tests fails with "value of type ''RecordingLanguageModel'' has no member ''noteCompaction''" — the expected failure. Now implementing: TranscriptDiffer.diffByEntryId(...) (set-based diff by Transcript.Entry.id, sharing a factored-out `partial(for:...)` helper with the existing positional diff), plus RecordingLanguageModelState.noteCompaction(_:) / RecordingLanguageModel.noteCompaction(_:) which append only never-before-seen entries and unconditionally reset lastSeen (no shrink-guard, since a fold is expected to be shorter).'
  timestamp: 2026-07-23T17:25:25.843875+00:00
- actor: claude-code
  id: 01ky80kad4644p891z4jrgxvrw
  text: |-
    Implementation landed, GREEN. Changes:
    - Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift: added `diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)` (set-based diff by Transcript.Entry.id), factored a shared `partial(for:...)` helper reused by both the existing positional `diff` and the new `diffByEntryId`.
    - Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift: added public `RecordingLanguageModel.noteCompaction(_:)`, actor method `RecordingLanguageModelState.noteCompaction(_:)` (sidecar + gate + session-meta, same chokepoint shape as sync/generate), and private `diffAndRecordCompaction(compacted:)` which appends only never-before-seen entries and unconditionally resets `lastSeen` (deliberately no shrink-guard — a fold is expected to be shorter, unlike diffAndRecord's anomaly-guard).
    - Tests/FoundationModelsRouterTests/NoteCompactionTests.swift: 5 new tests (TDD — confirmed RED via real compile failure first) covering exact-append semantics + CompactionSegment round-trip, pre-fold-untouched, baseline reset via a real follow-up turn over the same handle, idempotent repeat, and a second/nested later compaction.

    Verification (fresh, this session): `swift build` clean (only the known pre-existing mlx-swift_Cmlx.bundle warning), `swift build --build-tests` clean, `swift test`: 434 tests in 47 suites passed, 16 gated/skipped in 6 suites — exactly baseline (429/46) + 5 new tests in 1 new suite. Targeted reruns of TranscriptDifferTests/RecordingLanguageModelTests/RecordingHandleResumeTests/CompactionSegmentTests/CompactionSpikeTests/TranscriptEntryMapperTests/SessionSidecarTests/TokenBudgetTests/TokenUsageMeteringTests also all green (96/96).

    Dispatched the really-done adversarial double-check agent on this diff; awaiting its verdict before final handoff. Leaving task in doing per /implement contract (not moving to review myself).
  timestamp: 2026-07-23T17:33:00.196130+00:00
- actor: claude-code
  id: 01ky80t3jrz98yb979g51k8fn8
  text: |-
    really-done adversarial double-check: PASS, no findings. Verified gate handling matches sync/enterGateAndDiff's shape exactly (single acquire/release, no throwing work in between), confirmed the diff/diffByEntryId `partial(for:...)` refactor is a byte-identical extraction (no behavior change to the existing positional differ), confirmed the unconditional lastSeen reset is intentional (a fold is expected to shrink) and validated end-to-end via the nested-compaction test, and confirmed the new tests are discriminating (would fail under a positional-diff implementation) rather than passing by construction. Independently reran swift test: 434/47 passed, 16 gated/6 skipped — matches baseline.

    All acceptance criteria and Tests checkboxes checked off. Task left in `doing`, ready for /review.
  timestamp: 2026-07-23T17:36:42.584948+00:00
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
position_column: doing
position_ordinal: '80'
title: 'noteCompaction on RecordingLanguageModel: append-only fold recording'
---
## What
Add `public func noteCompaction(_ compacted: Transcript)` to `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` (compaction_plan.md §1.5 bare-session path, §3):

- The handle's differ is count-based append-only. `noteCompaction` appends the *never-before-recorded* entries of the compacted transcript to that session's `transcript.jsonl` — unseen-ness is a set lookup by `Transcript.Entry.id` (payloads already carry `entryId` via `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`). This is how the synthesized summary entry (with its `CompactionSegment`) reaches disk.
- Resets the differ baseline (`Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift` state held by the handle) so post-fold turns record as ordinary appends: retained tail entries keep their entry ids, so they are recognized as already recorded — no divergence, no double-recording.
- Recording stays append-only: nothing before the fold is touched (requirement 2); session id unchanged on every event (requirement 4).
- Document the caller contract: after `noteCompaction`, rebuild `LanguageModelSession(model: same handle, tools:, transcript: compacted)`.

## Acceptance Criteria
- [x] `noteCompaction` appends exactly the unseen entries (the summary entry; nothing retained is re-written) and resets the baseline
- [x] Subsequent turns after the fold record as normal appends with no duplicated events
- [x] All pre-fold events remain intact in `transcript.jsonl`; session id identical on every event

## Tests
- [x] Extend `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift` or add `NoteCompactionTests.swift`: compact a fixture transcript, call `noteCompaction`, assert exact-append semantics, baseline reset (drive a follow-up turn via the existing handle test harness), pre-fold events untouched, repeated compactions
- [x] `swift test --filter 'RecordingLanguageModel|NoteCompaction'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
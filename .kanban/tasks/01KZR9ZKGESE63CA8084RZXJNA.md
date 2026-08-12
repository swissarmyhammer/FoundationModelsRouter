---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzw0t9kcnmtpaj7jvt9nvvnn
  text: |-
    Research complete. Findings and decisions:

    - There are two diff call paths. The session path is `RoutedSessionActor.recordTranscriptDelta` (RoutedSessionActorRecording.swift). The handle path is `RecordingLanguageModelState.diffAndRecord` (RecordingLanguageModel.swift). The shared detection will go into `TranscriptDiffer`. Each path will call it before its positional diff.
    - The session path keeps only a count (`persistedEntryCount`). It reads its "last seen" prefix from the CURRENT backend transcript, so an id check there is empty without new state. Decision: add `persistedBaseline` (the recorded prefix ids plus the boundary entry's mapped payload) to `RoutedSessionActor`. It starts as nil and is set after each successful diff and after each compaction fold.
    - Decision on the loud signal: a warning log PLUS a recorded marker event, not a thrown error. The two chokepoints are non-throwing and run on the success exit and the throwing exit of each turn. A thrown error would change turn semantics widely. The marker is a new `TranscriptEvent.Kind` case `divergence`. It is not entry-kind, so reconstruction and `historyOrdinal` do not see it.
    - Schema: the `divergence` kind lands within schema v2 by the same rule as the `unknown` carrier (task ^9n7fna4): this build writes it only when the SDK makes a non-append transcript change, which the current SDK does not do. The limit (an old v2 reader gets a decode error on such a recording) will be documented in `RecordingSchemaVersion.v2`.
    - Decision on shrink interaction: the shrink guard stays exactly as it is (log, drop, reset). After a shrink the count no longer names anything that was recorded, so `persistedBaseline` resets to nil and verification starts again at the next successful diff. This keeps TranscriptFidelityTests' pinned shrink tests green (their turn-3 entries are rebuilt with fresh ids).
    - Decision on the in-place rewrite probe: id match plus a payload equality probe at the boundary index only (the last recorded entry). A same-id rewrite deeper in the prefix stays undetected by design (cost scope from the card).
    - Decision on duplicate entry ids at restore: `TranscriptTree.restoreFilteredEvents` will log a warning with the id and both seq positions, and the NEWEST event wins. The newest event is the latest write for that id; the oldest is superseded content.
    - Test plan (red first): session-path rewrite test and mid-insert test in TranscriptFidelityTests (VariableLLMContainer), a handle-path rewrite test through `RecordingLanguageModel.sync`, and a direct `restoreFilteredEvents` duplicate-id test in TranscriptReconstructionTests with a log assertion. `UndrivenLanguageModel` moves from CompactionSegmentTests into a shared test helper; `assertLogged` moves from TranscriptEntryMapperTests into a shared test helper.
  timestamp: 2026-08-12T22:17:19.212304+00:00
- actor: claude-code
  id: 01kzw4y7z68vx7sn7bqtr7g6rb
  text: |-
    ### implement — changed
    - evidence: 15 code files changed (9 in Sources, 4 test files changed, 2 test helper files added). New shared detection: `TranscriptDiffer.Baseline` and `TranscriptDiffer.Divergence` with `divergence(from:in:)` / `divergence(lastSeen:current:)`. Both chokepoints guard before the positional diff: `RoutedSessionActor.recordTranscriptDelta` (with a new `persistedBaseline` state, reset at shrink/divergence/success/compaction) and `RecordingLanguageModelState.diffAndRecord`. The loud signal is a warning log plus one recorded `TranscriptEvent.Kind.divergence` marker event; the diff for that call is dropped and the baseline resets. Restore now resolves a duplicated entry id to the NEWEST event and logs the id with both seq positions (`TranscriptTree.restoreFilteredEvents`). Decisions are documented on `TranscriptDiffer.Divergence`, `restoreFilteredEvents`, and `RecordingSchemaVersion.v2` (the new kind lands within v2 by the unknown-carrier precedent). The shrink guard and its two pinned tests stay exactly as they were.
    - TDD: four new tests were red first (marker absent, tail duplicated, oldest duplicate won), then green: `inPlaceRewriteRecordsDivergenceMarkerAndRecovers`, `midTranscriptInsertionRecordsDivergenceMarkerWithoutDuplicatingTail`, `handleInPlaceRewriteRecordsDivergenceMarkerAndRecovers` (TranscriptFidelityTests), `duplicateEntryIdRestoresNewestEventAndLogs` (TranscriptReconstructionTests, with an OSLogStore log assertion). `assertLogged` moved to Tests/Helpers/LogAssertions.swift and `UndrivenLanguageModel(+Container)` moved to Tests/Helpers/UndrivenLanguageModel.swift for reuse.
    - test run: one ungated `swift test` — 900 + 27 + 24 = 951 tests, 84 + 11 + 5 suites, 0 failures, exit 0. The one "known issue" is the pre-existing deliberate `withKnownIssue` inside BoundedWait's own test. No new compiler warnings.
    - next: review (/review). The task stays in `doing`.
  timestamp: 2026-08-12T23:29:22.918602+00:00
depends_on:
- 01KZR9Z6QH9WVXVSX9T6Z1MSG1
position_column: doing
position_ordinal: '8180'
title: Make the transcript differ loud on non-append backend changes
---
## Problem

`TranscriptDiffer.diff` is purely positional: it records `current[lastSeen.count...]` and never looks at entry ids (Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift:41-53). Three SDK behaviors therefore corrupt the record with no signal:

1. **In-place rewrite at the same count**: the SDK edits entry k without changing the count. The diff is empty. The record keeps the stale content forever. No test.
2. **Mid-transcript insertion**: the count grows by n, but the new entries are not at the tail. The differ records the last n entries — the wrong ones. The record duplicates the tail, misses the inserted entries, and every later turn stays off by n. No warning. No test.
3. **Entry-id reuse**: restore resolves duplicate ids to the OLDEST event (`uniquingKeysWith: { first, _ in first }`, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:186-189), silently restoring the wrong content. No test.

(A transcript shrink IS caught, logged, and dropped — TranscriptFidelityTests.swift:393-452 pins that as intended.)

## Proposed solution

1. Verify, at the chokepoint, that the prefix of the backend transcript still matches what was recorded: compare the ids of `current[..<baseline]` against the recorded ids (cheap — ids only, no content). On mismatch, do not record a wrong diff. Emit a typed, loud signal: a warning log plus a recorded marker event (or a thrown typed error — decide which, and document it).
2. Optionally detect the in-place rewrite the same way (id match but a changed entry at the same position needs an equality probe on the suffix boundary only — scope this by cost).
3. On restore, make duplicate entry ids loud: log with the id and positions, and prefer the NEWEST event, or throw a typed error — decide, document, test.

## Acceptance

- A stub backend that rewrites an entry in place produces the loud signal and never silently persists a wrong diff.
- A stub backend that inserts mid-transcript produces the loud signal; the record does not duplicate the tail.
- A recording with a duplicated entry id restores loudly, with the documented winner.
- The existing shrink behavior and its test stay as they are. #transcript
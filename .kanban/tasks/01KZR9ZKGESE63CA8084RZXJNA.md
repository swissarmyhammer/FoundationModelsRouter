---
assignees:
- claude-code
depends_on:
- 01KZR9Z6QH9WVXVSX9T6Z1MSG1
position_column: todo
position_ordinal: '9380'
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
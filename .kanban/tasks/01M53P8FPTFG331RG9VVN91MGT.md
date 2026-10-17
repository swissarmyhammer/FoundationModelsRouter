---
assignees:
- claude-code
depends_on:
- 01M53FFKACCYMAKXPXKK8WKXJ2
position_column: todo
position_ordinal: '8580'
title: Use TranscriptSegmentFilter in MailRecordSegment.removingRecords
---
Source: review finding of ^k8wkxj2 (`duplication/duplication`, Sources/FoundationModelsRouter/Session/OperationEventSegment.swift). The finding says: "Switching MailRecordSegment.removingRecords to the same helper edits the counterpart, so report that as a separate task."

## What
`MailRecordSegment.removingRecords(from:)` in `Sources/FoundationModelsRouter/Session/MailRecordSegment.swift` has its own copy of the filter-and-rebuild shape: it guards on a `.prompt` entry, filters the segments by a predicate, gives the entry unchanged when it drops nothing, and makes the entry again from the kept segments. Task ^k8wkxj2 moved this shape into `TranscriptSegmentFilter.keptSegments(of:dropping:)` in `Sources/FoundationModelsRouter/Session/TranscriptSegmentFilter.swift`, and `OperationEventSegment.entryWithoutRelayedQuestions` uses it.

Change `removingRecords(from:)` to call `TranscriptSegmentFilter.keptSegments(of: prompt.segments, dropping:)` with the predicate "a `.structure` segment whose `schemaName` is `MailRecordSegment.schemaName`".

Difference to keep in mind: `keptSegments` gives `nil` when the read removes each segment. The current `removingRecords` keeps a `.prompt` entry with no segments in that case. `removingRecords` returns a `Transcript.Entry` (not optional), and `ContextRenderer.context(of:)` maps each entry through it. Keep the current behavior: when `keptSegments` gives `nil`, give a `.prompt` entry with the same id, options and response format, and no segments.

## Acceptance Criteria
- [ ] `removingRecords(from:)` has no filter of its own; it calls `TranscriptSegmentFilter.keptSegments(of:dropping:)`.
- [ ] A `.prompt` entry with mail records and text gives the same entry with the text only.
- [ ] A `.prompt` entry with only mail records gives a `.prompt` entry with the same id and no segments.
- [ ] Each entry that is not a `.prompt` entry stays as it is.

## Tests
- [ ] Add unit tests for the three cases above in a new `Tests/FoundationModelsRouterTests/MailRecordSegmentRemovalTests.swift` (write them first; the "only mail records" test must pass before and after the change).
- [ ] The existing check in `Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift` that maps `MailRecordSegment.removingRecords(from:)` stays green.
- [ ] Run `swift test` one time: 0 failures, 0 warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#elicitation-fixes
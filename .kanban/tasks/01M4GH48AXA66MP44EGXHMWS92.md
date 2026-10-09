---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4h888t2tsbcpm1m4aa93bg8
  text: |-
    Research:
    - The rule in Extras `ToolInvocationRecord.swift` says that no id goes into the field of the other id. It does not forbid an event that carries the two ids side by side. So this task needs no Extras change: `SessionEvent.toolInvocation` gets a second associated value, `toolCallID: String?`, and `ToolInvocationRecord.correlationID` stays the `completionToken`.
    - The SDK-keyed events (`toolCall`, `toolStatus`) come from the submission diff in `RoutedSessionActorRecording.recordTranscriptDelta`. That diff runs after the live open and close records, so the diff time is too late to put the id on a live event.
    - At an open record, the SDK waits in the tool call, and the live backend transcript already holds the `.toolCalls` entry. `takeGenerationCall` and the repetition watch read the transcript at that same moment. So `deliver(invocation:)` can read `unrecordedTranscriptEntries()`, find the first unjoined call with the same tool name, and join it.
    - Between answers, the unrecorded entries are empty, so a record that opens outside a submission gets `nil`.
    - Breaking change for the consumer: FoundationModelsACPAgent `EventProjection.swift` matches `.toolInvocation(let record)`. It must change to `.toolInvocation(let record, let toolCallID)`.
  timestamp: 2026-10-09T21:14:07.555+00:00
- actor: claude-code
  id: 01m4h8zhc1p3magv0kj1r7trse
  text: |-
    Implementation landed (not committed).

    Decision: no change to FoundationModelsExtras. The Extras rule forbids to put one id in the field of the other id. `ToolInvocationRecord.correlationID` stays the `completionToken`. The event `SessionEvent.toolInvocation` now has a second associated value, `toolCallID: String? = nil`, so the event carries the two ids side by side.

    Where the id comes from: `ToolCallOutputPairing` runs at the submission diff, which comes after the live open and close records. So the join runs at the open record instead. New type `ToolCallRunJoin` (Sources/FoundationModelsRouter/Session/ToolCallRunJoin.swift). In `RoutedSessionActor.deliver(invocation:)`, an open record reads `unrecordedTranscriptEntries()`. The SDK waits in the tool call at that time, and the `.toolCalls` entry is already there (the scripted tests prove it). The record joins the first call with the same tool name, no output, and no run yet. The close record gets the id of its open record and reads no entries. `InFlightTranscript.openCalls(in:)` became internal so that the join can use it.

    Known limit (documented on `ToolCallRunJoin`): the record has no arguments. When one round calls one tool two times and the SDK runs the calls at the same time, the open records can come in the other order, and the two runs can get each other's id.

    Event order: written on `SessionEvent.toolInvocation(_:toolCallID:)`: open record, close record, toolCallReport, then from the diff toolCall + running toolStatus, completed/failed toolStatus, then submissionEnded.

    Consumer impact: this is a source break for a pattern with one binding. FoundationModelsACPAgent `EventProjection.swift` has `case .toolInvocation(let record):` and must change to `case .toolInvocation(let record, let toolCallID):`.
  timestamp: 2026-10-09T21:26:49.985338+00:00
- actor: claude-code
  id: 01m4h8zy5vf9gkrw6t8rsjccsf
  text: |-
    ### implement — changed
    - evidence: 14 files. New: Sources/FoundationModelsRouter/Session/ToolCallRunJoin.swift, Tests/FoundationModelsRouterTests/ToolCallRunJoinTests.swift. Changed: Session/SessionEvent.swift, RoutedSessionActor.swift, RoutedSessionActorRunJournal.swift, CompactionYield.swift, SessionProjection.swift, SessionAnswer.swift, RoutedSession.swift, OperationEventJournal.swift; Tests ToolInvocationLivenessTests.swift, GenerationCallUsageTests.swift, QueuedPassStallWatchTests.swift, Helpers/SessionEventCollection.swift. RED: `swift test --filter ToolCallRunJoinTests` 7 issues (ids nil). GREEN: same filter 8/8 pass. Full `swift test`: 1563 tests in 196 suites pass (2 known issues that were there before), 23 tests in 11 suites pass, 19 tests in 3 suites pass. `swift build`: complete, no warning in Router sources.
    - next: /review
  timestamp: 2026-10-09T21:27:03.099188+00:00
- actor: claude-code
  id: 01m4h95ht0x8bcqb2fngj7n9t3
  text: |-
    ### test - green
    - evidence: swift build - Build complete, 0 Router warnings. swift test - 1563 tests in 196 suites passed, 0 failed, 0 skipped. Two more runs: 23 tests and 19 tests passed.
    - note: The build tool prints one warning, "missing creator for mutated node", for the mlx-swift_Cmlx bundle. It comes from SwiftPM and a dependency. It is not Router code.
    - note: Two known issues are expected. Two tests use withKnownIssue to prove that a stub records an issue. They existed before this task. They are not skips.
    - next: review
  timestamp: 2026-10-09T21:30:07.040294+00:00
- actor: claude-code
  id: 01m4h96aqrdr2grrxdxxncny69
  text: |-
    ### commit — changed
    - evidence: b9b5fdcd feat(session): join the SDK tool-call id with the run completion token (^xhmws92)
    - next: review
  timestamp: 2026-10-09T21:30:32.568880+00:00
position_column: doing
position_ordinal: '80'
title: Join the SDK tool-call id with the run completion token
---
## Problem

Router has two id spaces for one tool run, and no code joins them:

- `SessionEvent.toolCall` and `SessionEvent.toolStatus` carry the SDK `Transcript.ToolCall.id` (`SessionEvent.swift:31,36`).
- All events that a tool emits carry its `completionToken`.

`ToolInvocationRecord` says that you must not stamp one id into the other (`FoundationModelsExtras/.../OperationEvents/ToolInvocationRecord.swift:21-30`). Result: the ACP client shows one tool run as two tool calls.

## Work

1. When `ToolCallOutputPairing.swift` knows the SDK tool-call id, put that id on the open `ToolInvocationRecord`, or on `SessionEvent.toolInvocation`.
2. If the rule in `ToolInvocationRecord.swift:21-30` must change, coordinate with FoundationModelsExtras. Write down the reason for the change.
3. The SDK-keyed events arrive only after the submission transcript diff (`FoundationModelsACPAgent/plan.md:1174-1176`). Write down the event order that a consumer can expect.

## Tests

- For a tool that opens a run, the invocation event carries the same SDK id as the `toolCall` event.

## Consumer

FoundationModelsACPAgent uses this join to show one tool call for each tool run.

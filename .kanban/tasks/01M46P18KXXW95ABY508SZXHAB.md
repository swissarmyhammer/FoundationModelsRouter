---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m46qkssgzbmswm42qf2takwz
  text: |-
    Research and implementation notes.

    - RED: the new test `yieldedSubmissionEndsWithTheUsageOfItsAttempt` (ToolResultCompactionTests) failed before the fix. On a fresh session the yielded `submissionEnded` carried tokensIn 0 and tokensOut 0, not 700 and 10. The answer usage was 1 and 1, but the generation calls summed to 701 and 11. On a session with earlier usage, the value is negative.
    - The fix reuses the ^3anq1yz shape. `recordYieldedAttempt` reads the usage of the attempt and takes the generation call (`takeGenerationCall(leaving: .toolCall)`) before it replaces `backend`. The finish then gets a baseline that gives back the usage of the attempt, and it reports the call that was taken before the replace.
    - `WatchStopMeasure` is now `ReplacedBackendMeasure`, in the new file `RoutedSessionActorReplacedBackend.swift`, because the compaction yield uses it too. The finish parameter `watchStop:` is now `replacedBackend:`. The new shared helper `replaceBackendAndRecord(with:attempt:usageOfAttempt:stopReason:measure:)` replaces the backend and records the attempt. The watch stop (`recordStoppedAttempt`) and the yield both call it, so the baseline arithmetic has one copy.
    - Criterion 2: in the scripted test, the call that the yield cancelled has its `generationCall` row (700 in, 10 out, entryKind `.toolCall`), and the journal rows agree. The call ended at a tool call, so the open of its tool reports it when the backend reported usage by then. A usage that arrives after the tool open and before the replace is now taken before the replace. Before the fix, it was read against the new backend and was lost.
    - Why one case cannot have a row: when the backend never reports the usage of that call (for example, an MLX call whose usage update never arrives after the cancel), the ledger cannot tell a call that the tool open already reported from a call that the backend never reported. A counted row (as the watch stop gives) could then report the same call two times. So the yield counts no tokens for that call. This is the same rule that ^3anq1yz uses for a call that ended at a tool call (`takeStoppedGenerationCall`, `endedAtToolCall`).
  timestamp: 2026-10-05T19:10:55.280288+00:00
- actor: claude-code
  id: 01m46qkwya01wyrth97t20274n
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorCompactionYield.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorReplacedBackend.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorWatchStopUsage.swift, Tests/FoundationModelsRouterTests/ToolResultCompactionTests.swift. New test RED then GREEN. Full `swift test --scratch-path <scratchpad>/build`: 1483 tests in 186 suites passed (2 known issues that existed before), 23 and 19 tests in the other runs passed, 0 failures.
    - next: review
  timestamp: 2026-10-05T19:10:58.506388+00:00
- actor: claude-code
  id: 01m46qnmygcq8ekp6d0v2kf6aa
  text: |-
    ### test — green
    - evidence: swift test with the scratchpad scratch path. 1483 tests in 186 suites passed. 23 tests and 19 tests in two more runs passed. 0 failures. 0 skipped. 2 known issues are expected (withKnownIssue).
    - note: The build gave one build-system line: "missing creator for mutated node" on the mlx-swift_Cmlx bundle. It is a dependency bundle line. It is not a source warning. The build was incremental (2.55 sec).
    - next: review.
  timestamp: 2026-10-05T19:11:55.856097+00:00
position_column: doing
position_ordinal: '80'
title: Usage delta after a compaction yield reads the new backend against the old baseline
---
## Problem

`RoutedSessionActorCompactionYield.swift`, `continueAfterCompactionYield(_:attempt:body:)`: the session replaces `backend` with the rebuilt transcript (`backend.replacingTranscript(...)`), and after that it calls `finishSubmissionAndRequeueIfUnattached` with `usageBefore: attempt.usageBefore`. A replaced backend starts a usage count of its own. Thus `finishSubmission` computes the usage of the attempt as the count of the new backend minus the baseline of the old backend. That value can be negative, and the `submissionEnded` of the yielded submission then carries a wrong `tokensIn` and `tokensOut`. The answer usage (`SessionAnswer.usage`) adds that wrong value.

The watch stop path had the same shape and was corrected in ^3anq1yz (`recordStoppedAttempt` reads the usage of the attempt before it replaces the backend, and gives the finish a baseline that gives back that usage).

Also check: `takeGenerationCall` in `finishSubmission` after the replace reads the new backend against the ledger of the old backend. So the call in flight at the yield gets no `generationCall` row.

## Acceptance criteria

- [x] A test with a scripted backend that reports usage, and a tool result that crosses the compaction trigger. The `submissionEnded` of the yielded submission carries the usage of the attempt, not the new count minus the old baseline.
- [x] The call that the yield cancelled has a `generationCall` row, or the card records why it cannot have one.

Found during ^3anq1yz. #router #defect
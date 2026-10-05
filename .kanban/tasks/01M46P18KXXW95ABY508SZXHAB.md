---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Usage delta after a compaction yield reads the new backend against the old baseline
---
## Problem

`RoutedSessionActorCompactionYield.swift`, `continueAfterCompactionYield(_:attempt:body:)`: the session replaces `backend` with the rebuilt transcript (`backend.replacingTranscript(...)`), and after that it calls `finishSubmissionAndRequeueIfUnattached` with `usageBefore: attempt.usageBefore`. A replaced backend starts a usage count of its own. Thus `finishSubmission` computes the usage of the attempt as the count of the new backend minus the baseline of the old backend. That value can be negative, and the `submissionEnded` of the yielded submission then carries a wrong `tokensIn` and `tokensOut`. The answer usage (`SessionAnswer.usage`) adds that wrong value.

The watch stop path had the same shape and was corrected in ^3anq1yz (`recordStoppedAttempt` reads the usage of the attempt before it replaces the backend, and gives the finish a baseline that gives back that usage).

Also check: `takeGenerationCall` in `finishSubmission` after the replace reads the new backend against the ledger of the old backend. So the call in flight at the yield gets no `generationCall` row.

## Acceptance criteria

- [ ] A test with a scripted backend that reports usage, and a tool result that crosses the compaction trigger. The `submissionEnded` of the yielded submission carries the usage of the attempt, not the new count minus the old baseline.
- [ ] The call that the yield cancelled has a `generationCall` row, or the card records why it cannot have one.

Found during ^3anq1yz. #router #defect
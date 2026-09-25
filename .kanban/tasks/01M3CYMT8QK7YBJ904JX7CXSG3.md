---
assignees:
- claude-code
depends_on:
- 01M3CYMC96HM7ZQF3XACBHPDJY
position_column: todo
position_ordinal: '9480'
title: Submission and answer events, and SessionAnswer in place of TurnOutcome
---
## Why

The events still describe a turn. `SessionEvent.turnStarted(TurnStart)` comes one time for each caller call, `turnEnded(TokenUsage)` one time for each SDK attempt, and no event marks the final answer. The user decided on 2026-09-25: "Events report each item (queued, started, ended) and each final answer". Design: `generation-queue.md`, section 5.6.

## What to do

1. Add a `SubmissionID` (opaque, unique in its session) and give it to each submission of the pump.
2. Events of the item (one submission): `.submissionQueued(SubmissionID)` only when it waits for the worker, `.submissionStarted(SubmissionStart)` (the id, and the `MessageID`s the submission delivers, and the cause: caller message, mail, or continuation), `.submissionEnded(SubmissionEnd)` (the id, the `TokenUsage` of that SDK call, and the `FinishReason`). `submissionEnded` replaces `turnEnded` one for one (one for each SDK call, also for a failed one).
3. Events of the answer: `.answered(SessionAnswer)` one time for each final answer, and `.answerFailed(AnswerFailure)` (the `MessageID`s and the reason: cancelled, or the error text) when the chain ends with no answer.
4. `SessionAnswer` replaces `TurnOutcome`: the reply, the `MessageID`s it answers, the usage summed over the submissions of the chain, the compactions, the tool calls and the tool invocation records. The reducer of `TurnOutcome` becomes the reducer of `SessionAnswer`.
5. Remove `turnStarted`, `TurnStart` and `TurnID`. `SessionProjection.currentTurn` becomes `currentSubmission: SubmissionStart?`, plus the waiting `MessageID`s.
6. `textDelta` and `textReset` also travel on `streamSessionEvents()`, because no caller owns a submission the pump started for mail.
7. Tracing: one span for each submission, named `submission`, with `submission.id` and `submission.cause` in place of `turn.id` and `turn.entry_point`. Update the DocC table of span attributes.
8. `generationCall(GenerationCallUsage)` stays: it reports one pass inside a submission.

## Acceptance Criteria

- [ ] A test with an overflow retry: two `submissionStarted`/`submissionEnded` pairs and one `answered`.
- [ ] A test: one `answered` names every `MessageID` its chain delivered.
- [ ] A test: a cancelled chain sends `answerFailed` with the reason "cancelled" and no `answered`.
- [ ] A test: a submission that waits sends `submissionQueued` before `submissionStarted`.
- [ ] `SessionProjection` tests restated to `currentSubmission`.
- [ ] Public-surface tests for every new public type.
- [ ] `rg -n "turnStarted|turnEnded|TurnStart|TurnID|TurnOutcome" Sources` finds nothing.
- [ ] Full `swift test` green, 0 new warnings; IntegrationTests build clean. #generation-queue
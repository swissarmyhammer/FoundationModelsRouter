---
assignees:
- claude-code
depends_on:
- 01M3FNB4MCRRBTJNNVZZ6P02R2
position_column: todo
position_ordinal: 9f80
title: 'Router: build SessionOutbox on the Extras Mailbox, and keep the pump''s cancellation invariants'
---
## What
Decision (user, 2026-09-26): the Extras `Mailbox<Message, Answer>` lets a caller post messages to a session asynchronously. The router's session message queue uses it.

Blocked by Extras task 01M3FN9KTQA9S37VTZXMMSRS07 (the generic `Mailbox`: `post` returns a `MessageID` and a one-time answer slot, plus cancel, replace, depth and take-next-batch). The Extras work must be pushed first.

- The Extras API (2026-09-26): `Mailbox<Message, Answer>` is a final class with one Mutex state. `post(_:) -> (id: MessageID, answer: MailboxAnswer<Answer>)` does not wait, and `answer.value` is `get async throws`. `postAndWait(_:)` cancels the message when the caller is cancelled. `cancel(_:) -> MessageCancellationResult` gives `.withdrawn`, `.cancelledInSubmission` or `.alreadyAnswered`. `replace(_:with:) -> MessageQueueMutationResult` gives `.applied` or `.alreadySent`. `pending`, `depth: MessageQueueDepth`, and `answerNextBatch(joining:_:) async -> Bool` for the pump. `takeJoining(admitting: (Message) -> Bool) -> [Letter]` (`Letter` has `id` and `message`) does not wait or suspend: in one lock step it takes each waiting letter that the predicate admits, in FIFO order, and joins it to the running batch; with no running batch it returns []. Use it in `takeMessagesJoiningTheAnswer()` in place of `outbox.takeJoiningBatch`. The Mailbox has no cancel mark: `cancel` removes a waiting letter and gives it `CancellationError` under the same lock, so a take never returns a cancelled message.
- Because `cancel` is now one synchronous lock step (no actor hop), some router constructs exist only for the old hop: `PumpAnswer.requestCancel()` before the withdraw, the post-enqueue `cancel(message:)` in `enqueueAndAwaitAnswer(of:)` (^5mnw172), and the `liveMessages` filter. You can remove such a construct only if its reason is gone. For each removal, write in the task comment the reason that is gone and the router test that still covers the case. Keep `isWorkCancelled` and the cancel of the running answer.
- When `cancel` returns `.cancelledInSubmission`, the router stops its running SDK call itself, as it does today. The Mailbox does not do this.
- `Sources/FoundationModelsRouter/Session/SessionOutbox.swift`: keep the caller-message queue in an Extras `Mailbox`. The router keeps these parts on top of it: `OperationEvent` mail and the coalescing of progress events, `OperationEventJournal`, and the conformance to `OperationEventSink` and `ToolCallReportSink`.
- `Sources/FoundationModelsRouter/Session/SessionMessage.swift`: remove `PumpAnswer` and use the Extras answer slot. `SessionMessage`, `MessageReader` and `SubmissionOptions` stay router types.
- `Sources/FoundationModelsRouter/Session/MessageQueue.swift`: use the Extras `MessageID` and depth and result types, if they are the same. Keep the public router names with typealiases if a rename would break users.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorPump.swift` and `RoutedSessionActorQueueing.swift`: take batches from the mailbox. Compaction, repetition limits, `recordSessionMetaIfNeeded` and `notifySubmissionBoundaryTools` stay router hooks around each batch.
- `Hosting/SessionMailbox.swift` (tool runs and elicitations) does not change.
- The pump has constructs that look redundant but prevent a model-wide deadlock and prevent silent loss of outbox messages. Do not remove or simplify them, except the constructs for the old cancel hop in the step above, with the record that step requires. Read the comments in `RoutedSessionActorPump.swift` and `RoutedSessionActorCancellation.swift` before the change.

## Acceptance Criteria
- [ ] `PumpAnswer` and the router's own caller-message FIFO are removed; the Extras `Mailbox` does this work.
- [ ] A cancelled pump does not block the work queue of the model: after a submission is cancelled, the next submission from a different session on the same model runs.
- [ ] The router tests of the queue semantics stay in the router. Extras has copies of them; the router removes none.
- [ ] The public API of `RoutedSession` (`send`, `enqueue`, `pendingMessages`, `replace`, `messageQueueDepth`) does not change.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] `SessionOutboxTests`, `SessionMessagePumpTests`, `MessageQueueTests`, `MailOnlyAnswerLimitTests`, `PendingEventInjectionTests`, `RespondRunPlaneDrainTests` and the `AnswerCancellation*` tests pass with no change to what they assert.
- [ ] Run the cancellation tests with parallel repetitions to find a race (for example `swift test --filter AnswerCancellation --parallel --num-workers 8`, repeated 20 times), and all runs pass.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo
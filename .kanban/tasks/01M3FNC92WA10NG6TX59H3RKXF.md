---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hfk44mq2hpt25gqrw3m322
  text: |-
    ### Research
    - The Extras `Mailbox` (f4bd503) is a final class with one Mutex. `MessageID.init` is internal to Extras: only `post` makes an id. So `SessionMessage` loses its `id` and `answer`; the pump works with `Mailbox.Letter` (id and message).
    - `answerNextBatch` waits on a doorbell when no letter waits. The pump reads `pending` and then calls `answerNextBatch` with no suspension point between them (same actor isolation). A caller cancel that runs off the actor can withdraw the last letter in that window. Then the pump waits for a letter that never comes. Plan: a flag `pumpAwaitsLetter`; each wake, withdraw and cancel releases the waiting pump (cancel of its task: `answerNextBatch` then returns `false` and takes nothing), and a new pump starts.
    - Caller compactions also used `PumpAnswer`. Plan: a second Extras `Mailbox<CompactionRequest, CompactionResult>`.
    - A mail-only answer has no mailbox batch, so `takeJoining` returns [] for it. The task states this contract.
    - Test helpers read `outbox.waitingMessageCount`, `pendingCompactions` and `MessageID()`. Tests keep their assertions; only the calls change.
  timestamp: 2026-09-27T13:06:41.428248+00:00
- actor: claude-code
  id: 01m3hg01bfbp361w56ec9sxzpf
  text: |-
    ### Constructs for the old cancel hop: what went, what stays
    1. REMOVED: `PumpAnswer.requestCancel()` before the withdraw. Reason that is gone: the withdraw was a hop to the actor, so the pump could take the message between the cancel and the withdraw. `Mailbox.cancel` is one synchronous lock step in the handler of the caller task: it withdraws a waiting letter (no take returns it after that) or takes it out of the running batch (`.cancelledInSubmission`). The second job of the mark (^cx1type: `isWorkCancelled` sees the cancel before the stop reaches the actor) stays in a new form: `isWorkCancelled` now reads the running batch of the mailbox, and a delivered message that left the batch counts as a cancel. Router tests that cover it: `theCancelMarkAloneStopsTheOverflowRetry` (now does only the mailbox cancel, with no hop) and `cancellationSurvivesIntoTheOverflowRetry(route: .callerTask)`.
    2. REMOVED: the post-enqueue `cancel(message:)` in `enqueueAndAwaitAnswer(of:)` (^5mnw172). Reason that is gone: the handler withdrew in a task of its own that could reach the queue before the add. Now the post is synchronous on the session actor, the handler is installed after the post with no suspension point between them, the pump takes a batch only on the session actor, and Swift runs the handler at once at install when the task is already cancelled. So the handler always finds the message in the mailbox, and its cancel is synchronous. Router test: `aCallerCancelledBeforeTheCallNeverReachesTheModel`. The same order applies to `compact()`: `cancellingAWaitingCallerCompactWithdrawsIt`.
    3. KEPT (new form): the `liveMessages` filter is now `liveLetters(_:of:)`. A cancel from the handler of a caller task does not run on the actor, so it can take a letter out of the running batch after the take and before the pump makes the letter part of its work. The filter reads the running batch with no suspension point before the work holds the letters.
    4. KEPT: `isWorkCancelled`, `.taking`, the stop of the running answer on `.cancelledInSubmission` (`settleCancel(of:_:)` -> `requestCancelOfRunningWork()`), `pumpWakeRequested`, `Task.detached`, the per-event hold.
    5. NEW: `pumpAwaitsLetter` and `releasePumpAwaitingLetter()`. `answerNextBatch` waits on a doorbell when no letter waits. An off-actor cancel can withdraw the last letter between the read of `pending` and the take. Each wake, each withdraw and `cancel()` release such a pump (cancel of the pump task: the take returns `false` with nothing taken), and the pump starts a new pump. `requestCancelOfRunningWork()` does not count a pump that waits for a letter as work.
  timestamp: 2026-09-27T13:13:44.559121+00:00
- actor: claude-code
  id: 01m3hpabstaqxpnj9crvq5pdgy
  text: |-
    ### Correction: the cancel mark STAYS (replaces items 1 and 3 of the comment above)
    - A first version called `Mailbox.cancel` for a running message. The mailbox then gives the caller `CancellationError` at once. `RespondRunPlaneDrainTests.cancellingTheCallersTaskLeavesTheStartedRunRunning` failed: it asserts that a caller whose task is cancelled while its message runs gets the answer of the batch (cancel is cooperative). So the reason for the mark is not gone, and the mark stays in a new form.
    - `PumpAnswer` is removed. The mark is now `CancelMarks` (a `Mutex<Set<MessageID>>` on the session, `cancelMarks`). `requestCancel(of:in:)` is the first half of each cancel, with no suspension point: a running item gets a mark and keeps its place in the batch; any other item gets `Mailbox.cancel` (withdrawn). `settleCancel(of:_:)` is the second half on the actor: it stops the work, or releases a pump that waits for a letter.
    - `isWorkCancelled` reads the marks of the items of the running work (^cx1type). `theCancelMarkAloneStopsTheOverflowRetry` now calls only `requestCancel(of:in:)`.
    - The `liveMessages` filter stays as `liveLetters(_:of:)`: it drops a letter that has a mark or that left the batch, and a marked letter gets `CancellationError` from `Mailbox.cancel`, as before.
    - The mail of a batch is taken with the batch again, and the "every caller was cancelled" path puts the mail back untouched (`putBack(untouched:)`), as before.
    - REMOVED (unchanged from the comment above): the post-enqueue `cancel(message:)` of ^5mnw172. Covered by `aCallerCancelledBeforeTheCallNeverReachesTheModel`.
    - Note: the disk of the machine was full during a test loop (No space left on device). I removed leftover test directories of this repository's tests in $TMPDIR that were older than one day. The failed runs of that loop came from the disk, not from the code. All loops ran again after the user freed space.
  timestamp: 2026-09-27T15:04:14.394270+00:00
- actor: claude-code
  id: 01m3hparfza9yrpk6fwvadpdbf
  text: |-
    ### implement — changed
    - evidence: Sources: MessageQueue.swift, SessionMessage.swift, SessionOutbox.swift, OperationEventSegment.swift, RoutedSessionActor.swift, RoutedSessionActorPump.swift, RoutedSessionActorQueueing.swift, RoutedSessionActorCancellation.swift, RoutedSessionActorGeneration.swift, RoutedSessionActorCompaction.swift, RoutedSessionActorAnswerExecution.swift. Tests (calls only, no assertion changed): SessionOutboxTests, SessionMessagePumpTests, MessageQueueTests, AnswerCancellationEntryPointTests, HumanWaitGateTests, SessionProjectionTests, SessionProjectionSeedingTests, Helpers/SessionPlumbingAccess.swift, new Helpers/MessageIDFixtures.swift. Clean `swift build --build-tests`: 0 code warnings. `swift test`: 1448 tests in 173 suites passed (2 known issues), plus 17 and 19. `swift test --filter AnswerCancellation --parallel --num-workers 8` x20: 27 tests each, 20/20 passed. Pump and queue suites x20: 94 tests each, 20/20 passed.
    - next: test
  timestamp: 2026-09-27T15:04:27.391044+00:00
- actor: claude-code
  id: 01m3hpbh6gj39zjk9jkmh14wr5
  text: |-
    ### test — green
    - evidence: clean `swift build --build-tests`: 0 code warnings (only the build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle"). `swift test`: 1448 tests in 173 suites passed (2 known issues), 17 tests in 8 suites passed, 19 tests in 3 suites passed; 0 skipped by this change. AnswerCancellation parallel x20: 27/27 each. Pump and queue suites parallel x20: 94/94 each.
    - note: another worker edits this working tree at the same time (removes `compaction_plan.md` and its references, changes `Package.swift` and IntegrationTests). The commit of this task takes only the hunks of this task.
    - next: commit
  timestamp: 2026-09-27T15:04:52.688165+00:00
- actor: claude-code
  id: 01m3hpcpgv92mgr26n3mq8k98j
  text: |-
    ### commit — changed
    - evidence: 8e30e3c refactor(session): build SessionOutbox on the Extras Mailbox (^9h3rkxf). Only the hunks of this task: the hunks of the other worker (compaction_plan references in RoutedSessionActorAnswerExecution.swift and RoutedSessionActorCompaction.swift, and the staged delete of compaction_plan.md) are not in the commit and stay as they were.
    - next: review
  timestamp: 2026-09-27T15:05:30.907541+00:00
- actor: claude-code
  id: 01m3hpzwk0ssry21y4e61est9p
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 2 findings (2 confirmed, 1 refuted): Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:146, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:92 (duplication/duplication: the `withTaskCancellationHandler` + `cancelFromCallerTask` pattern; extract `awaitMailboxAnswer`).
    - next: implement
  timestamp: 2026-09-27T15:15:59.712599+00:00
- actor: claude-code
  id: 01m3hpzyp5a37csj67x40q3x3y
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (Mailbox-based SessionOutbox, CancelMarks, pump release)
    - test: green (swift test 1448 + 17 + 19 passed; AnswerCancellation parallel x20 all pass; clean build 0 code warnings)
    - commit: 8e30e3c
    - review: findings — 2 (duplication/duplication at RoutedSessionActorCompaction.swift:146 and RoutedSessionActorGeneration.swift:92)
  timestamp: 2026-09-27T15:16:01.861249+00:00
- actor: claude-code
  id: 01m3hqnxggdc1hcm48fztrjnnn
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (d71a2af) — 0 findings, 0 refuted. Both prior findings (duplication/duplication at RoutedSessionActorCompaction.swift:146 and RoutedSessionActorGeneration.swift:92) are fixed by `awaitMailboxAnswer(id:answer:in:)` and checked.
    - next: done
  timestamp: 2026-09-27T15:28:01.552656+00:00
- actor: claude-code
  id: 01m3hqnzxmn2g5n8pez680mfb1
  text: |-
    ### finish iteration 2 — clean
    - implement: changed (extract `awaitMailboxAnswer(id:answer:in:)`, used by `enqueueAndAwaitAnswer` and `compact`)
    - test: green (swift test 1448 + 17 + 19 passed; AnswerCancellation parallel x20: 27/27 each)
    - commit: d71a2af
    - review: clean — 0 findings
  timestamp: 2026-09-27T15:28:04.020821+00:00
depends_on:
- 01M3FNB4MCRRBTJNNVZZ6P02R2
position_column: done
position_ordinal: ffffff9f80
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
- [x] `PumpAnswer` and the router's own caller-message FIFO are removed; the Extras `Mailbox` does this work.
- [x] A cancelled pump does not block the work queue of the model: after a submission is cancelled, the next submission from a different session on the same model runs.
- [x] The router tests of the queue semantics stay in the router. Extras has copies of them; the router removes none.
- [x] The public API of `RoutedSession` (`send`, `enqueue`, `pendingMessages`, `replace`, `messageQueueDepth`) does not change.
- [x] `swift build` passes with no warnings on a clean build.

## Tests
- [x] `SessionOutboxTests`, `SessionMessagePumpTests`, `MessageQueueTests`, `MailOnlyAnswerLimitTests`, `PendingEventInjectionTests`, `RespondRunPlaneDrainTests` and the `AnswerCancellation*` tests pass with no change to what they assert.
- [x] Run the cancellation tests with parallel repetitions to find a race (for example `swift test --filter AnswerCancellation --parallel --num-workers 8`, repeated 20 times), and all runs pass.
- [x] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo

## Review Findings (2026-09-27 10:05)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 20 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:146` `duplication/duplication` — The pattern of wrapping a mailbox answer in `withTaskCancellationHandler` with `cancelFromCallerTask` on cancel is duplicated. This exact structure appears in both `compact()` (here) and `enqueueAndAwaitAnswer()` in RoutedSessionActorGeneration.swift, differing only in the mailbox type and how the item is posted. Two functions doing the same thing with different mailbox parameters should share one extracted helper. Extract a shared helper function `awaitMailboxAnswer<Message: Sendable, Answer: Sendable>(id: MessageID, answer: MailboxAnswer<Answer>, in mailbox: Mailbox<Message, Answer>) async throws -> Answer` that handles the `withTaskCancellationHandler` + `cancelFromCallerTask` pattern, and call it from both `compact()` and `enqueueAndAwaitAnswer()`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:92` `duplication/duplication` — The pattern of wrapping a mailbox answer in `withTaskCancellationHandler` with `cancelFromCallerTask` on cancel is duplicated. This exact structure appears in both `enqueueAndAwaitAnswer()` (here) and `compact()` in RoutedSessionActorCompaction.swift, differing only in the mailbox type and how the item is posted. Two functions doing the same thing with different mailbox parameters should share one extracted helper. Extract a shared helper function `awaitMailboxAnswer<Message: Sendable, Answer: Sendable>(id: MessageID, answer: MailboxAnswer<Answer>, in mailbox: Mailbox<Message, Answer>) async throws -> Answer` that handles the `withTaskCancellationHandler` + `cancelFromCallerTask` pattern, and call it from both `enqueueAndAwaitAnswer()` and `compact()`.

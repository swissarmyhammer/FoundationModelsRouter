---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3e0q3jp12v0snh9pe9kzkpm
  text: |-
    Picked up. Research done at HEAD fa18880.

    What holds now:
    - `turnStarted(TurnStart)` is sent one time for each answer (the pump chain), in `runTurnWork`, before the proactive compaction. `turnEnded(TokenUsage)` is sent in `finishTurn` (Recording) one time for each attempt (`runTurnAttempt`), only when the backend gives usage; also for an attempt that the hard ceiling refused before its model call, and for a proactive compaction that failed before the first attempt.
    - `submissionQueued` / `submissionStarted` have no payload. They come from `GenerationCallPhase.sessionEvent` through the pass observer, and only for a backend with a queue (D4 of ^1psqdm9). A summarizer call of a compaction sends them too (D5 of ^1psqdm9).
    - `TurnOutcome` is reduced by `TurnOutcomeReducer` in `respond(to:maxTokens:observing:)`; `usage` is the LAST `turnEnded`.
    - The span `FoundationModelsRouter.turn` is opened by `runTurn` with `withSpan` around the whole answer. `turn.entry_point` comes from `SessionMessage.entryPoint` (`RouterTracing.TurnEntryPoint`), which has no other reader except `TurnStart.messageId`.
    - `textDelta`/`textReset` are yielded only to the per-message event stream by `streamGeneratingBody`. A reply submission (`respond`, `send`, mail) calls `backend.respond`, which gives no fragments.
    - No `SessionEvent` is stored in a recording (only `TranscriptEvent`), so old recordings are not touched by this task.

    Decisions (the reasons are in each item):
    - D1. `SubmissionID`: opaque, minted from a per-session counter that starts at 1, one for each submission. Reason: the work id also counts caller compactions, and a submission is not a work.
    - D2. A submission of the session is one attempt of the answer chain: the first one, and each continuation (compaction yield, ceiling stop, overflow retry, rejected tool call, repetition recovery). A summarizer call of a compaction is NOT a submission of the session, and sends no submission event. Reason: design 5.5 puts compaction BETWEEN two submissions, the cause list of 5.6 has no compaction, and the acceptance criterion counts two pairs for an overflow retry, which always compacts. This replaces D5 of ^1psqdm9. The stall watch of a summarizer call does not change.
    - D3. Every submission sends `submissionStarted`, also over a backend with no queue (at the start of its model call). With a queue it comes when the worker starts the item. `submissionQueued(id)` comes only for a wait. Reason: `submissionStarted` replaces `turnStarted` as the frame, and a consumer needs start and end pairs on every backend. This replaces D4 of ^1psqdm9. The start event is sent by an actor hop at the start of the item, after the pending phases are applied, so `submissionQueued` always comes first and no content comes before the start.
    - D4. `submissionEnded` for every submission the session opened, at the place of `turnEnded`, also for a failed one, also when the backend gives no usage (`usage` is then `nil`). A submission that never started (the hard ceiling refused it, or a cancel came before or during its wait) sends `submissionEnded` with no `submissionStarted`. A proactive compaction that fails before the first submission opens no submission, so it sends no `submissionEnded`; the answer ends with `answerFailed`.
    - D5. `SubmissionEnd`: `submissionId`, `usage: TokenUsage?`, `finishReason`. `TokenUsage` keeps its `finishReason` (no public break there).
    - D6. `SubmissionStart`: `submissionId`, `messageIds: [MessageID]`, `cause: SubmissionStart.Cause` (`message`, `mail`, `continuation`, raw values used by tracing). The first submission has cause `message` when it carries a caller message, else `mail`; its ids are the messages of the batch. A continuation has cause `continuation` and the ids of the messages that joined it.
    - D7. `answered` / `answerFailed` are sent by the pump when the chain ends, to the stream of the first message (when it streams events) and to `streamSessionEvents()`. The ids are every message the chain delivered, joined ones too. The reason is `cancelled` when `isWorkCancelled` is true (the cancel invariant: key on the predicate, not on the error type), else `error(String(describing: error))`. A message withdrawn before a chain took it gets no event: no chain answered it.
    - D8. `SessionAnswer.reply` is the final reply of the chain (what `respond` returns). `usage` sums `tokensIn`/`tokensOut` over the `submissionEnded` events that carry usage; `contextFill` and `finishReason` come from the last of them; `nil` when none carries usage.
    - D9. `respond(to:maxTokens:observing:)` returns `SessionAnswer`, taken from the `answered` event of its stream.
    - D10. `SessionProjection.currentSubmission` is set at `submissionStarted` and cleared at the `submissionEnded` of the same id. The waiting ids are `messagesAwaitingAnswer`: the ids a started submission delivered and no `answered`/`answerFailed` closed yet. Reason: an event-fed projection cannot see the outbox; "waiting" already names a message in the outbox in the `RoutedSession` API.
    - D11. The `textDelta`/`textReset` of a stream submission also go to `streamSessionEvents()`. A reply submission (`send`, mail) still calls `backend.respond`; its text comes in `answered.reply`. To stream a mail submission would change the backend call and drop the grammar; that is not in this task.
    - D12. Tracing: one span `FoundationModelsRouter.submission` for each submission, opened when the submission opens and ended when it ends, a child of the caller's context, the parent of the tool spans. Attributes `submission.id`, `submission.cause`, and `tokens.in`/`tokens.out` when the submission measured the render. `RouterTracing.TurnEntryPoint` and `SessionMessage.entryPoint` go: no reader is left.
    - D13. Each new payload type has a public init, as `TurnStart` got after the review of ^cbhpdjy.

    Names that later tasks own are not renamed here (internal `runTurnAttempt`, `finishTurn`, `recordFailedTurn`, `TurnBoundaryTool`, `recoveriesPerTurn`, the test helpers with "turn").
  timestamp: 2026-09-26T04:48:59.990092+00:00
- actor: claude-code
  id: 01m3e165gdb3zas10yzx6dk28d
  text: 'Progress: tests written first (RED: the target does not compile until the new API exists): `SubmissionAnswerEventTests` (answered names every message of its submission; a joined continuation message; cancelled chain -> answerFailed(.cancelled); error chain -> answerFailed(.error)), `AutoCompactionTests.overflowRetrySendsTwoSubmissionPairsAndOneAnswer`, restated `SessionProjectionTests` (submissionEnded counters, currentSubmission, messagesAwaitingAnswer), public-surface `SubmissionStartPublicSurfaceTests` (git mv from TurnStartPublicSurfaceTests), `SessionAnswerPublicSurfaceTests`, restated `GenerationSubmissionEventPublicSurfaceTests`. Production types landed: `SubmissionIdentity.swift` (git mv from TurnIdentity.swift), `SessionAnswer.swift` (git mv from TurnOutcome.swift), `RoutedSessionActorSubmissionEvents.swift`, `SessionEvent` cases. Next: the pump, recording, tracing, projection and doc edits, then the restated unit tests.'
  timestamp: 2026-09-26T04:57:13.485490+00:00
- actor: claude-code
  id: 01m3e34t8ys23k6tanj0txdgj1
  text: |-
    ### implement — changed
    - evidence: Sources — new `Session/SubmissionIdentity.swift` (git mv from TurnIdentity.swift), `Session/SessionAnswer.swift` (git mv from TurnOutcome.swift), new `Session/RoutedSessionActorSubmissionEvents.swift`; changed SessionEvent, RoutedSessionActor, RoutedSessionActorTurnExecution (runAnswerChain replaces runTurn; begin/end of each submission; start event by an actor hop at the start of the queue item), Pump, Recording (endSubmission in place of turnEnded), PassReports, Generation (text events also on streamSessionEvents), Queueing, SessionMessage (entryPoint gone), SessionProjection (currentSubmission, messagesAwaitingAnswer), ResponseTextReducer, RoutedSession docs (span table), GenerationPassObserver (`sessionEvent(submission:)`), GenerationQueue, RouterTracing (span `submission`, `submission.id`, `submission.cause`; TurnEntryPoint gone). DocC RoutedSession.md, SessionProjection.md; Examples/MultiModelGeneration; 8 IntegrationTests files; generation-queue.md 5.6. Tests: new SubmissionAnswerEventTests, SessionAnswerPublicSurfaceTests, SubmissionStartPublicSurfaceTests (git mv), Helpers/AnswerFrameAssertions.swift (git mv from TurnFrameAssertions); restated about 25 test files (no test deleted; 31 @Test lines renamed, 39 now).
    - tests: full `swift test`: 1455 + 13 + 19 = 1487 passed (was 1472), 0 failed, 2 expected known issues; 0 warnings in touched files after a forced recompile. 13 session/event/projection/tracing/cancellation/queue suites with `--parallel`: 10 of 10 runs passed (178 tests each). `swift build` library + Examples clean; IntegrationTests `swift build --build-tests` clean. `rg` of the removed names in Sources: nothing.
    - decisions: see the research comment (D1–D13). Meaning changes worth a look in review: `SessionAnswer.reply` is the final reply of the chain, not a reduction of textDeltas; `SessionAnswer.usage` is the sum; `respond` messages now carry their id in `SubmissionStart.messageIds` (the old TurnStart named only `send` ids); a summarizer call sends no submission event (old SummarizerSubmissionTests restated).
    - not changed (owned by later tasks): internal names with "turn" (`runTurnWork`, `runTurnAttempt`, `finishTurn`, `turnEventSink`, `currentTurnEventSink`), test file/suite names with "turn", `UPSTREAM_ASKS.md` mentions of the old events (^f33q8gw / ^d7d777f).
    - next: review
  timestamp: 2026-09-26T05:31:26.366967+00:00
depends_on:
- 01M3CYMC96HM7ZQF3XACBHPDJY
position_column: doing
position_ordinal: '80'
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

- [x] A test with an overflow retry: two `submissionStarted`/`submissionEnded` pairs and one `answered`. <!-- AutoCompactionTests.overflowRetrySendsTwoSubmissionPairsAndOneAnswer -->
- [x] A test: one `answered` names every `MessageID` its chain delivered. <!-- SubmissionAnswerEventTests.anAnswerNamesEveryMessageOfItsSubmission, SubmissionAnswerEventTests.anAnswerNamesAMessageThatJoinedAContinuation -->
- [x] A test: a cancelled chain sends `answerFailed` with the reason "cancelled" and no `answered`. <!-- SubmissionAnswerEventTests.aCancelledChainSendsAnswerFailed -->
- [x] A test: a submission that waits sends `submissionQueued` before `submissionStarted`. <!-- QueuedPassStallWatchTests.aWaitingSubmissionSendsItsQueuedIdBeforeItsStartAndNoStall -->
- [x] `SessionProjection` tests restated to `currentSubmission`. <!-- SessionProjectionTests.currentSubmissionRunsFromItsStartToItsEnd, messagesAwaitingAnswerHoldsTheDeliveredMessagesUntilTheirAnswer, expectProjectionUnchanged; SessionProjectionSeedingTests -->
- [x] Public-surface tests for every new public type. <!-- SubmissionStartPublicSurfaceTests, SessionAnswerPublicSurfaceTests, GenerationSubmissionEventPublicSurfaceTests -->
- [x] `rg -n "turnStarted|turnEnded|TurnStart|TurnID|TurnOutcome" Sources` finds nothing. <!-- rg exit 1 -->
- [x] Full `swift test` green, 0 new warnings; IntegrationTests build clean. #generation-queue <!-- swift test: 1455 + 13 + 19 = 1487 passed; IntegrationTests swift build --build-tests: Build complete -->

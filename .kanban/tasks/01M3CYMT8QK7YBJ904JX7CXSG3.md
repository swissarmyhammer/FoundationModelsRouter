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
- actor: claude-code
  id: 01m3e59yk3yd9de10s2ktfmz4p
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit c682155). 3 findings, 3 confirmed, 0 refuted. Sources/FoundationModelsRouter/Session/SessionAnswer.swift:250 (swift/error-handling), Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:407 (completeness/invariant-propagation), Tests/FoundationModelsRouterTests/SubmissionAnswerEventTests.swift:80 (swift/fluent-usage).
    - next: implement. Do the 3 items in the "Review Findings (2026-09-26 00:40)" section. The task stays in review.
  timestamp: 2026-09-26T06:09:11.779446+00:00
- actor: claude-code
  id: 01m3e5agyeq61w8fhp5rk4h7tk
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 62 files (submission and answer events; SessionAnswer; TurnStart, TurnID, TurnOutcome removed)
    - test: green — swift test, 1487 passed (1455+13+19), 0 failed, 0 skipped; 9 event and session suites 3 extra runs clean; all products and IntegrationTests build clean
    - commit: c682155
    - review: findings — Session/SessionAnswer.swift:250, AutoCompactionTests.swift:407, SubmissionAnswerEventTests.swift:80
  timestamp: 2026-09-26T06:09:30.574001+00:00
- actor: claude-code
  id: 01m3e5gh5aav1skn22ahnj6f42
  text: |-
    Picked up the 3 review findings (moved to doing). Research:
    - Finding 1: `respond(to:maxTokens:observing:)` is the only loop in `Sources/` that waits for `answered`. `SessionProjection.apply(eventsFrom:)` already handles `answerFailed`. The crash is reachable: when the task that awaits `respond` is cancelled, the `for try await` over an `AsyncThrowingStream` ENDS (next() gives nil, no throw). Then `answer` is nil and `preconditionFailure` stops the process. A chain that fails with an error does not crash today, because the stream throws after `answerFailed`.
    - Decision F1: move the loop into an internal `SessionAnswer.awaitEnd(of:observing:)` so a unit test can feed a hand-made stream. After the loop: an `answered` gives the answer; else a cancelled task throws `CancellationError`; else a captured `answerFailed` throws that `AnswerFailure` (it now conforms to `Error`); only a stream with no end of the answer and no cancel stays the defect case. The loop does not break at `answerFailed`, so the real error of the chain still reaches the caller when the stream throws it.
    - Decision F2: add the frame check to the new tests of c682155 that collect the events of one answer, and a split helper `eventsInsideAnswerFrames(_:)` for the tests that collect more than one answer.
    - Decision F3: `answersEnd` becomes `waitForAnswersToEnd(_:in:)`. The other helpers of the file (`makeSession(over:dir:)`, `awaitPrompts(_:on:)`) are verb phrases already.
  timestamp: 2026-09-26T06:12:47.402948+00:00
- actor: claude-code
  id: 01m3e5wjdydyeyepmeyxhwnqc9
  text: |-
    Review findings fixed (3 of 3):
    - F1 `swift/error-handling`: the loop of `respond(to:maxTokens:observing:)` moved to internal `SessionAnswer.awaitEnd(of:observing:)`. It captures `answered` and `answerFailed` and reads the stream to its end, so the real error of a failed chain still reaches the caller. After the loop: an answer is returned; a cancelled reader task throws `CancellationError`; a captured `answerFailed` with no stream error throws that `AnswerFailure` (now `Error`); only no end of the answer and no cancel stays `preconditionFailure` (a defect of the session). RED seen first for both new tests: the process stopped at "Fatal error: the event stream of a message finished with no answered event". The real crash was a caller that cancels the task that awaits `respond`: the stream ends with no error and no end of the answer. It is the only loop in `Sources/` that waits for `answered`; `SessionProjection` already handles `answerFailed`; the Examples loop returns its text and throws the stream error, so it has no such gap.
    - F2 `completeness/invariant-propagation`: `_ = eventsInsideAnswerFrame(events)` added to the overflow test and to each new test of c682155 that collects the events of one answer (GenerationCallUsageTests x2 (the manual `events.last?.isAnswerEnd` check replaced), MessageQueueTests x3, QueuedPassStallWatchTests x2, SessionAnswerTests x2, SessionEventStreamTests x2, TurnCancellationTests x1, SubmissionAnswerEventTests x3). New helper `[SessionEvent].eventsInsideEachAnswerFrame()` checks each frame of a log with more than one answer (SubmissionAnswerEventTests two-answer test, MessageQueueTests.consecutiveTurnsTakeDistinctIds). The reducer and projection tests build events by hand and have no live frame, so the check does not fit there.
    - F3 `swift/fluent-usage`: `answersEnd` renamed `waitForAnswersToEnd(_:in:)`. The other helpers of the file (`makeSession(over:dir:)`, `awaitPrompts(_:on:)`) already read as verb phrases.
    - New tests: `SubmissionAnswerEventTests.aRespondWhoseCallerCancelsThrowsCancellationError`, `SubmissionAnswerEventTests.aStreamThatEndsWithAnAnswerFailureThrowsIt`, `SessionAnswerPublicSurfaceTests.aConsumerCatchesAFailureAsAnError`. `AnswerDrivenRun` got `cancel()`.
  timestamp: 2026-09-26T06:19:21.918982+00:00
- actor: claude-code
  id: 01m3e5wpdytqsvrt42245fv6qy
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsRouter/Session/SessionAnswer.swift; Tests/FoundationModelsRouterTests/{SubmissionAnswerEventTests, AutoCompactionTests, GenerationCallUsageTests, MessageQueueTests, QueuedPassStallWatchTests, SessionAnswerTests, SessionEventStreamTests, TurnCancellationTests}.swift; Tests/FoundationModelsRouterTests/Helpers/{AnswerFrameAssertions, AnswerDrivenRun}.swift; Tests/FoundationModelsRouterPublicSurfaceTests/SessionAnswerPublicSurfaceTests.swift. Full `swift test`: 1457 + 14 + 19 = 1490 passed (was 1487; +3 new), 0 failed, 2 expected known issues. Answer, event and compaction suites (12 suites, 150 tests, plus 4 public-surface tests) 3 extra runs: 3 of 3 green. Forced recompile of the touched files: 0 source warnings. IntegrationTests `swift build --build-tests`: Build complete. No commit, no `swift format`.
    - next: review
  timestamp: 2026-09-26T06:19:26.014502+00:00
- actor: claude-code
  id: 01m3e6f95dxn1gn2a6h5q25ycv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 69e1cce): 0 findings, 0 confirmed, 0 refuted. The engine reviewed 12 files. 2 files in `.kanban/` were not reviewed because of `.reviewignore`. The 3 findings of the review of 2026-09-26 00:40 are resolved. (1) `SessionAnswer.swift` now reads `.answerFailed` in the event loop and throws the failure. (2) `AutoCompactionTests.overflowRetrySendsTwoSubmissionPairsAndOneAnswer` now calls `eventsInsideAnswerFrame(events)`. (3) The helper `answersEnd` now has the name `waitForAnswersToEnd(_:in:)`.
    - next: none. The task is in `done`.
  timestamp: 2026-09-26T06:29:35.021147+00:00
- actor: claude-code
  id: 01m3e6hje6j0kjr16tnnq4c8jt
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 12 files (no crash on a failed or cancelled answer; AnswerFailure conforms to Error; frame checks in tests)
    - test: green — swift test, 1490 passed (1457+14+19), 0 failed, 0 skipped; 7 answer and event suites 3 extra runs clean
    - commit: 69e1cce
    - review: clean — 0 findings
  timestamp: 2026-09-26T06:30:50.054605+00:00
depends_on:
- 01M3CYMC96HM7ZQF3XACBHPDJY
position_column: done
position_ordinal: ffffff8d80
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

## Review Findings (2026-09-26 00:40)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 61 file(s) reviewed, 6 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `Examples/MultiModelGeneration/README.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Session/TurnIdentity.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Session/TurnOutcome.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/TurnFrameAssertions.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Session/TurnIdentity.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Session/TurnOutcome.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/Helpers/TurnFrameAssertions.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Session/TurnIdentity.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Session/TurnOutcome.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/Helpers/TurnFrameAssertions.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Session/TurnIdentity.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Session/TurnOutcome.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/Helpers/TurnFrameAssertions.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Session/TurnIdentity.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Session/TurnOutcome.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/TurnFrameAssertions.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, so its declarations are unread

- [x] `Sources/FoundationModelsRouter/Session/SessionAnswer.swift:250` `swift/error-handling` — The event loop captures only `answered` events but the stream is documented to send either `answered(_:)` or `answerFailed(_:)`. If `answerFailed` is received, `answer` remains `nil` and the function crashes with `preconditionFailure` instead of properly propagating the failure, violating the contract that successful answer handling must handle both terminal states. Capture `answerFailed` events in the loop and throw or return the failure. Example: add `else if case .answerFailed(let failure) = event { /* handle or rethrow failure */ }` to the conditional at line 252–254, or break the loop after capturing either terminal event and handle the absence of both as the defect case.
- [x] `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:407` `completeness/invariant-propagation` — New test `overflowRetrySendsTwoSubmissionPairsAndOneAnswer` collects and inspects answer events but does not validate the answer frame structure with `eventsInsideAnswerFrame`, unlike other tests throughout the change that handle submission and answer events. Add `_ = eventsInsideAnswerFrame(events)` after line 418 (after collecting from the log) to validate the answer frame structure is intact, matching the pattern established in other tests in this change.
- [x] `Tests/FoundationModelsRouterTests/SubmissionAnswerEventTests.swift:80` `swift/fluent-usage` — Function name `answersEnd` does not form a grammatical phrase at the call site. The call `let ended = await Self.answersEnd(Self.twoAnswers, in: log)` reads as 'ended = await self answers end...' which is not grammatical. Since the function performs a wait action, the name should be a verb phrase like `waitForAnswersToEnd`. Rename the function to something like `waitForAnswersToEnd(_:in:)` to form a proper verb phrase: `let ended = await Self.waitForAnswersToEnd(Self.twoAnswers, in: log)`.

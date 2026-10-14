---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xrs81d98bypq2kynedy15d
  text: |-
    Research done. Extras is at b68a5d4 (holds 11426a4). The update broke two test call sites: ToolMountFixtures.toolRun (ToolRun init lost `inlineSettleDeadline`) and SessionRunPlaneTests (RunPlane.awaitAnswer needs `runToken`). Both are corrected; the build is green.

    Design (decided here):
    - New public cases `SessionEvent.workStarted` and `SessionEvent.workEnded`, origin `.system`, on streamSessionEvents() only. Consumers with exhaustive switches (Agents, ACPAgent) must add the two cases. They are not changed here.
    - The state is a Mutex on the session actor: phase idle / working / closed, plus a generation count. The start event comes from `noteWorkStarted()`, which runs under the lock at each place where work starts: wakePump (pump task set), mail(_:) (user-type mail put in the queue), compact(prompt:budget:), and respond/complete of an open elicitation (before the run plane resumes the run). Each call adds one to the generation.
    - The end event comes from a check after each signalWorkChange(): the same reads as isIdle(), then, under the lock, the same final check plus "generation did not change". Only then it emits workEnded. Thus the end never comes while new work started.
    - close() sets the phase to closed: no work event after close starts.
    - Found: the sweep of cancelAll() settles runs with no settlement forward, so no work change was signalled. The sweep task now signals a work change when it ends.
    - Task 9: IdleReads gets the tokens of RunPlane.runsWaitingOnlyForUser(). isIdle() ignores those runs. hasPendingOperation keeps reads.openRuns, so it does not change. A recorded elicitation event signals a work change, because elicitation mail cannot start a submission and wakes no answer.
  timestamp: 2026-10-14T17:53:54.221732+00:00
- actor: claude-code
  id: 01m4xsxv6mh21n3yzjn9sw7m8b
  text: |-
    Implementation landed (parts 10 and 9). Extras is at b68a5d4.

    API names (decided here):
    - New public cases: `SessionEvent.workStarted` and `SessionEvent.workEnded`. Origin `.system`. Only `streamSessionEvents()` carries them. They come in turns, `workStarted` first. After `close()` starts, no work event comes. BREAKING for consumers with an exhaustive `switch` over `SessionEvent` (Agents, ACPAgent): they must add the two cases. Those packages are not changed here. Router call sites updated: SessionOutputHub, SessionAnswerReducer, SessionObserver, Examples/MultiModelGeneration, ScriptedToolAnswerComparisonTests, IntegrationTests RealToolAnswerComparisonTests.
    - Internal: `RoutedSessionActorWorkEvents.swift` with `WorkEventState`, `AskedQuestions`, `QuestionAnswer`, `QuestionAnswerOutcome`, `noteWorkStarted()`, `workDidChange()`, `reportWorkEndIfIdle()`, `endWorkEvents()`, `noteWorkStart(answering:with:)`, `noteAnswer(to:outcome:startedWork:)`, `noteQuestionAsked(_:)`. `isIdle()` now uses `readIdleState()`. `IdleReads.openQuestions` (from `RunPlane.openElicitations()`). `hasPendingOperation()` is now internal (was private) for the test; its logic does not change.

    Where the events come:
    - Start (before the first output of the work): start of an answer of the pump (`runAnswer`), user-type mail put in the queue (`mail(_:)`), `compact(prompt:budget:)`, and `respond`/`complete` of an open question that resumes its run (noted BEFORE the run plane resumes the run).
    - End (after the last output of the change): pump end, run settlement, requested compaction end, cancelAll sweep end (new signal), a journaled question, and an answer that did not resume its run. The last check of `isIdle` and the emit are under the lock of `workEvents`; a start during the reads stops the end.

    Part 9: a run is no work when it has an open question AND the journal recorded that question (`AskedQuestions.wasAsked`). Without the second condition the end came before `elicitationRequested` under load (seen in one run; fixed). One read of `openElicitations()` gives the runs that wait only for the user (same rule as `runsWaitingOnlyForUser()`), so two reads cannot disagree.

    Decisions/notes:
    - A pump cycle that takes no batch gives no work event (the start is at `runAnswer`, not at `wakePump`), so question mail of an idle session gives no start/end pair.
    - URL accept gives no work event; its completion starts the work. The session tracks the mode of each recorded question for this.
    - Shared test fixture `BackgroundingSessionFixture` (SessionIdleWaitTests now uses it).
    - The Extras update needed two test-site fixes: `ToolMountFixtures.toolRun` (no `inlineSettleDeadline`) and `SessionRunPlaneTests` (`awaitAnswer(..., runToken:)`).
  timestamp: 2026-10-14T18:13:53.492837+00:00
- actor: claude-code
  id: 01m4xsy2w3vre3f2t9x6xybwr7
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift; changed SessionEvent.swift, SessionOutputHub.swift, SessionAnswer.swift, SessionObserver.swift, RoutedSession.swift, RoutedSessionActor.swift, RoutedSessionActorIdle.swift, RoutedSessionActorPump.swift, RoutedSessionActorQueueing.swift, RoutedSessionActorCompaction.swift, RoutedSessionActorRunJournal.swift, RoutedSessionActorDrain.swift, NoOpToolCallStop.swift, FoundationModelsRouter.docc/RoutedSession.md, Examples/MultiModelGeneration/main.swift, IntegrationTests/.../RealToolAnswerComparisonTests.swift; tests: new SessionWorkEventTests.swift, new Helpers/BackgroundingSessionFixture.swift, changed SessionIdleWaitTests.swift, SessionRunPlaneTests.swift, ScriptedToolAnswerComparisonTests.swift, Helpers/ToolMountFixtures.swift. `swift build --build-tests`: Build complete, no warnings. `swift test --skip-build --filter 'FoundationModelsRouterTests\.(SessionWorkEventTests|SessionIdleWaitTests|SessionRunPlaneTests|ScriptedToolAnswerComparisonTests|ToolInvocationLivenessTests|ElicitationRoutingTests|NoOpToolCallStopTests|CancelAllSignalTests|MailSignalTests|SessionObserverTests|PerCallMountSessionTests|RespondRunPlaneDrainTests|SessionDrainTests|AwaitAnswerTests|PendingEventInjectionTests)'`: "Test run with 160 tests in 15 suites passed".
    - next: /test (full suite), then /review. Consumers Agents and ACPAgent must add the new cases `.workStarted` and `.workEnded` to their exhaustive switches.
  timestamp: 2026-10-14T18:14:01.347474+00:00
- actor: claude-code
  id: 01m4xw4xmbzqegfqhw13fkwq3q
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` 0 warnings (only the harmless mlx-swift_Cmlx.bundle line). Final `swift test --skip-build`: "Test run with 1703 tests in 206 suites passed after 6.102 seconds with 1 known issue" (the known issue is the existing withKnownIssue in RealModelHarnessTests). IntegrationTests: `swift build --build-tests` Build complete, 0 warnings, 0 errors (tests not run).
    - fixes: (1) The first full run hung. Live sample showed a lock-order deadlock in SessionOutputHub: emit held the hub lock and called yield, while a cancelled feed held its stream lock and ran onTermination, which took the hub lock (test theNextInputHoldsNoDisplayEvent). Fixed in Sources/FoundationModelsRouter/Session/SessionOutputHub.swift: no onTermination handler takes the hub lock now; emit removes a feed or subscription when its yield answers terminated. (2) 18 issues from the new workStarted/workEnded events in answer-frame helpers. Fixed in Tests/FoundationModelsRouterTests/Helpers/AnswerFrameAssertions.swift (new SessionEvent.isWorkEvent, work events dropped before the frame checks) and OriginAndTerminalEventTests.swift (collectOutputs drops work events; SessionWorkEventTests checks them). (3) IntegrationTests had a stale FoundationModelsExtras checkout (d0d4653, no OpenElicitation); ran `swift package --manifest-cache local update FoundationModelsExtras` there, now b68a5d4.
    - next: review
  timestamp: 2026-10-14T18:52:42.507219+00:00
- actor: claude-code
  id: 01m4xw5tjb134aekcftdxab1d2
  text: |-
    ### commit — changed
    - evidence: 7b04bdd9 feat(session): send work-start and work-end events, and count a user wait as no work
    - next: review
  timestamp: 2026-10-14T18:53:12.139608+00:00
- actor: claude-code
  id: 01m4xwyardv300a2h3mbmc89vs
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (7b04bdd9). Engine: 10 findings (10 confirmed, 6 refuted). Hand checks: 3 findings. Open: RoutedSessionActorQueueing.swift:172; AnswerFrameAssertions.swift:27; BackgroundingSessionFixture.swift:12, :54; SessionIdleWaitTests.swift:182; SessionWorkEventTests.swift:133, :188, :227, :246, :248, :272, :293; SessionOutputHub.swift:251.
    - Hand check with no finding: the work events alternate. Each start and each end goes out under the workEvents lock, the end checks that the start count did not change, and the closed phase stops each event after close() starts.
    - next: implement the 13 open items. The card stays in review.
  timestamp: 2026-10-14T19:06:35.149739+00:00
- actor: claude-code
  id: 01m4xwz6r14pfat8t4qkkaxzx2
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — work events, user-wait idle, new SessionWorkEventTests
    - test: green — swift test, 1703 tests in 206 suites passed; IntegrationTests build clean; hub lock-order deadlock fixed
    - commit: 7b04bdd9
    - review: findings — RoutedSessionActorQueueing.swift:172, SessionOutputHub.swift:251, AnswerFrameAssertions.swift:27, BackgroundingSessionFixture.swift:12, :54, SessionIdleWaitTests.swift:182, SessionWorkEventTests.swift:133, :188, :227, :246, :248, :272, :293
  timestamp: 2026-10-14T19:07:03.809322+00:00
- actor: claude-code
  id: 01m4xycqxn2pjvm2g6he7xyz0x
  text: |-
    Implement pass 2: the 13 findings of 2026-10-14 13:53 are done.

    Hub leak (SessionOutputHub.swift), design chosen: a separate small lock of stopped keys. Each feed and each mail subscription now has a termination handler (makeReaderStream(key:)). The handler takes only `stoppedReaders` (a Mutex<Set<ULID>>) and puts its key in it. It never takes the hub lock. Each hub operation on readers (makeFeed, finishFeeds, subscribe, unsubscribe, emit, close, readerCount) runs through withLiveReaders(_:): under the hub lock it takes and empties `stoppedReaders` and removes those keys from feeds and subscriptions, then does its work. Lock order: stream lock -> stoppedReaders; hub lock -> stoppedReaders; hub lock -> stream lock (yield in emit). stoppedReaders is always the last lock, so no cycle: the old deadlock (handler takes hub lock under stream lock while emit holds hub lock and yields) cannot come back. The handler is set before the hub records the reader, and the stream is not given out before the record, so a key is never drained before it is recorded. The handler captures the hub weak (no retain cycle hub -> continuation -> handler -> hub). The other choice (copy continuations, yield after release, serial emit) was not taken: it needs a second order guarantee for emit and changes more code. Test: MailSubscriptionTests.stoppedReadersLeaveTheHub makes a feed and a subscription on a hub with no output, drops them, and reads `readerCount` == 0 (RED first: 1 issue; GREEN after).

    Deterministic tests (SessionWorkEventTests.swift): each test that has work at the same time now fixes the order.
    - New helper checkWorkEndAfterThePump(of:): waits on `idleChanges` until `isPumpRunning` is false (the pump clears its task before its workDidChange signals idleChanges), then runs `reportWorkEndIfIdle()` to its end. The test runs it while the run is held at a gate, then opens the gate. A work-end event while a run is open is then always before the run outputs.
    - theWorkEndComesAfterTheRunOutputs: check after the pump, then gate.open.
    - aRunThatWaitsOnlyForTheUserIsNoWork: now a fake run (trackFakeRun) asks through a ToolContext whose sink is ElicitationPostings (keeps the event, no journal). Prompt, pump end, check, `isIdle() == false`, then the test posts the kept event to the outbox (journal). The window "question open, not journaled" is now fixed.
    - AskingTool has an askGate and a returnGate. The asking phase opens askGate only after the pump end check; the resumed phase opens returnGate only after the check (for the respond path, after the `.answered` of the elicitation-mail answer).
    - Verified against wrong implementations (then restored, git diff of RoutedSessionActorIdle.swift is empty): (1) open-run check dropped -> theWorkEndComesAfterTheRunOutputs, aRunThatWaitsOnlyForTheUserIsNoWork, anAnswerStartsWorkBeforeTheResumedRun, aURLAcceptIsNoWorkAndItsCompletionIs fail; (2) askedQuestions check dropped -> aRunThatWaitsOnlyForTheUserIsNoWork fails (isIdle and the elicitationRequested order), the others pass.

    Duplication:
    - RoutedSessionActorQueueing: one private deliverAnswer(toElicitation:_:orReturn:outcome:through:) (parse, noteWorkStart, run plane call, noteAnswer). respond passes runPlane.respond plus the postElicitationAnswer branch; complete passes runPlane.complete. The old deliver(toElicitation:) is gone.
    - New Helpers/SessionFixtureLifecycle.swift (start/end). BackgroundingSessionFixture calls it and gets sessionActor() (the two suites had copies of actor(of:)). NoOpToolCallModel.swift not edited, per the finding: follow-up task ^9jbbzj7.
    - SessionIdleWaitTests: the end(_:opening:) forwarder and actor(of:) are gone; call sites use fixture.end(...) and fixture.sessionActor().
    - New Helpers/SessionOutputPositions.swift: SessionEventCase (case name, matches(_:)), SessionEvent.caseName, firstPosition(in:where:), position(of:in:), position(ofFirst:in:). SessionWorkEventTests, RunMailOriginTests and CancelAllSignalTests use it (their private index(of:in:) are gone); CompactionSignalTests OutputLog.firstIndex uses firstPosition. No inline `if case ... { true } else { false }` predicate is left in SessionWorkEventTests.
    - PendingElicitationFixtures: makeContext(for:postingTo:completionToken:) moved here from ElicitationRoutingTests (now shared), and ElicitationPostings keeps the posted events (postedEvents).
    - AnswerFrameAssertions: doc key `allEvents`, and the stale `events` name in the summary and Returns lines too.

    Note for the next agent: the files tool `replace_all` changed only one site per call in this run; write the whole file when many sites change.
  timestamp: 2026-10-14T19:31:55.957062+00:00
- actor: claude-code
  id: 01m4xycztcta7gd5p3ccmqfnps
  text: |-
    step: implement
    outcome: changed
    evidence: Sources/FoundationModelsRouter/Session/SessionOutputHub.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift; Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift, SessionIdleWaitTests.swift, MailSubscriptionTests.swift, CancelAllSignalTests.swift, CompactionSignalTests.swift, RunMailOriginTests.swift, ElicitationRoutingTests.swift, Helpers/AnswerFrameAssertions.swift, Helpers/BackgroundingSessionFixture.swift, Helpers/PendingElicitationFixtures.swift, new Helpers/SessionFixtureLifecycle.swift, new Helpers/SessionOutputPositions.swift. `swift build --build-tests`: Build complete, no compiler warnings (only the mlx-swift_Cmlx.bundle note). `swift test --skip-build --filter 'FoundationModelsRouterTests\.(SessionWorkEventTests|SessionIdleWaitTests|MailSubscriptionTests|CancelAllSignalTests|CompactionSignalTests|RunMailOriginTests|ElicitationRoutingTests|SessionRunPlaneTests|MailSignalTests|SessionObserverTests|RespondRunPlaneDrainTests|SessionDrainTests|AwaitAnswerTests|PendingEventInjectionTests|OriginAndTerminalEventTests|NoOpToolCallStopTests)'`: "Test run with 175 tests in 16 suites passed after 0.251 seconds." 13 of 13 findings checked. Follow-up ^9jbbzj7 (NoOpToolCallSessionFixture uses SessionFixtureLifecycle).
    task: ^5kbfsyv
  timestamp: 2026-10-14T19:32:04.044897+00:00
- actor: claude-code
  id: 01m4xyjj7fkxp02v3qqtv9cnde
  text: |-
    ### test - green
    - evidence: swift build --build-tests: 0 warnings (only the harmless Cmlx.bundle "missing creator" note). swift test --skip-build (one run): "Test run with 1704 tests in 206 suites passed after 7.311 seconds with 1 known issue." The known issue is the expected-issue test "the embedding slot every harness profile carries records an issue when anything embeds through it". Extra runs: 25 tests in 13 suites passed; 19 tests in 3 suites passed; XCTest 0 tests, 0 failures. IntegrationTests: swift build --build-tests: Build complete, 0 warnings, 0 errors (tests not run).
    - next: review
  timestamp: 2026-10-14T19:35:06.735612+00:00
position_column: doing
position_ordinal: '80'
title: Session work events and user-wait idle (elicitation Router tasks 9 and 10)
---
Source: elicitation-plan.md, Router tasks 9 and 10. Do not start this task. It is not in the mail plan.

(10) Add two session events on the output stream. They are in order with the other outputs and have the origin .system:
- One event when the session gets work while it had no work.
- One event when the session has no work any more.
Use the same rules as awaitIdle(). Send one event for each change of the work, so that a consumer needs no clock and no poll.

(9) A run that waits only for the user does not count as work, for isIdle() and for these events. hasPendingOperation does not change.

Depends on Extras task 15 (each open question linked to its run token). The Extras card for task 15 is 01M4XHV11H4PHS5ATFT8EF14F9 (^8ef14f9) on the Extras board.

Found by ACPAgent step 4 T5 (^4pjhz63): awaitIdle() is not in order with streamSessionEvents(), and no event tells a change of the work. #elicitation-phase-1

## Review Findings (2026-10-14 13:53)

> Scope: `review sha HEAD~1..HEAD` (commit 7b04bdd9) — reviewed the diffs only — lines this change added or modified. 24 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift:172` `reuse/reuse` — The new body of complete(elicitationId:) repeats the sequence in respond(elicitationId:response:): it notes the work start, calls runPlane, and notes the answer. Only the runPlane call and the post differ. The shared sequence is not in a helper, so the two copies can drift apart. A near-match was not generalized. Move the shared sequence into one private helper. It takes the run plane call as a closure and the response as an optional post step. Then respond and complete each pass their own runPlane call. Keep the postElicitationAnswer branch in respond only.
- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerFrameAssertions.swift:27` `swift/doc-parameter-naming` — The signature now names the parameter `allEvents`, but the doc key on line 23 still says `- Parameter events:`. That key matches neither the internal name nor the external label, so it is a stale name left by the signature change. DocC and Xcode will not resolve it. Change the doc key to `/// - Parameter allEvents: The events of one answer, in order.` and keep the prose as it is.
- [x] `Tests/FoundationModelsRouterTests/Helpers/BackgroundingSessionFixture.swift:12` `duplication/duplication` — The new struct BackgroundingSessionFixture repeats the role of the existing NoOpToolCallSessionFixture. Two fixtures for one job can drift apart. Use one shared session fixture. Either have the changed suites call NoOpToolCallSessionFixture, or move the shared logic into one helper that both fixtures call. Do not edit NoOpToolCallModel.swift in this change. Report that edit as a separate task.
- [x] `Tests/FoundationModelsRouterTests/Helpers/BackgroundingSessionFixture.swift:54` `duplication/duplication` — The new end(opening:) method repeats the teardown of NoOpToolCallSessionFixture.end. The gate opening, close and directory removal can drift apart. Use one shared teardown. Call the existing NoOpToolCallSessionFixture.end logic from the changed code, or extract one helper for the gate, close and cleanup steps and call it from both fixtures.
- [x] `Tests/FoundationModelsRouterTests/SessionIdleWaitTests.swift:182` `reuse/reuse` — The new `end(_:opening:)` helper only forwards to `fixture.end(opening:)`. It adds no behavior, so it is a second name for the same operation. Call `fixture.end(opening:)` directly at each call site, or keep the helper only if it is needed to fill a default argument that the fixture lacks.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:133` `reuse/reuse` — `position(in:of:)` is a fourth private copy of the same 'index of the first output whose event matches, or fail' helper. The copies sit in CompactionSignalTests, RunMailOriginTests and CancelAllSignalTests. Each copy has to be fixed separately. Move one shared helper into Tests/FoundationModelsRouterTests/Helpers and call it from this suite and from the existing suites. If that is out of scope for this change, state the duplication as a known follow-up.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:227` `reuse/reuse` — The `.compactionStarted` predicate is written inline here, the same way as the other predicate copies in this file. Use the shared predicate helper from the fix for line 175.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:248` `reuse/reuse` — The `.elicitationRequested` predicate is written inline here, the same way as the other predicate copies in this file. Use the shared predicate helper from the fix for line 175.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:272` `reuse/reuse` — The `.runSettled` predicate is repeated here, the same as at line 192. Use the shared predicate helper from the fix for line 175.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:293` `reuse/reuse` — The `.runSettled` predicate is repeated here, the same as at lines 192 and 272. Use the shared predicate helper from the fix for line 175.

> Note: The engine refuted the finding for line 175 of SessionWorkEventTests.swift. Line 175 is the first inline `.answered` predicate of the same kind. The findings for lines 227, 248, 272 and 293 tell you to make one shared predicate helper and use it for each inline predicate in the file, line 175 also.

Hand checks (same pass, scope commit 7b04bdd9):

- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:188` `hand/deterministic-test` — `theWorkEndComesAfterTheRunOutputs` opens the gate before it reads the outputs of the first answer. Thus the order of the run settlement and the end of the first pump is not fixed. When the run settles before the pump ends, the pump starts the second answer before it ends, and a wrong implementation that sends `.workEnded` at the end of the pump while a run is open passes the test. The test can pass by chance, so it does not prove that no early `.workEnded` comes while a run is open. Make the order fixed: before `gate.open()`, wait on an explicit event that the first pump ended and that its `workDidChange()` finished. Then require that the outputs read up to that point have no `.workEnded`. Then open the gate and read the rest. Use no sleep, no retry and no time limit.
- [x] `Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift:246` `hand/deterministic-test` — The same cause is in `aRunThatWaitsOnlyForTheUserIsNoWork`. The test does not fix the order of the end of the pump and the journal of the question. A wrong implementation that counts a run with an open question as no work before the journal records the question (no `askedQuestions` check) sends `.workEnded` before `.elicitationRequested` only on some runs, so the test can pass by chance. Fix the order with explicit event waits, so that the test fails each time against that wrong implementation. Remove this cause from each test in the file.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutputHub.swift:251` `hand/resource-leak` — `makeFeed()` and `subscribe(to:)` have no termination handler now, and only `emit(_:failure:audience:)` removes a continuation whose yield returns `.terminated`. A feed whose reader stops stays in `state.feeds` until the next output of the session, `finishFeeds()` or close. On a session with no output, each feed that a consumer makes and drops stays in the hub, so the count of feeds is not bounded by the live readers. The doc of `makeFeed()` says that the feed lives "until its reader stops". (Pending ids, waiters and the audience do not use the termination handler: a waiter ends through `withTaskCancellationHandler`. A mail subscription stays only until the terminal event of its mail or close.) Remove a stopped feed and a stopped subscription with no wait for the next output, and keep the lock order: for example, let the termination handler put the key in a separate lock that holds only the keys of stopped readers, and let `makeFeed()`, `subscribe(to:)` and `emit` remove those keys under the hub lock. Add a deterministic test that makes and drops a feed on a session with no output and then reads the count of feeds.
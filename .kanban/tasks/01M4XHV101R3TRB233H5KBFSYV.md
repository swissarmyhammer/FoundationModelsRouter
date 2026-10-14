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
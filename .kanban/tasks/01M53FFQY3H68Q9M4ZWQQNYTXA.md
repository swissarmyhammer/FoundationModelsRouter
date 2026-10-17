---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53q7b8j4cnaagf4zyfd22f9
  text: |-
    Research (implement step).
    - (a) `SessionEvent.mailDeliveryPaused(_:)` has one documented meaning: the hold of `mailOnlyAnswerLimit` (SessionEvent.swift, the doc of `case mailDeliveryPaused`; MailDeliveryPause.swift: `limit` is "the limit in force ... The session reached it when it held the mail", and `description` says "reached the mailOnlyAnswerLimit of N"; generation-queue.md section 5.4, "The bound on answers that mail alone starts"). The hold of `requeueUndeliveredRunMail` (RoutedSessionActorRecording.swift, `func requeueUndeliveredRunMail`) has a different cause: a submission that did not deliver its mail (no `.prompt` entry). The `cancel()` hold (`holdPendingMail()`) also sends no paused event. Plan: no code change for (a); see the decision comment.
    - (b) `isIdle(startedAt:reading:)` (RoutedSessionActorIdle.swift) counts the working child of a relay only through the open run R (`runTokensWithWorkingChild` is subtracted from the user-wait tokens). The sweep of `cancelAll()` settles R while its body and the relay still run, so P is idle while the child works. Plan: any relay with a working child is work of P, also when R is not open.
    - (c) Agents guards with `questionTarget.userPresence == .interactive` and reads `relay == nil` (FoundationModelsAgents AgentRun+Drive.swift, `drive(_:prompt:questionTarget:observer:)`). Plan: `SubagentQuestionRelay.start` returns `SubagentQuestionRelay?`, `nil` for a headless target. Agents assigns into an optional, so it still compiles.
    - (d) `awaitRelayedQuestionRecorded(_:)` waits on `relayChanges` only for the record or the settle. The doc of the relay says the wait must not end when close STARTS. Plan: end the wait when the close of P ENDED (a flag set at the end of `closeAndAwaitTheEnd()`, then `relayChanges.signal()`). The test uses `ChangeSignal(observingWaiters:)` on `relayChanges` (the same pattern as `idleChanges` and `questionPosts`) and `RecordedWaitResult`, so the old code fails by an assertion, not by a hang.
    - Pin: Extras is pinned at 7a40759. That pin does not have the "settled run gives a new question cancel" change (Extras 7a8df59).
  timestamp: 2026-10-17T01:22:05.714932+00:00
- actor: claude-code
  id: 01m53qn92yhx2mr0393qrtcbgy
  text: |-
    Decision for (a): no code change. `requeueUndeliveredRunMail` sends no `mailDeliveryPaused` event, and this is correct. Reasons:
    1. The event has one documented meaning: the hold of the mail-only answer limit. Sources/FoundationModelsRouter/Session/SessionEvent.swift, the doc of `case mailDeliveryPaused(MailDeliveryPause)`: "The session held new mail and started no answer for it, because `mailOnlyAnswerLimit` answers that only run mail started each started a new background run ... (generation-queue.md, section 5.4)". generation-queue.md section 5.4, "The bound on answers that mail alone starts (^9bxas0w)", ties the event to `SessionOutbox.putBack(holding:)` at the limit only.
    2. The payload cannot describe the requeue hold. Sources/FoundationModelsRouter/Session/MailDeliveryPause.swift: `limit` is "the limit in force ... The session reached it when it held the mail", and `description` renders "reached the mailOnlyAnswerLimit of N; the next caller message carries the held mail". A requeue after a submission that did not deliver its mail (Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, `finishSubmissionAndRequeueIfUnattached` then `requeueUndeliveredRunMail`) reached no limit, so the event would report a false cause to the host, and the log line of category `MailDelivery` would be false too.
    3. The other hold that is not a limit hold, `holdPendingMail()` of `cancel()`, also sends no paused event. The requeue hold follows the same rule. The submission that could not deliver the mail ends its answer with its own terminal event, so the host sees that failure there.
    A new event or a new cause field on `MailDeliveryPause` would be a new public API; the card does not ask for it.
  timestamp: 2026-10-17T01:29:42.238114+00:00
- actor: claude-code
  id: 01m53qngyxkndw761txm0fgr1e
  text: |-
    Implementation landed (b), (c), (d). RED: each new test failed by an assertion before the fix (one run, 3 tests in 1 suite: `isIdleWhileTheChildWorks == false` was false; `relay == nil` was false and `relayCount == 0` was 1; `endedBeforeTheSettle` was false). GREEN: `swift test --filter 'FoundationModelsRouterTests\.(SubagentQuestionRelayTests|RelayedQuestionsTableTests)/'` gave "Test run with 25 tests in 2 suites passed".
    - (b) `RelayedQuestions` keeps only `childWorks` by relay id; `hasWorkingChild` replaces `runTokensWithWorkingChild`. `isIdle(startedAt:reading:)` returns `false` while any relay has a working child, also when the run of the relay is not open (the sweep of `cancelAll()` settled it). The run token of a relay is gone (`openRelay(child:childWorks:)`), because the idle rule does not read it any more. Test: `aParentIsNotIdleAfterCancelAllWhileItsChildWorks`.
    - (c) `SubagentQuestionRelay.start(child:agentName:target:)` returns `SubagentQuestionRelay?`: `nil` for a target whose `userPresence` is not `.interactive`. This matches Agents (`var relay: SubagentQuestionRelay?`, `answersQuestions: relay == nil`), which still compiles. The old test `aHeadlessTargetGivesTheChildQuestionACancelAtOnce` (an interactive child under a headless target, relayed to a cancel) tested the opposite contract; it is replaced by `aRelayDoesNotStartForAHeadlessTarget`.
    - (d) `didEndClose` is set as the last step of `closeAndAwaitTheEnd()` (`endRelayWaits()`), and `awaitRelayedQuestionRecorded(_:)` also ends on it. The wait still does not end when a close STARTS (the documented reason stays). `relayChanges` now observes its waiters, as `idleChanges` and `questionPosts` do, so the test can see a registered wait. Test: `theRelayWaitEndsWhenTheCloseOfTheParentEnded`.
    - New fixture helper `SubagentRelayFixture.runThenEnd(opening:_:)` ends the fixture also when the body throws (T1). The new tests use it.
    - Docs: RoutedSession.docc, generation-queue.md section 5.4 (subagent bullet).
  timestamp: 2026-10-17T01:29:50.301968+00:00
- actor: claude-code
  id: 01m53qrabat8dk9nrr4mftz4qw
  text: |-
    ### implement — changed
    - evidence: RED 3 tests failed by assertion; GREEN `swift test --filter 'FoundationModelsRouterTests\.(SubagentQuestionRelayTests|RelayedQuestionsTableTests)/'` = "Test run with 25 tests in 2 suites passed". Full suite one time, `swift test`, exit 0: "Test run with 1804 tests in 219 suites passed after 3.293 seconds with 1 known issue" (the known issue is the designed `withKnownIssue` of the harness embedding stub), "Test run with 26 tests in 14 suites passed", "Test run with 19 tests in 3 suites passed"; XCTest "Executed 0 tests" x3. `swift build --package-path IntegrationTests --build-tests`: Build complete. The only warning is the SwiftPM build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", no compiler warning.
    - files: Sources/FoundationModelsRouter/Session/{RoutedSessionActor.swift, RoutedSessionActorIdle.swift, RoutedSessionActorRelayedQuestions.swift, RoutedSessionActorForking.swift, SubagentQuestionRelay.swift}, Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md, generation-queue.md, Tests/FoundationModelsRouterTests/{SubagentQuestionRelayTests.swift, Helpers/SubagentRelayFixtures.swift}.
    - (a): no code change, reason in the "Decision for (a)" comment. The coordinating session must know this.
    - next: /review. Not committed.
  timestamp: 2026-10-17T01:31:21.834897+00:00
depends_on:
- 01M53FFKACCYMAKXPXKK8WKXJ2
position_column: doing
position_ordinal: '80'
title: 'Group D: paused event on requeue, idle after cancelAll, relay presence guard, end the relay wait on close'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 3, group D. Each fix starts with a test that fails before the fix.

- [x] (a) `requeueUndeliveredRunMail` (RoutedSessionActorRecording.swift ~213-226) holds run mail and sends no `mailDeliveryPaused` event. Send the event. If there is a correct reason not to send it, record the reason on this card and tell the coordinating session. (Result: no code change; the reason is in the comment "Decision for (a)".)
- [x] (b) After `cancelAll()`, a parent P can be idle while its child still works (RoutedSessionActorIdle.swift ~192-195: a settled run R is not in `openRuns`, so the child-works flag has no effect). P sends `workEnded`, then `workStarted` with no new input. Fix it, or record the design reason on this card and tell the coordinating session. (Result: fixed; `RelayedQuestions.hasWorkingChild`.)
- [x] (c) `SubagentQuestionRelay.start()` has no presence check, so it starts for a headless target. Add the guard (Agents has the same guard today). (Result: `start` returns `nil` for a headless target.)
- [x] (d) `awaitRelayedQuestionRecorded` (RoutedSessionActorRelayedQuestions.swift ~346-348) can wait forever when P finished its close before the relay sends the question up. End the wait on close. (Result: the wait ends when the close ended, `didEndClose`.)
- [x] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes
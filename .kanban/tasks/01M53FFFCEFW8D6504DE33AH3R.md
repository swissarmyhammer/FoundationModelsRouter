---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53kz41atxym1ed0kebm0wk9
  text: |-
    Research and implementation log (implement step):

    - Cause, confirmed in the code: `performCancelAll()` ends the open questions in ONE step (`RunPlane.cancelOpenElicitations()`), then starts the sweep and does not wait for it. A question that a run asks after that step (for example a relayed question of a child, on the token of a run that the sweep did not cancel yet) is recorded by the journal and goes out on the feeds. The sweep can end it only later (a slow canceler holds the sweep), and `close()` ended the feeds right after `performCancelAll()`. So the end went to a finished feed.
    - RED test (fixed order, no hang): `ElicitationEndedEventTests.closeEndsAQuestionThatOpensWhileItsStopWaits`. Q1 (on the token of a fake `.process` run whose canceler is held) holds its end post at a gate, so `cancelOpenElicitations()` of the stop waits. In that window Q2 opens on a token of no run and goes out on the feed. The sweep holds at the canceler, so it cannot end Q2. Red output: `ends.count → 0` ("the feed ended while the second question was open"). Each wait of the test also ends when the question settles with no post (`ContextQuestion.waitUntilSettledOr`), and the fixture closes also when the body throws (new `BackgroundingSessionFixture.endingAfter(opening:_:)`, rule T1).
    - Fix (no design trade-off was needed): `close()` now calls `finishFeedsAfterTheirQuestionsEnded()` (RoutedSessionActorQuestionEnds.swift) inside the same `.system` origin, right after `performCancelAll()`. It ends each open question again, waits for the end and completion posts on their way, and repeats until a check finds no recorded question that is open or has a post on its way, and no question that the journal recorded during the check (new `AskedQuestions.recordedCount`). The feeds finish after that check with no suspension point between them. The order of the other close steps does not change, so each invariant of the memory "RoutedSession cancellation invariants" stays (no lock, no change to the pump, the cancel marks, the sweep or the drain).
    - Discovery: a question that the run plane holds and the journal did not record yet goes to no feed after the end, so it needs no end there. A question that the client answered leaves the run plane before the record notes the answer; the check reads the run plane, so such a question does not keep the loop running.
    - Moved `isQuestion(_:)` from a private helper of SubagentQuestionRelayTests to the shared SessionOutputPositions.swift, so both suites use one copy.
    - Known limit (no change): a hostile child that asks a new question each time its question ends would make a new cycle each time, until the sweep cancels the relaying run (R1 then gives the cancel at once with no post).
  timestamp: 2026-10-17T00:25:10.442915+00:00
- actor: claude-code
  id: 01m53m46dbk9xjx7pdgb5nz48f
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorQuestionEnds.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift, Sources/FoundationModelsRouter/Session/SessionEvent.swift, Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift, Tests/FoundationModelsRouterTests/Helpers/BackgroundingSessionFixture.swift, Tests/FoundationModelsRouterTests/Helpers/SessionOutputPositions.swift, Tests/FoundationModelsRouterTests/SubagentQuestionRelayTests.swift. RED: `swift test --filter 'FoundationModelsRouterTests.ElicitationEndedEventTests/closeEndsAQuestionThatOpensWhileItsStopWaits'` 1 test failed by assertion (`ends.count → 0`), no hang. GREEN: the same filter, 1 test passed. Full `swift test` one time: 1795 tests in 217 suites passed with 1 known issue (RealModelHarness `withKnownIssue`), plus 26 and 19 tests passed, exit 0. `swift build --package-path IntegrationTests --build-tests`: Build complete, exit 0. The only warning is the known SwiftPM "missing creator for mutated node" of mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-10-17T00:27:56.715589+00:00
depends_on:
- 01M53FF6DB5XXAG4T9JDMZ1CB9
position_column: doing
position_ordinal: '80'
title: 'R3: end each open question on a feed before close ends the feeds'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 1, rule R3, group A.

Rule R3: each `elicitationRequested` on a feed gets its `elicitationEnded` on the same feed before the feed ends.

Defect: `close()` calls `performCancelAll()` (RoutedSessionActorForking.swift ~433-435), then ends the feeds (~440), and only then runs the drain (~448).

Scenario:
1. A child asks q2 while `performCancelAll()` of P waits.
2. P journals q2 and sends `elicitationRequested` while the feeds are open.
3. The feeds end.
4. The drain closes the child, and the relay ends q2 at P through `endElicitation` (SubagentQuestionRelay.swift ~383-386).
5. That end goes to a finished feed, so a client sees q2 open forever.

- [x] Write a fixed-order test that fails before the fix: q2 is asked in the window of step 1; expect `elicitationEnded(q2)` on the same feed before the feed ends.
- [x] Change the order of close so that each open question ends (on each open feed) before the feeds end. Keep the cancellation invariants (memory: RoutedSession cancellation invariants).
- [x] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes
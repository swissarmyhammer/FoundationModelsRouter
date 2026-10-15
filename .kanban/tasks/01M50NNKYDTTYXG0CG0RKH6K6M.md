---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50v44zjv8nnv9tqwmxqayge
  text: |-
    Implementation notes (implement step):
    - Extras moved to dcdda5d first, then to 9db765a (^jn6qhbn) in the root and in IntegrationTests. Only this repo's sourcekit-lsp was stopped, by pid.
    - API: SessionEvent.elicitationCompleted(ElicitationCompletion); public struct ElicitationCompletion { elicitationId: ULID } with public init. Each exhaustive switch in this repo has the new case (SessionObserver, SessionAnswer, SessionOutputHub Terminal.answer(), Examples/MultiModelGeneration, ScriptedToolAnswerComparisonTests, IntegrationTests RealToolAnswerComparisonTests). Consumers (Agents demo, ACPAgent translator, Multitool ScenarioRunner) must add the case. Do not push before the reviewer gives the word.
    - Origin: no map from run token to run mail exists. The record of the questions (AskedQuestions) now keeps the MailID of the run mail that holds the question (noteAsked(_:runToken:mailID:)). The completion has origin .mail([that id]), the same origin as its elicitationRequested.
    - SessionOutbox.post(elicitationCompleted:) enqueues on the journal chain (enqueueJournalWork). OperationEventJournal has a new requirement record(elicitationCompleted:poster:). The journal calls AskedQuestions.complete(_:postedBy:), then noteWorkStarted(), deliverLive(..., origin:) (drops check), then workDidChange().
    - Discovery: before this task, a completion through ToolContext.complete left the question as acceptedURL in the record, so close() sent a wrong elicitationEnded for it. A completion through session.complete removed the record at noteAnswer, so a later Extras post could not find the question. Fix: new State .completed. noteAnswered(.resumedRun) of an accepted URL question keeps it as .completed (not open, no end) until the Extras post takes it out. The post accepts states url/acceptedURL/completed, and refuses form/ended.
    - Red evidence (before production code, Extras dcdda5d): 3 of 5 tests failed by assertion (found.count == oneCompletion), no hang. The 2 negative tests (form, unknown id) passed before and after: they guard against a too-wide implementation.
    - Order test added after Extras 9db765a: "the completion comes before the first event of the resumed run" (real AskingTool background run; the first event of the resumed run is its runSettled). It passes at 9db765a. It was not run red: at dcdda5d the order was a race, so no fixed red run is possible.
  timestamp: 2026-10-15T22:32:31.986236+00:00
- actor: claude-code
  id: 01m50v4e45j2e5zaejvg44b1r7
  text: |-
    ### implement — changed
    - evidence: Extras at 9db765a (root and IntegrationTests). New files: Sources/FoundationModelsRouter/Session/ElicitationCompletion.swift, Tests/FoundationModelsRouterTests/ElicitationCompletedEventTests.swift (6 tests). Changed: SessionEvent, SessionOutbox, OperationEventJournal, RoutedSessionActorRunJournal, RoutedSessionActorWorkEvents, RoutedSessionActorIdle (doc), SessionObserver, SessionAnswer, SessionOutputHub, RoutedSession.md, Examples/MultiModelGeneration/main.swift, IntegrationTests RealToolAnswerComparisonTests, test helpers PendingElicitationFixtures / SessionOutputPositions, ElicitationEndedEventTests, SessionOutboxTests, ScriptedToolAnswerComparisonTests.
    - red: 3 of 5 tests failed by assertion at dcdda5d before the production code; order test not red-able (race at dcdda5d).
    - green: ElicitationCompletedEventTests "Test run with 6 tests in 1 suite passed". Touched suites "Test run with 78 tests in 5 suites passed". Full suite at dcdda5d: "Test run with 1749 tests in 212 suites passed ... with 1 known issue" (the RealModelHarness tripwire), plus 26 tests / 19 tests passed. Full suite at 9db765a with the order test: exit 0 (its output was not kept, so no count line; it was not run again). Builds: swift build --build-tests and IntegrationTests swift build --build-tests complete, zero Router warnings (only the SwiftPM "missing creator for mutated node" note of mlx-swift).
    - not committed, not pushed. Card stays in doing.
    - next: /review.
  timestamp: 2026-10-15T22:32:41.349805+00:00
position_column: doing
position_ordinal: '80'
title: Session event elicitationCompleted when the run plane completes an accepted URL flow
---
Do not start this task until the Extras card is done that posts a run plane event when an accepted URL flow completes.

- [ ] Add a public SessionEvent case `elicitationCompleted(ElicitationCompletion)`. `ElicitationCompletion` carries the elicitation id (the same ULID as in `elicitationRequested`).
- [ ] The origin is the run mail (`.mail([id])` of the run that asked the question).
- [ ] The session sends the event when the run plane completes an accepted URL flow, from any source (the `complete(elicitationId:)` call of the client or another path that the Extras event reports). It comes before the events of the resumed run.
- [ ] Fixed-order test: the event comes one time, with the correct id and origin, before the first event of the resumed run.
- [ ] This is a new public case. The consumer switches (Agents demo, ACPAgent translator, Multitool ScenarioRunner) change in one step. Do not push before the reviewer is told and gives the word. #elicitation-phase-3
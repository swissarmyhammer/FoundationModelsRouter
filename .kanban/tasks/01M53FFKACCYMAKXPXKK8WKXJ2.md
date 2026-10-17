---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53mrmdb50d23y601y9ewgsw
  text: |-
    Research (implement step):
    - Live path: the live context already excludes q. The journal writes each run event only to the recorder (`append(partial:)` -> `appendToRecorder`), not to the backend. The outbox makes no run mail for a relayed question (`SessionOutbox`: `guard event.elicitation?.isRelayed != true`). A live fork seeds from `settledTranscript` (backend entries), so a live fork also excludes q.
    - Restore path: `SessionTreeRestoration` seeds each node from `TranscriptTree.effectiveTranscript(forSession:)` -> `ContextRenderer.context(of:)`. That render keeps each `.toolOutput` entry of the journal, so q is in the context of a restored P, and of a restored fork of P when the fork cut is after q.
    - A second restore leak: `TranscriptTree.lostRunTerminalEvents(in:)` gives the detail of an orphaned run from `newest.elicitation?.message`. When the newest event of the relaying run is a relayed question, the manufactured `.lost` terminal carries q as run mail to the next prompt.
    - Identification: `ElicitationRequest.agentPath` is persisted (encoded when not empty, decoded with default []), so `isRelayed` (agentPath not empty) identifies relayed questions in old journals too. No new journal kind is necessary; old journals stay readable.
    - Plan: filter in `ContextRenderer.context(of:)` — remove each `OperationEventSegment` whose event is a relayed question from each rendered entry, and drop a `.toolOutput` entry that then has no segment. In the orphan scan, a relayed question does not give the detail of the lost terminal.
  timestamp: 2026-10-17T00:39:06.411283+00:00
- actor: claude-code
  id: 01m53nh2rydhtvtp5a3fvn8jwt
  text: |-
    RED then GREEN:
    - RED (one run, 3 failures): `RelayedQuestionContextTests` restore test failed at the check that the restored P context holds no q; fork test failed for the restored fork and for a live fork of the restored P. `SessionTreeRestorationLostRunTests/orphanedRunKeepsTheRelayedQuestionOutOfItsLostDetail` failed (detail was the relayed question message).
    - What did not work first: the lost-detail test passed before the fix when the progress and q were both posted before the answer. Cause: the delivered run mail of the progress is read after q in the stream, so it was the newest event. The test now posts q after the answer (new `journaledAfterTheAnswer` parameter of `recordAndRestore`).
    - Mechanism: no new journal kind. `ContextRenderer.context(of:)` now ends with `OperationEventSegment.removingRelayedQuestions(from:)`: it removes each `OperationEventSegment` of an `.elicitation` event whose request has a non-empty `agentPath` (`ElicitationRequest.isRelayed`), and drops a `.toolOutput` entry with no segment left. `agentPath` is in the recorded JSON, so old journals are filtered the same way. The orphan scan keeps a relayed question from replacing an older event of its run, and `lostDetail(of:)` never uses the message of a relayed question.
    - Live path: already excluded q before the fix (journal writes only to the recorder, no run mail for a relayed question, live fork seeds from the backend transcript). The new restore test also checks the live transcript of P.
    - GREEN: `swift test --filter 'FoundationModelsRouterTests\.(RelayedQuestionContextTests|SessionTreeRestorationLostRunTests|PlanRestorationTests)'` 17 tests in 3 suites passed.
  timestamp: 2026-10-17T00:52:27.550243+00:00
- actor: claude-code
  id: 01m53nmtkepm8k0cd2vsabjvyj
  text: |-
    ### implement — changed
    - evidence: `swift test` (one run) 1798 tests in 218 suites passed, 0 failures, 1 known issue (the intended `withKnownIssue` test of RealModelHarness); `swift build --package-path IntegrationTests --build-tests` Build complete, exit 0. No compiler warning (only the SwiftPM "missing creator for mutated node" line, which is not from the code). Files: Sources/FoundationModelsRouter/Session/OperationEventSegment.swift, Sources/FoundationModelsRouter/Recording/ContextRenderer.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift (doc), Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift (doc), Sources/FoundationModelsRouter/Session/SubagentQuestionRelay.swift (doc), Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md (doc); tests: Tests/FoundationModelsRouterTests/RelayedQuestionContextTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/TranscriptEntrySegments.swift (new, shared read moved from PlanRestorationTests), Tests/FoundationModelsRouterTests/PlanRestorationTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift, Tests/FoundationModelsRouterTests/Helpers/{RouterTestFixtures,SessionFixtureLifecycle,BackgroundingSessionFixture,SubagentRelayFixtures,NoOpToolCallModel}.swift (optional `recordingsDir`).
    - next: /review. Not committed.
  timestamp: 2026-10-17T00:54:30.254215+00:00
depends_on:
- 01M53FFFCEFW8D6504DE33AH3R
position_column: doing
position_ordinal: '80'
title: 'R5: a relayed question is not model input, also after restore and fork'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 2, rule R5, group C.

Rule R5: a relayed question is not model input.

Defect: RoutedSessionActorRunJournal.swift (~57) writes each run event as `.toolOutput`, and a relayed question is a run event. `ContextRenderer.context(of:)` puts that entry into the context after a restore or a fork (ContextRenderer.swift ~97-102, TranscriptReconstruction ~237-260). So after a restore of P, or a fork of P, the model of P reads the question q.

- [x] Write a fixed-order test that fails before the fix: a child relays q to P; restore P (and, in a second test, fork P); the context of the model does not contain q.
- [x] Fix: the relaying level keeps the question in its journal, but not in the context. This must also be true after restore and after fork. Keep the other run events in the context as they are now.
- [x] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes
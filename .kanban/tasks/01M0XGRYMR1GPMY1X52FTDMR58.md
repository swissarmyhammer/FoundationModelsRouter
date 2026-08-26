---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0y5jwfwn3bbq3zns1dsawra
  text: |-
    Research done. Findings:
    - Terminal delivery path today: RunEventFunnel -> SessionOutbox.post(event:) -> stage + wakeUp + journal chain -> RoutedSessionActor.record(event:) (journal). The mailbox settles only after post returns, so a settled run always has its terminal staged and journaled.
    - Gap confirmed: dispatchNextPrompt() with no queued prompt re-queues the drained events and returns nil. awaitQueuedWork() returns at once for the pending terminal, so a driver loop spins and the model never hears the terminal.
    - Streaming surfaces: SessionEvent has no case for a run's terminal. The turn's own sink (currentTurnEventSink) is set for the whole turn, so a run that settles inside the turn can be reported on the per-turn stream from record(event:).
    - Plan: (1) add SessionEvent.runSettled(OperationEvent); record(event:) delivers it through the current turn sink or the session feed (same route as deliver(invocation:)). (2) dispatchNextPrompt(): an event-only drain that holds a .completed event runs a delivery turn with a fixed delivery prompt; a progress-only drain re-queues as before. (3) Shared test fixture (BackgroundingBackend, LatchedBackgroundTool) moved to Tests/.../Helpers so PromptQueueTests, RespondRunPlaneDrainTests and SessionOutboxToolWiringTests use one copy.
    - Exhaustive switches over SessionEvent that need the new case: TurnOutcome.apply, SessionProjection.apply, ScriptedToolTurnComparisonTests, IntegrationTests RealToolTurnComparisonTests, Examples/MultiModelGeneration/main.swift.
  timestamp: 2026-08-26T04:34:49.980601+00:00
- actor: claude-code
  id: 01m0y618mw7grmwk2xh2qv2jzj
  text: |-
    Implementation landed (TDD: the two gap tests were red first — streamEvents runSettled and the empty-queue delivery turn; the five signal tests and the timedOut test passed on the respond surface at once, which pins that surface).

    Delivery rule: a dispatch that finds no queued prompt but a staged `.completed` event runs a delivery turn with `RoutedSessionActor.settledRunDeliveryPrompt`; a progress-only or elicitation-only wake re-queues and runs no turn. Every run terminal is also delivered live as the new `SessionEvent.runSettled(OperationEvent)` through the turn sink or the session feed (`RoutedSessionActor.deliverLive(_:)`, shared with `deliver(invocation:)`).

    Production files: SessionEvent.swift (new case), RoutedSessionActorRunJournal.swift, RoutedSessionActorTurnExecution.swift (dispatchNextPrompt split into deliverSettledRunsIfAny / runDispatchedTurn), RoutedSessionActorGeneration.swift (settledRunDeliveryPrompt, respond doc), RoutedSessionActorQueueing.swift and RoutedSession.swift (docs), TurnOutcome.swift and SessionProjection.swift (exhaustive switch arms). Also the exhaustive switches in ScriptedToolTurnComparisonTests, IntegrationTests RealToolTurnComparisonTests, and Examples/MultiModelGeneration/main.swift.

    Test fixtures: BackgroundingBackend, BackgroundingLLMContainer, LatchedBackgroundTool and BackgroundFixtureArguments moved from RespondRunPlaneDrainTests into Tests/FoundationModelsRouterTests/Helpers/BackgroundingBackendFixtures.swift so PromptQueueTests and SessionOutboxToolWiringTests share one copy. The existing test `streamEventsKeepsBackgroundingItsBackgroundRuns` kept every assertion; only its title lost the word "unchanged".

    Not done on purpose: SessionOutboxToolWiringTests still holds its own private GatedBackgroundTool (FakeToolArguments) because ToolInvokingBackend and many existing tests cast to BackgroundTool<FakeToolArguments>; replacing it would rewrite existing tests.
  timestamp: 2026-08-26T04:42:41.180098+00:00
- actor: claude-code
  id: 01m0y61fj5qkcayfrfd120v6vr
  text: |-
    ### implement — changed
    - evidence: 16 files — Sources/FoundationModelsRouter/Session/{SessionEvent,RoutedSessionActorRunJournal,RoutedSessionActorTurnExecution,RoutedSessionActorGeneration,RoutedSessionActorQueueing,RoutedSession,TurnOutcome,SessionProjection}.swift, Tests/FoundationModelsRouterTests/{RespondRunPlaneDrainTests,PromptQueueTests,SessionOutboxToolWiringTests,ScriptedToolTurnComparisonTests}.swift, Tests/FoundationModelsRouterTests/Helpers/BackgroundingBackendFixtures.swift (new), IntegrationTests/.../RealToolTurnComparisonTests.swift, Examples/MultiModelGeneration/main.swift. Delivery rule: an empty-queue dispatch that holds a settled run's terminal runs a delivery turn; a run that settles inside a turn is reported as SessionEvent.runSettled on the turn stream. Tests added: startedSignalReachesTheModelAsThePendingEnvelope, progressSignalReachesTheModel, elicitationSignalReachesTheModelAndTheAnswerResumesTheRun, errorSignalReachesTheModelAsAFailedTerminal, doneSignalReachesTheModelAsASucceededTerminal, timedOutRunReachesTheModelAsATimedOutTerminal, streamEventsEmitsTheTerminalOfARunThatSettlesBeforeTheStreamEnds, settledRunOnEmptyQueueRunsADeliveryTurn, progressOnlyWakeOnEmptyQueueRunsNoTurn. `swift build --build-tests`: 0 errors, 0 warnings from our code. `swift test`: 1056 tests in 104 suites passed + 83 in 10 suites, 0 failures (2 pre-existing known issues). IntegrationTests package builds.
    - next: /review
  timestamp: 2026-08-26T04:42:48.261067+00:00
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
position_column: doing
position_ordinal: '80'
title: The five run signals reach the calling model
---
## What
A background run speaks to its calling model with exactly five signals, and each one must reach the model:

1. **"I started"** — the immediate `PendingRunEnvelope` handle (the tool call's return value).
2. **"I am making progress"** — progress events update the run's `latestProgressDetail`; `status` shows them; each one resets `timeout`.
3. **"I need to elicit"** — the run raises an elicitation; the request surfaces to the host/user; only that run suspends until the answer arrives.
4. **"I have an error"** — a failed or timed-out run settles with its honest `OperationOutcome` (`failed`, `timedOut`, `stopped`, `lost`).
5. **"I am done"** — the run settles; one terminal event with the bounded output tail.

Signals 4 and 5 are settlement, and the session must push them to the model on every surface. **Known gap (verified in code):** on the driver-loop surface, a settled run wakes `awaitQueuedWork()`, but `dispatchNextPrompt()` runs no turn when the prompt queue is empty — the events re-queue and the model hears nothing. The streaming surfaces state outright that they do not change. Backgrounding is now the usual path for shell and agent calls, so this gap is the main case, not a corner.

- [x] Design decision to implement: an event-only wake with a settled run runs a delivery turn — `dispatchNextPrompt()` (or a sibling) dispatches a turn that carries the terminal event to the model even with an empty prompt queue. `streamEvents(to:)`/`streamResponse(to:)` emit terminal events for runs that settle before the stream ends; later settlements are delivered by the next dispatch.
- [x] `respond(to:)` keeps its drain (`backgroundRunDrainRoundLimit` rounds) — it already satisfies the contract on that surface.
- [x] Files: `Sources/FoundationModelsRouter/Session/RoutedSession.swift`, `RoutedSessionActorGeneration.swift`, `RoutedSessionActorQueueing.swift`, `RoutedSessionActorRunJournal.swift`.

## Acceptance Criteria
- [x] One test per signal proves it reaches the model surface (five tests).
- [x] A test proves: a driver loop with an EMPTY prompt queue hears a settled run — a delivery turn runs, and the model's next transcript carries the terminal event, with no `wait` call.
- [x] A test proves: `streamEvents(to:)` emits the terminal event of a run that settles before the stream ends.
- [x] A test proves: a `timedOut` run reports `OperationOutcome.timedOut` to the model the same way.
- [x] Full suite green.

## Tests
- [x] Add the cases to `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift`, `SessionOutboxToolWiringTests.swift`, and the prompt-queue tests (`PromptQueueTests.swift`).
- [x] Run `swift test` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
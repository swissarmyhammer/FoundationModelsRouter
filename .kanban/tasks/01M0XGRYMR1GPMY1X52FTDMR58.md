---
assignees:
- claude-code
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
position_column: todo
position_ordinal: '8480'
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

- [ ] Design decision to implement: an event-only wake with a settled run runs a delivery turn — `dispatchNextPrompt()` (or a sibling) dispatches a turn that carries the terminal event to the model even with an empty prompt queue. `streamEvents(to:)`/`streamResponse(to:)` emit terminal events for runs that settle before the stream ends; later settlements are delivered by the next dispatch.
- [ ] `respond(to:)` keeps its drain (`backgroundRunDrainRoundLimit` rounds) — it already satisfies the contract on that surface.
- [ ] Files: `Sources/FoundationModelsRouter/Session/RoutedSession.swift`, `RoutedSessionActorGeneration.swift`, `RoutedSessionActorQueueing.swift`, `RoutedSessionActorRunJournal.swift`.

## Acceptance Criteria
- [ ] One test per signal proves it reaches the model surface (five tests).
- [ ] A test proves: a driver loop with an EMPTY prompt queue hears a settled run — a delivery turn runs, and the model's next transcript carries the terminal event, with no `wait` call.
- [ ] A test proves: `streamEvents(to:)` emits the terminal event of a run that settles before the stream ends.
- [ ] A test proves: a `timedOut` run reports `OperationOutcome.timedOut` to the model the same way.
- [ ] Full suite green.

## Tests
- [ ] Add the cases to `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift`, `SessionOutboxToolWiringTests.swift`, and the prompt-queue tests (`PromptQueueTests.swift`).
- [ ] Run `swift test` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
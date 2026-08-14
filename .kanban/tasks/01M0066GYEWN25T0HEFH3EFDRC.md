---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m00a5m7a17fre5vnnxh6wq6p
  text: |-
    Research: the card's three candidate routes are not exclusive — the fix needs two of them together, and the reason is a window rather than a preference.

    - `cancelCurrentTurn()` alone cannot end a parked drain: even reporting `.requested` leaves the caller suspended on `SessionMailbox.wait`, which ignores task cancellation and runs to `ToolContext.waitSecondsCeiling` (86_400 s — one day).
    - A cancellation-aware `SessionMailbox.wait` was rejected: that wait is also the `wait` tool op's surface, and a model-driven bounded wait must not be broken by an unrelated task cancellation. Changing it there would be a much wider contract change than this card asks for.
    - So: the drain races each wait, exactly as `DetachingTool.raceSettlement(of:deadlineNanoseconds:)` races its soft deadline. `RaceGate` — the resume-exactly-once rendezvous that race is built on — was `private` inside `DetachingTool.swift`; it is now internal in `Concurrency/RaceGate.swift`, used by both races rather than copied.

    Decision on what a cancelled drain returns: **the last turn's answer, never a thrown `CancellationError`**. The drain loop already returned the answer for the two cancellation checks it made between rounds, and a detached tool call answers a cancellation by detaching and returning its pending envelope — so throwing for the in-wait case alone would make one surface report a cancellation two different ways.

    Discovery while implementing: registering the drain per *wait* leaves a real window. `endTurn()` clears `currentTurnId`, then the drain suspends on `mailbox.parkedRuns()` before it registers its first gate; a cancellation landing in that suspension would report `.noTurnInFlight` and cancel nothing, and the drain would then wait the run out. Closed by registering the drain for its whole length (`runPlaneDrainCount`, incremented with no suspension after the turn returns) and by re-reading `cancelRequestCount` immediately before each wait registers its gate — there is no suspension between that check and the registration, so a cancellation is either seen by the check or finds a gate to resume.
  timestamp: 2026-08-14T14:17:45.450887+00:00
- actor: claude-code
  id: 01m00a5y2k6v707k8eg7h8f1mt
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Concurrency/RaceGate.swift (new), Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift, Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift, docs/Usage.md
    - red first: both new tests failed for the stated reasons — `cancelCurrentTurn()` reported `.noTurnInFlight`, and neither route ended the parked call inside the bound.
    - green: one bare `swift test` — 938 + 27 + 24 tests, 0 failures, 1 pre-existing known issue (BoundedWaitTests). Every build warning is in the sibling mlx-swift-lm checkout; no warning names a file of this repository.
    - behavior change a consumer must know: `cancelCurrentTurn()` now reports `.requested`, not `.noTurnInFlight`, when a `respond(to:maxTokens:)` is draining the run plane between its turns. Signatures are unchanged. `cancelPrompt(id:)` inherits it and can now report `.turnCancelled` for a draining call.
    - next: /review
  timestamp: 2026-08-14T14:17:55.539150+00:00
position_column: doing
position_ordinal: '80'
title: cancelCurrentTurn() cannot stop a respond() that is draining the run plane
---
Found while landing `^nmpejc5` (`respond(to:)` self-drains the run plane).

## What is true today

`RoutedSessionActor.respond(to:maxTokens:)` now waits, between turns, for every parked run to settle (`settleParkedRuns()`), bounded by `ToolContext.waitSecondsCeiling` per run.

That wait sits **between** turns, so no turn is in flight while it runs:

- `RoutedSession.cancelCurrentTurn()` reads `currentTurnId`, finds `nil`, and reports `.noTurnInFlight`. It cancels nothing.
- `SessionMailbox.wait(completionToken:seconds:)` suspends on a `CheckedContinuation<WaitOutcome, Never>` and ignores task cancellation by design, so cancelling the caller's own task does not end the wait either.

The drain does check both routes **between rounds** (`cancelRequestCount` and `Task.isCancelled`), so a cancellation that lands while a turn is running is honored. A cancellation that lands *inside* a drain wait is not observed until that run settles, its ceiling elapses, or `close()`'s sweep resumes the waiter.

## Why it matters

A caller that starts a long backgrounded job and then wants out has no surface that ends the call. `close()` does end it (the sweep resumes every waiter), but closing the session is a bigger hammer than cancelling one call.

## What a fix probably needs

- A cancellation route that reaches a waiter of the run plane — either `cancelCurrentTurn()` reporting on (and interrupting) a draining call, or a cancellation-aware `SessionMailbox.wait`, or the drain racing each wait against a cancellation signal the way `DetachingTool.raceSettlement(of:deadlineNanoseconds:)` races a deadline.
- A decision on what a cancelled drain returns: the last turn's answer, or a thrown `CancellationError`.
- A test that cancels a call parked in its drain and observes it end.

#eventplan

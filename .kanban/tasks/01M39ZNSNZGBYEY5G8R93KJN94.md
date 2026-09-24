---
assignees:
- claude-code
depends_on:
- 01M39ZNAJWMVZ291SCH8CSJ2HW
position_column: todo
position_ordinal: '8280'
title: Stop holding the generation gate for the whole turn; make a turn that waits for the GPU cancellable
---
## Why

After the queue exists at the executor seam (^8csj2hw), the turn-long gate in `RoutedSessionActor.beginTurn()`/`endTurn()` (`Session/RoutedSessionActorTurnGating.swift`) only blocks: tool time holds the GPU, and a parent tool that waits for a child turn on the same model starves the child. Design: `generation-queue.md`, section 2.

## What to do

1. `beginTurn()` takes only `turnLock`. `endTurn()` releases only `turnLock`. Remove `holdsGenerationPermit`, `admitToGenerationGate`, `acquireGenerationPermit`, `releaseGenerationPermit`.
2. `turnLock` stays for the whole turn. It is the correctness gate (one turn for each session, safe transcript reads). Kanban ^1zt7vyg: "the gate is throughput, not safety".
3. The turn id is minted after `turnLock`, as now. A turn that waits only for a queue place thus has a turn id, and `cancelCurrentTurn()` cancels `inFlightModelCall`, which cancels the queue wait (`waitUnlessCancelled` in the wrapper of ^8csj2hw).
4. Remove the gate from its other holders:
   - `compact(prompt:budget:)` in `RoutedSessionActorCompaction.swift` takes the gate through `beginTurn()`, so step 1 covers it.
   - `generationGate` is given as an argument to `RoutedSessionActor.init` in `RoutedLLM.swift` (the root session), `RoutedSessionActorForking.swift` (a fork), and `Recording/SessionTreeRestoration.swift` (a restored session). These places do not take the gate themselves. Remove the parameter from `RoutedSessionActor.init` and from these call sites when nothing reads it.
   - `LanguageModelProfile.generationGate` and `ResidentModelGates.generation`: remove them when nothing reads them (Recording moved to its own lock in ^8csj2hw).
5. Update the doc comments that name the gate: the protocol doc of `RoutedSession` and of `awaitingUser(_:)` in `RoutedSession.swift`, the `generationGate` / `holdsGenerationPermit` / `borrowsGenerationPermit` / `currentPermitLoan` members of `RoutedSessionActor`, the chokepoint doc in `RoutedSessionActorTurnExecution.swift`, the doc of `performAutoCompaction` in `RoutedSessionActorCompaction.swift`, `LanguageModelProfile.generationGate`, and `ResidentModelGates`.

## Keep these invariants

The memory `routed-session-cancellation-invariants` names constructs that look redundant and are not. Do not weaken: cancel decisions key on `isTurnCancelled`, never on the type of `CancellationError`; `abandonFoldIfCancelled` stays non-`async`; `runTurn` calls `recordFailedTurn(...)` before it rethrows; `try Task.checkCancellation()` after the streaming loop stays. In tests, route a follow-up after a cancel through `awaitCancelledUnwind` / `followUpTurnCompletes`, never a bare `await session.respond(...)`.

## Tests that pin the old lock and must change

`SharedGenerationGateContentionTests`; `ForkConcurrencyTests` (the FIFO-for-each-turn test becomes FIFO for each pass); `TurnCancellationTests` (the tests that cancel a turn parked on the gate); `MultiTurnSessionTests.forkHoldsTurnLockDuringMakeFork`; `NestedGenerationReentryTests` (the `.noTurnInFlight` contract for a turn parked on the gate). Find them with `rg -l "generationGate|holdsGenerationPermit|noTurnInFlight" Tests`. Change each test to state the new contract. Do not delete a test to make the suite green.

## Acceptance Criteria

- [ ] Session A is in a tool body that waits. Session B on the same model completes a full turn during that wait.
- [ ] A turn that waits for a queue place is cancelled at once with `cancelCurrentTurn()`, gives `.requested`, and its caller gets the cancel result. The queue permit count is 1 after.
- [ ] Two sessions with long tool loops take alternate passes (FIFO for each pass).
- [ ] The full suite is green, checked with the real test names (see memory `swift-test-filter-false-pass`). #generation-queue
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cje1sr71s75tx2nvqbtv37
  text: 'Scope decision (user, 2026-09-25, option A). Step 1 removes the permit symbols, and the human-wait release and the permit parts of `GenerationPermitLoan` use them. Thus this task removes the gate and all code that only served the permit: the loan fields `gate`, `holdsPermit`, `lends(over:)`, `setHoldsPermit`, the background-run count, `borrowsGenerationPermit`, `currentPermitLoan`, and the human-wait release (`awaitingUser` becomes `body()` only; `humanWaitDepth`, `humanWaitLenderTurnId`, `beginHumanWait`, `endHumanWait` go). The loan stays only as the tool-call marker for the same-session refusal. ^44y6ba4 then replaces the loan with a light task-local and removes `withGenerationLent`.'
  timestamp: 2026-09-25T15:20:08.760860+00:00
- actor: claude-code
  id: 01m3cjt6h5b7t504e3675ebgyd
  text: |-
    Research done. Findings:
    - Readers of the gate in Sources: `RoutedSessionActorTurnGating` (begin/endTurn, admit/acquire/release, human wait), `runCancellableModelCall` (the loan is made with `gate:` and `holdsPermit:`), `RoutedLLM.makeSession`, `RoutedSessionActorForking.fork`, `SessionTreeRestoration`, `RoutedModel.init` (`gates:` from `PoolEntry.gates`, made in `ModelPool`, passed in `Router.makeRoutedModel`). After the change nothing reads `ResidentModelGates`, so the type and every `gates:` parameter go (fixtures: `HandBuiltProfileFixtures`, `OwningProfileTests`, `EmbedTracingTests`, `RealModelHarness`; `generationGate:` in `SessionSidecarTests` and in two IntegrationTests files).
    - Stub containers with no executor seam (`HookedLLMContainer`, `ToolCallingLLMContainer`, `ObservingLLMContainer`, `SuspendingLLMContainer`, `InstrumentedLLMContainer`) now get no serialization from the Router. Tests that measured overlap over such stubs must move to a container with a queue: `LiveBackendContainer<PassObservingModel>` (the executor seam), or a stub container that owns a `GenerationQueue` and runs each scripted pass in `runPass` (the ^8csj2hw step 4 decision).
    - Tests to restate: `SharedGenerationGateContentionTests`, `ForkConcurrencyTests.generationGateSerializesAndIsFIFO`, `TurnCancellationTests.cancellingATurnSuspendedInAwaitingUserKeepsGatesBalanced`, `NestedGenerationReentryTests` (gate checks, the two loan tests, the `.noTurnInFlight` test), `HumanWaitGateTests` (all gate counts; the re-acquire no longer exists), `RecordingLanguageModelTests.recordingLockLeavesGenerationToTheQueue`, `PooledResidencyTests.concurrentGenerationOnSharedModelSerializes`, `MultiTurnSessionTests` (a MARK names the gate).
    - `LanguageModelExecutorGenerationRequest.enabledTools` exists, so a scripted model can call a tool only in a session that mounts tools. The acceptance tests use this to run a tool session and a plain session over one queued container.
    - `HumanWaitGateTests.turnEndingDuringAReAcquireStrandsNoPermit` (flaky, ^1qpmghh) tests the re-acquire in `endHumanWait`. That code goes in this task (option A), so the test changes to the new contract and the race it measured no longer exists.
  timestamp: 2026-09-25T15:26:46.821876+00:00
- actor: claude-code
  id: 01m3cpcpjsmcvva4asqc0fn6bd
  text: |-
    step: implement
    outcome: done. All acceptance criteria are met. The task stays in doing. It is ready for /review.
    evidence:
    - Production: `beginTurn()` takes only `turnLock`, then mints the turn id. `endTurn()` releases only `turnLock`. The gate, the permit functions and the human-wait release and re-acquire are removed. `awaitingUser` is `try await body()`. `generationGate` is removed from `RoutedSessionActor.init` and from its call sites (RoutedLLM, forking, SessionTreeRestoration). `LanguageModelProfile.generationGate`, `PoolEntry.gates` and `ResidentModelGates.swift` are removed. `GenerationPermitLoan` is now only a tool-call mark (option A; ^44y6ba4 has a scope comment). The docs that named the gate are updated.
    - AC1: `GenerationQueueTurnTests/aToolBodyThatWaitsLetsAnotherSessionCompleteATurn`. AC3: `GenerationQueueTurnTests/twoToolLoopsTakeAlternatePasses`. AC2: `NestedGenerationReentryTests/cancelOnASessionWaitingForAQueuePlaceCancelsItAtOnce` (`.requested`, CancellationError to the caller, `availablePlaces == 1`, `waiterCount == 0`). The GenerationQueueTurnTests were RED before the production change (13 issues, no hang).
    - Restated tests (none deleted to make the suite green): SharedGenerationGateContentionTests is replaced by SharedGenerationQueueContentionTests; ForkConcurrencyTests `generationQueueSerializesPassesAndIsFIFO`; TurnCancellationTests; PooledResidencyTests; NestedGenerationReentryTests; HumanWaitGateTests (9 tests, turn-lock contract); MultiTurnSessionTests (MARK only).
    - ^1qpmghh: `HumanWaitGateTests.turnEndingDuringAReAcquireStrandsNoPermit` is affected. The re-acquire it measured does not exist now, so its race is gone. The test is restated as `turnEndingDuringAnOutOfTurnWaitStrandsNothing`, with no spin on a gate waiter count. It passed 12 x 150 parallel repetitions.
    - Build: `swift build --build-tests` and `swift build --build-tests --package-path IntegrationTests` compile clean. The only warning is the build-system line "missing creator for mutated node" for the mlx-swift_Cmlx bundle, which is not from Swift source.
    - Filter run: `swift test --skip-build --filter 'FoundationModelsRouterTests\.(GenerationQueueTurnTests|NestedGenerationReentryTests|SharedGenerationQueueContentionTests|ForkConcurrencyTests|TurnCancellationTests|HumanWaitGateTests|PooledResidencyTests|RecordingLanguageModelTests|MultiTurnSessionTests|AsyncSemaphoreTests)/'` gives "Test run with 96 tests in 10 suites passed".
    - Parallel stress (swiftpm-testing-helper, 12 processes x 150 repetitions for each suite): NestedGenerationReentryTests, TurnCancellationTests, SharedGenerationQueueContentionTests, ForkConcurrencyTests, HumanWaitGateTests, PooledResidencyTests and MultiTurnSessionTests have 0 failures and 0 crashes.
    - Full suite: `swift test --skip-build`, 6 runs, all exit 0 with "Test run with 1398 tests in 160 suites passed ... with 2 known issues" (the 2 known issues were there before).
    - Found, not caused by this task: under parallel stress, processes that run a real SDK tool loop abort with `_ContiguousArrayStorage deallocated with non-zero retain count 2` in FoundationModels frames. GenerationQueueTurnTests shows it (4 of 12 processes). I built HEAD 158f7bf in a separate worktree: unchanged suites (SessionEventStreamTests, TurnTokenCeilingTests and others) crash the same way, 5 of 12 processes. Filed as ^vg6bmq6.
    - Memory `routed-session-cancellation-invariants.md` is updated: the endHumanWait invariant is gone, and the note about the SDK crash is added.
    task: ^93kjn94
  timestamp: 2026-09-25T16:29:18.809711+00:00
depends_on:
- 01M39ZNAJWMVZ291SCH8CSJ2HW
position_column: doing
position_ordinal: '80'
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

- [x] Session A is in a tool body that waits. Session B on the same model completes a full turn during that wait.
- [x] A turn that waits for a queue place is cancelled at once with `cancelCurrentTurn()`, gives `.requested`, and its caller gets the cancel result. The queue permit count is 1 after.
- [x] Two sessions with long tool loops take alternate passes (FIFO for each pass).
- [x] The full suite is green, checked with the real test names (see memory `swift-test-filter-false-pass`). #generation-queue
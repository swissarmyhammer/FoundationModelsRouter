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
- actor: claude-code
  id: 01m3cqqmjm54hdse5z4ms6y4fb
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 38ece0e). 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsRouterTests/SharedGenerationQueueContentionTests.swift:47 (reuse/reuse).
    - next: Use the `Fixture` struct in GenerationQueueTests.swift again, or add parameters to it, and remove `PassProbe`. Then do the review again.
  timestamp: 2026-09-25T16:52:45.780445+00:00
- actor: claude-code
  id: 01m3cqsk994j12g0t0tn720xv8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 47 files (gate removed; user-approved scope A)
    - test: green — swift test, 1419 passed (1398+2+19), 0 failed, 0 skipped; concurrency suites 3 extra runs clean; IntegrationTests build clean
    - commit: 38ece0e
    - review: findings — Tests/FoundationModelsRouterTests/SharedGenerationQueueContentionTests.swift:47
  timestamp: 2026-09-25T16:53:49.993053+00:00
- actor: claude-code
  id: 01m3cqyqrfygp7wvsq2k6673z5
  text: |-
    Picked up the review finding (reuse/reuse, PassProbe). Research:
    - The same fixture (a ConcurrencyPeakObserver, a RunLatch, an ObservedPassLog and a LiveBackendContainer over a PassObservingModel) has three copies: `GenerationQueueTests.Fixture` (from ^8csj2hw), `SharedGenerationQueueContentionTests.PassProbe`, and inline code in `NestedGenerationReentryTests.cancelOnASessionWaitingForAQueuePlaceCancelsItAtOnce`.
    - `Helpers/ToolLoopPassModel.swift` is a near-copy of `Helpers/PassObservingModel.swift` (find duplicates: 0.97): the same executor, configuration, identity marker, pass log and prompt read. The differences are a tool loop length, an optional step semaphore, and the tool-calling capability.
    - `GenerationQueueTurnTests.makeFixture` is a near-copy (0.95) of `NestedGenerationReentryTests.makeProfile`: a router over a StubModelLoader of one container, then a resolve of the standard test profile.
    Plan: extend PassObservingModel with `toolRounds` and `step` (defaults keep the old behavior) and delete ToolLoopPassModel; add one shared `PassObservingFixture` in Helpers; add `RouterTestFixtures.resolveStandardProfile(over:cacheDir:)` and use it in GenerationQueueTurnTests and NestedGenerationReentryTests. No test and no assertion is removed.
  timestamp: 2026-09-25T16:56:38.415066+00:00
- actor: claude-code
  id: 01m3cr7m7gfjsk043p10nttne4
  text: |-
    ### implement — changed
    - finding fixed: `SharedGenerationQueueContentionTests.swift:47` `reuse/reuse` (PassProbe). The same cause is removed from all the new queue test files:
      - New `Tests/FoundationModelsRouterTests/Helpers/PassObservingFixture.swift`: the one fixture (observer, latch, pass log, model, container, queue, `makeContainer()`). It replaces `GenerationQueueTests.Fixture`, `SharedGenerationQueueContentionTests.PassProbe`, and the inline copy in `NestedGenerationReentryTests.cancelOnASessionWaitingForAQueuePlaceCancelsItAtOnce`.
      - `Helpers/ToolLoopPassModel.swift` is deleted. `PassObservingModel` now takes `step` and `toolRounds` (defaults keep the old behavior; it declares tool calling only when `toolRounds > 0`). `GenerationQueueTurnTests` uses `PassObservingFixture(toolRounds:step:)` and opens the pass latch first.
      - New `RouterTestFixtures.resolveStandardProfile(over:cacheDir:)` replaces `GenerationQueueTurnTests.makeFixture` and the body of `NestedGenerationReentryTests.makeProfile`. `RespondRunPlaneDrainTests.makeProfile` has the same body, but that file is not in this commit, so it is not changed.
    - No test and no assertion is removed.
    - evidence: `swift build --build-tests` clean (only the known "missing creator" build-system line). Touched suites (`GenerationQueueTests|GenerationQueueTurnTests|SharedGenerationQueueContentionTests|NestedGenerationReentryTests`) 6 runs: 24 tests in 4 suites passed each time. Full `swift test` 3 runs: 1398 tests in 160 suites passed (2 known issues), plus 2 and 19, each exit 0. IntegrationTests build clean.
    - note: the `files` edit op did one replacement even with `replace_all: true`; check the count after each edit.
    - next: /review
  timestamp: 2026-09-25T17:01:29.712257+00:00
- actor: claude-code
  id: 01m3crp19dd5nr2hv92wxbrn6y
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (121107f). 0 findings, 0 confirmed, 0 refuted. 8 files reviewed. The prior finding at `SharedGenerationQueueContentionTests.swift:47` (reuse: `PassProbe` duplicated `Fixture`) is checked. The commit replaces the two fixtures with one shared `Helpers/PassObservingFixture.swift`. The rules that declined an item named `Helpers/ToolLoopPassModel.swift`. This commit deletes that file.
    - next: The task is in done. No work remains.
  timestamp: 2026-09-25T17:09:21.837525+00:00
- actor: claude-code
  id: 01m3crshfdg06ev0xbvvr54y7c
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 8 test files (one shared PassObservingFixture; ToolLoopPassModel removed)
    - test: green — swift test, 1419 passed (1398+2+19), 0 failed, 0 skipped; touched suites 3 extra runs clean; IntegrationTests build clean
    - commit: 121107f
    - review: clean — 0 findings
  timestamp: 2026-09-25T17:11:16.717838+00:00
depends_on:
- 01M39ZNAJWMVZ291SCH8CSJ2HW
position_column: done
position_ordinal: ffffff8480
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

## Review Findings (2026-09-25 11:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 41 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, so its declarations are unread

- [x] `Tests/FoundationModelsRouterTests/SharedGenerationQueueContentionTests.swift:47` `reuse/reuse` — The new `PassProbe` struct is a near-duplicate (0.94 similarity) of an existing `Fixture` struct already defined in `GenerationQueueTests.swift`. Creating a parallel copy defeats the purpose of maintaining a single canonical implementation. The existing Fixture should have been reused or extended with parameters to handle any differences in contract. Review the existing `Fixture` in `GenerationQueueTests.swift` line 23, and refactor to reuse it—either as-is, or by adding parameters to handle differences between the queue-general test setup and queue-contention-specific test setup. Maintaining two nearly-identical fixtures creates a maintenance burden.

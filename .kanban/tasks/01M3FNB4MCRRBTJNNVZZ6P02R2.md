---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hetw42s9zr8m95xspg7g6m
  text: |-
    Implementation notes (implement step, iteration 1):
    - Removed the router copies: `Core/ModelRef.swift`, `Concurrency/GenerationQueue.swift`, `Concurrency/GenerationWorker.swift`, `Concurrency/GenerationQueueError.swift`, `Session/GenerationReentry.swift`. Kept `RaceGate`, `AsyncSemaphore`, `CancellableWait` and `SerialAsyncChain`.
    - Choice for the public API: public typealiases in the new file `Sources/FoundationModelsRouter/Concurrency/QueuePrimitives.swift` (`ModelRef`, `GenerationQueue`, `GenerationQueueError` = the `FoundationModelsExtras` types). We did not use `@_exported import FoundationModelsExtras`, because that exports all Extras names (`ModelPool`, `MessageID`, `ToolContext` and others) to router users, and these names clash with the router types until the later tasks remove them. The aliases are sufficient: the examples and `IntegrationTests/` compile with no source change.
    - `import FoundationModelsExtras` is added to each router file that uses an Extras type by its Extras name: `ModelCallMark` and `SubmissionTarget` have no router alias (`RoutedSessionActorAnswerExecution`, `RoutedSessionActorCompaction`, `RoutedSessionActorCompactionYield`, `RoutedSessionActorGeneration`, `BackgroundToolRunner`). The files that use `ModelRef`, `GenerationQueue` or `GenerationQueueError` use the router aliases, which the module declares; inside the router module the router declaration wins over the Extras name, so an import there adds nothing.
    - Differences of the Extras queue that we examined: `submit(isolation:onQueued:_:)`, `isRunning` and `waitingCount` are public in Extras (internal in the router copy). Extras calls `onQueued` on the caller before the job goes into the worker stream (the router copy called it on the worker). `GenerationPassObserver.submissionQueued()` is thread safe, and the queued event still comes before the start event.
    - Removed router tests that Extras owns: the `GenerationQueueWorkerTests` suite (Extras `GenerationQueueWorkerTests` has the same tests), the ModelRef tests in `CoreTypesTests` (Extras `ModelRefTests`), and the "model-call mark itself" tests in `NestedGenerationReentryTests` (Extras `ModelCallMarkTests`). Kept `GenerationQueueWorkerTaskTests` (a whole SDK call over the router `SessionLanguageModel` runs on the worker task) in the renamed file `GenerationQueueWorkerTaskTests.swift`.
    - IntegrationTests: its own ignored `IntegrationTests/Package.resolved` pinned Extras at 8b4706d, which has no queue types. We set that local pin to f4bd503 (the same pin as the root) and ran `swift package resolve --package-path IntegrationTests`. Then `swift build --build-tests --package-path IntegrationTests` passed.
    - Clean build (`swift package clean` then `swift build --build-tests`): no warning in router code (only the mlx-swift C++ warnings and the build-system "missing creator" warning of the mlx bundle).
    - Focused tests: `swift test --filter "RoutedSessionCancellationTests|MessageQueueTests|NestedGenerationReentryTests|GenerationQueue|SubmissionQueueSpikeTests|AnswerCancellation"` ran 79 tests, all pass. Five parallel runs (`--parallel --num-workers 8`) of the cancellation and queue suites: 56 tests each, all pass.
  timestamp: 2026-09-27T12:53:26.786885+00:00
- actor: claude-code
  id: 01m3hetyjacwz9qxkxypmc7tc8
  text: |-
    ### implement — changed
    - evidence: 5 source files removed; added Sources/FoundationModelsRouter/Concurrency/QueuePrimitives.swift; import added in 5 source files; tests changed: CoreTypesTests.swift, NestedGenerationReentryTests.swift, GenerationQueueWorkerTests.swift renamed to GenerationQueueWorkerTaskTests.swift (queue suite removed). swift build --build-tests (clean) passes; focused filter ran 79 tests, all pass.
    - next: /test
  timestamp: 2026-09-27T12:53:29.290438+00:00
- actor: claude-code
  id: 01m3hf3f6fxeggtdq10k67sqv4
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (3c0f397) — findings 0, confirmed 0, refuted 0; 15 files reviewed, 20 .kanban files ignored. The only notes are tool rules that could not read the 6 deleted files.
    - next: none; the task moved to done.
  timestamp: 2026-09-27T12:58:08.463174+00:00
- actor: claude-code
  id: 01m3hf3m01129gtd516hkdj5vf
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — removed 5 router source files; added Concurrency/QueuePrimitives.swift (public typealiases); import FoundationModelsExtras in 5 files; removed the router tests that Extras owns.
    - test: green — swift test: 1448 tests in 173 suites passed (2 known issues are withKnownIssue assertions), 17 tests and 19 tests passed; clean swift build --build-tests with no router warnings; swift build --build-tests --package-path IntegrationTests passed.
    - commit: 3c0f397 refactor(concurrency): use the queue primitives of FoundationModelsExtras (^z6p02r2)
    - review: clean — review sha HEAD~1..HEAD, 0 findings; task moved to done.
  timestamp: 2026-09-27T12:58:13.377317+00:00
position_column: done
position_ordinal: ffffff9e80
title: 'Router: use the queue primitives from FoundationModelsExtras and remove the router copies'
---
## What
Decision (user, 2026-09-26): the core `FoundationModelsExtras` target owns one process-wide model pool, a work queue for each model and a mailbox for sessions. There is no new Extras product or target. The router is one user of it. The registry is another user.

Blocked by Extras task 01M3FN8WD0G0NJ7QAAKSPZ9RW1 (Extras board). That task copies these types into the core `FoundationModelsExtras` target. The Extras work must be pushed first, because `Package.swift` gets Extras by git URL. Update `Package.resolved` to that Extras commit. Pin the commit of 01M3FN8WD0G0NJ7QAAKSPZ9RW1 only (Extras commit a7f4051; later pins: 00dbc07 for the pool and embedder tasks, d143763 for the Mailbox task, and the last hosting commit for the removal task): a later Extras commit adds a public `ModelPool`, and the router has its own public `ModelPool` until task 01M3FNJS6J7KGAJJ5WFEST00WA removes it, so the name is ambiguous. The Extras session pushes that commit separately.

- `Package.swift` does not change: the library target already depends on the `FoundationModelsExtras` product.
- Remove the router copies of the types that are now in Extras:
  - `Sources/FoundationModelsRouter/Core/ModelRef.swift`
  - `Sources/FoundationModelsRouter/Concurrency/GenerationQueue.swift`, `GenerationWorker.swift`, `GenerationQueueError.swift`
  - `Sources/FoundationModelsRouter/Session/GenerationReentry.swift` (`ModelCallMark`, `SubmissionTarget`)
- Extras decision (2026-09-26): the Extras `GenerationQueue` keeps the public API, but its internals are one detached worker loop and one job type. Extras has no `RaceGate`, `AsyncSemaphore` or `GenerationWorker`. Thus the router KEEPS `Concurrency/RaceGate.swift` (used by `Hosting/ToolRun.swift`, `Hosting/BackgroundToolRunner.swift` and `PumpAnswer` until the later tasks remove them), `Concurrency/AsyncSemaphore.swift` and `CancellableWait.swift` (the resolve lock, until task 01M3FNJS6J7KGAJJ5WFEST00WA), and `SerialAsyncChain.swift`.
- The router runs on a different queue implementation after this task. The router tests of the queue and of cancellation are the proof that the behavior did not change.
- Add `import FoundationModelsExtras` to each router file that uses these types. Today only `Hosting/OperationVocabulary.swift` imports it.
- `ModelRef` and `GenerationQueue` are public router API today. Make sure that router users can still use them with no source change (for example a public typealias in the router, or `@_exported import FoundationModelsExtras` if a typealias is not sufficient). Record the choice in the task comment.
- Remove the router tests that Extras now owns (the tests of the types above). Keep the router tests that test router behavior over these types.
- Do not change behavior. Do not run `swift format`.

## Acceptance Criteria
- [ ] No file in `Sources/FoundationModelsRouter/` declares `ModelRef`, `GenerationQueue`, `GenerationWorker` or `ModelCallMark`.
- [ ] `swift build` passes with no warnings (do a clean build, because a build from the cache hides warnings).
- [ ] The router examples and `IntegrationTests/` compile with no source change.

## Tests
- [ ] `swift build --build-tests` passes.
- [ ] `swift test` passes. Make sure that the output shows the full count of tests run.
- [ ] `RoutedSessionCancellationTests`, `MessageQueueTests` and the tests of the re-entrant wait pass with no change.
- Build note (2026-09-27): `Package.resolved` is ignored by git, and it resolves Extras at `f4bd503` (the head of `main`, with all Extras work). Thus the per-commit pins in this task do not apply: build against `f4bd503`. That commit already has public `ModelPool`, `MessageID`, `ToolContext` and other names that the router also declares, so the name-clash guard test moved to task 01M3FPCADD0GTFAV2RANXKE7G0, which removes the last clashing router types.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo
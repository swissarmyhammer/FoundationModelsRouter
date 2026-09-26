---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ff0xrs00231hjd6r6rpp82
  text: |-
    Research and baseline, before the change.

    - `rg -i 'passQueue|pass queue|queued pass'` (without `.kanban`) finds the path only in these places: `SessionLanguageModel.swift` (type doc, `init(wrapping:passQueue:)`, `respond` doc and body, `SessionLanguageModelState.passQueue` and its `init`), the doc of `ExecutorPassthrough`, one test in `GenerationQueueWorkerTests.swift`, one expectation in `GenerationQueueTests.swift`, and `generation-queue.md` section 5.3. No production code gives `passQueue`.
    - Decision on the test `thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput`: it proves only that one pass of the removed path is one queue item and does not see the task-local of the caller. The submission path has its own test in the same suite: `aWholeSDKCallRunsOnTheWorkerTask` submits a whole SDK call over `SessionLanguageModel(wrapping:)` to a `GenerationQueue`, and proves that the call runs on the worker task (it sees no mark), returns the output of its pass, and leaves the queue idle. The control test `theSDKGivesTheCallerTaskLocalToThePass` stays. Thus nothing of the deleted test must be restated; I delete it.
    - Baseline clean build (`swift build --build-tests --scratch-path <scratchpad>/before`): exit 0. Warnings come only from the `mlx-swift` Metal headers, from the package cache and from the `mlx-swift_Cmlx.bundle` node. There is no warning from the project.
    - Baseline periphery 3.x (`periphery scan --skip-build --index-store-path <scratchpad>/before/out --retain-public --relative-results --disable-update-check`), filtered to the project directories: 55 findings. 7 in `Sources/`, 47 in `Tests/`, 1 in another project directory. None names `passQueue` (tests still read it).
    - Baseline `swift test` (full, no `--filter`): 1459 tests in 171 suites, 17 tests in 8 suites, 19 tests in 3 suites. Total 1495. All pass.
  timestamp: 2026-09-26T18:18:16.217851+00:00
- actor: claude-code
  id: 01m3ffavgnpyn2hvdjn4fxkxb1
  text: |-
    Implementation done.

    Correction to the research comment: the baseline periphery count is 54 project findings (7 in `Sources/`, 47 in `Tests/`), not 55. The 55th line was the output of `wc`. No finding is in another project directory.

    What changed:
    - `SessionLanguageModel.swift`: `init(wrapping:)` and `SessionLanguageModelState.init(wrapped:)` have no `passQueue`. `SessionLanguageModelState.passQueue` is gone. `Executor.respond` has no `@Sendable` pass closure and no queue branch: it reports the pass start, defers the pass end, and calls the wrapped executor under the prompt-cache scope. The behavior of the path that production uses (no queue) does not change. The type doc now says that a wrapper holds no queue and runs each pass inside the submission that holds its SDK call. The `Throws` line of `respond` no longer names a `CancellationError` of a queued pass.
    - `ExecutorPassthrough.swift`: the type doc no longer names a pass queue.
    - `GenerationQueueWorkerTests.swift`: deleted `thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput`. The suite doc of `GenerationQueueWorkerTaskTests` now names only a whole SDK call over a `SessionLanguageModel`, submitted as one item. The helper `respondWithMark(over:)` stays, because the control test uses it.
    - `GenerationQueueTests.swift`: deleted the one expectation `first.state.passQueue == nil`. The test stays.
    - `generation-queue.md` section 5.3: the bullet "A recording handle" now says "Done (^rbm6jtz)".

    Deleted tests (1): `GenerationQueueWorkerTaskTests.thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput`. It proved only that one pass of the removed path is one queue item. `aWholeSDKCallRunsOnTheWorkerTask` proves the same fact for the submission path (the call runs on the worker task, returns the output of its pass, and leaves the queue idle), so nothing needed a restatement.

    Not changed, on purpose: `Tests/FoundationModelsRouterTestSupport/ExecutorPassBoundaryProbe.swift` says "The first check is the one a per-pass queue needs". That text is about the proof of spike ^8nqkten, which `generation-queue.md` item 1 keeps on purpose ("the reason that a per-pass queue was possible"). It does not name the removed code.

    Also checked: `GenerationQueue.submit(isolation:_:)` lost its only caller in `Sources/` (the pass queue branch), but it is `public`, so `--retain-public` keeps it, and scripted backends and tests use it. Periphery shows no new finding.
  timestamp: 2026-09-26T18:23:41.589842+00:00
- actor: claude-code
  id: 01m3ffb00pqe95z4qvzrnaq3wn
  text: |-
    ### implement — changed
    - evidence: 5 files. `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`, `Sources/FoundationModelsRouter/Core/ExecutorPassthrough.swift`, `Tests/FoundationModelsRouterTests/GenerationQueueWorkerTests.swift`, `Tests/FoundationModelsRouterTests/GenerationQueueTests.swift`, `generation-queue.md`. `rg 'passQueue' Sources Tests IntegrationTests Examples Tools`: no match. Clean build in a new scratch path: exit 0, 0 project warnings. `swift test` (full): before 1459 + 17 + 19 = 1495, after 1458 + 17 + 19 = 1494, drop of 1 = the deleted test, 0 failures, the same 2 known issues. `swift build --package-path IntegrationTests --build-tests`: exit 0. Periphery (`--skip-build --index-store-path <scratch>/out --retain-public --relative-results`): 54 project findings before (7 Sources, 47 Tests), 54 after, the same set.
    - next: `/review`.
  timestamp: 2026-09-26T18:23:46.198633+00:00
- actor: claude-code
  id: 01m3fft4j50bwx73dsjb3dxms3
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (bd786db); 0 findings, 0 confirmed, 0 refuted; 7 files attempted, 0 failed. The engine did not review generation-queue.md (no validator matches it) and the two .kanban files (.reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-09-26T18:32:02.373062+00:00
- actor: claude-code
  id: 01m3ffx2jjtpfj97p0551j5852
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files (per-pass queue path removed; 1 test deleted)
    - test: green — swift test, 1494 passed (1458+17+19), 0 failed, 0 skipped; IntegrationTests build clean; Periphery 54 before and 54 after
    - commit: bd786db
    - review: clean — 0 findings
  timestamp: 2026-09-26T18:33:38.642322+00:00
position_column: done
position_ordinal: ffffff9880
title: Remove the per-pass queue path of SessionLanguageModel (passQueue), which no production code uses after ^qhf29tg
---
## Why

Task ^qhf29tg removed `RecordingLanguageModel` and `MLXFoundationModelsContainer.languageModel`. That property was the only production code that made a `SessionLanguageModel` with a pass queue (`SessionLanguageModel(wrapping: model, passQueue: generationQueue)`). Now no production code gives `passQueue`. Each backend wrapper has no pass queue, and its session submits each whole SDK call to the `GenerationQueue` of the model (`generation-queue.md`, section 5.3).

The card of ^qhf29tg said: do not remove `passQueue` in that task, a follow-up task does it. This is that task.

Periphery does not report the path, because tests still call it. The path is dead for production.

## What

In `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`:

- [x] Delete the parameter `passQueue` of `SessionLanguageModel.init(wrapping:passQueue:)`. The initializer becomes `init(wrapping:)`. <!-- proof: the diff of SessionLanguageModel.swift; clean build exit 0 -->
- [x] Delete `SessionLanguageModelState.passQueue`, and the parameter `passQueue` of `SessionLanguageModelState.init(wrapped:passQueue:)`. <!-- proof: the initializer is now init(wrapped:); rg passQueue finds nothing -->
- [x] In `Executor.respond(to:model:streamingInto:)`, delete the `guard let passQueue = state.passQueue` branch and the `passQueue.submit(pass)` call. The pass runs directly. <!-- proof: respond now reports the pass start, defers the pass end, and calls innerRespond under withPromptCacheScope; no closure and no queue -->
- [x] Update the doc comments of the type, the initializer, `respond` and the state that talk about a pass queue or a queued pass. <!-- proof: rg -i 'pass queue|queued pass' Sources finds nothing; the Throws line of respond no longer names CancellationError of a queued pass -->
- [x] `Sources/FoundationModelsRouter/Core/ExecutorPassthrough.swift`: update the doc comment that says "unless it has a pass queue". <!-- proof: the diff of ExecutorPassthrough.swift -->

In the tests:

- [x] `Tests/FoundationModelsRouterTests/GenerationQueueWorkerTests.swift`: the test `thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput` makes `SessionLanguageModel(wrapping:passQueue:)`. It tests only the removed path. Delete it, and count it in the test drop. Check that the other tests of that suite (for example `aWholeSDKCallRunsOnTheWorkerTask`) still prove what the worker does. <!-- proof: test deleted; aWholeSDKCallRunsOnTheWorkerTask and the control theSDKGivesTheCallerTaskLocalToThePass stay and pass; the suite doc no longer names a wrapper whose passes are items -->
- [x] `Tests/FoundationModelsRouterTests/GenerationQueueTests.swift`: `wrappersOverOneModelCompareByTheirOwnState` expects `first.state.passQueue == nil`. Delete that one expectation; keep the test. <!-- proof: the diff removes one line; the test passes -->

In the design documents:

- [x] `generation-queue.md`: the bullet "A recording handle (added by ^1psqdm9)" in section 5.3 says a separate task removes the pass queue. Mark it done by this task. <!-- proof: the bullet now says "Done (^rbm6jtz)" -->

Do not run `swift format`.

## Acceptance Criteria

- [x] `rg 'passQueue' Sources Tests IntegrationTests Examples Tools` finds nothing. <!-- proof: rg exit 1, no output -->
- [x] A clean build in a new scratch path (`swift build --build-tests --scratch-path <new dir>`) has zero new compiler warnings. <!-- proof: scratch path <scratchpad>/after, exit 0; the warnings outside /checkouts/ are only the package-cache lines and the mlx-swift_Cmlx.bundle node, as in the baseline -->
- [x] `swift test` (full suite, no `--filter`) passes. The count of tests goes down by the deleted tests only (expected: 1 test). <!-- proof: before 1459 + 17 + 19 = 1495; after 1458 + 17 + 19 = 1494; the drop of 1 is thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput -->
- [x] `swift build --package-path IntegrationTests --build-tests` succeeds. <!-- proof: exit 0; it recompiled FoundationModelsRouter and both integration products -->
- [x] Periphery (`periphery scan --skip-build --index-store-path <dir>/out --retain-public --relative-results`) reports no new finding in `Sources/`. <!-- proof: before 54 project findings (7 Sources, 47 Tests); after 54 (7 Sources, 47 Tests); diff of the two sets with line numbers stripped is empty -->

## Tests

This task removes code and adds no behavior. Record the full-suite count before the change (after ^qhf29tg: 1459 + 17 + 19 = 1495). The remaining suite is the regression guard.

#dead-code
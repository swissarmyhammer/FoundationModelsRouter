---
assignees:
- claude-code
position_column: todo
position_ordinal: 9d80
title: Remove the per-pass queue path of SessionLanguageModel (passQueue), which no production code uses after ^qhf29tg
---
## Why

Task ^qhf29tg removed `RecordingLanguageModel` and `MLXFoundationModelsContainer.languageModel`. That property was the only production code that made a `SessionLanguageModel` with a pass queue (`SessionLanguageModel(wrapping: model, passQueue: generationQueue)`). Now no production code gives `passQueue`. Each backend wrapper has no pass queue, and its session submits each whole SDK call to the `GenerationQueue` of the model (`generation-queue.md`, section 5.3).

The card of ^qhf29tg said: do not remove `passQueue` in that task, a follow-up task does it. This is that task.

Periphery does not report the path, because tests still call it. The path is dead for production.

## What

In `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`:

- [ ] Delete the parameter `passQueue` of `SessionLanguageModel.init(wrapping:passQueue:)`. The initializer becomes `init(wrapping:)`.
- [ ] Delete `SessionLanguageModelState.passQueue`, and the parameter `passQueue` of `SessionLanguageModelState.init(wrapped:passQueue:)`.
- [ ] In `Executor.respond(to:model:streamingInto:)`, delete the `guard let passQueue = state.passQueue` branch and the `passQueue.submit(pass)` call. The pass runs directly.
- [ ] Update the doc comments of the type, the initializer, `respond` and the state that talk about a pass queue or a queued pass.
- [ ] `Sources/FoundationModelsRouter/Core/ExecutorPassthrough.swift`: update the doc comment that says "unless it has a pass queue".

In the tests:

- [ ] `Tests/FoundationModelsRouterTests/GenerationQueueWorkerTests.swift`: the test `thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput` makes `SessionLanguageModel(wrapping:passQueue:)`. It tests only the removed path. Delete it, and count it in the test drop. Check that the other tests of that suite (for example `aWholeSDKCallRunsOnTheWorkerTask`) still prove what the worker does.
- [ ] `Tests/FoundationModelsRouterTests/GenerationQueueTests.swift`: `wrappersOverOneModelCompareByTheirOwnState` expects `first.state.passQueue == nil`. Delete that one expectation; keep the test.

In the design documents:

- [ ] `generation-queue.md`: the bullet "A recording handle (added by ^1psqdm9)" in section 5.3 says a separate task removes the pass queue. Mark it done by this task.

Do not run `swift format`.

## Acceptance Criteria

- [ ] `rg 'passQueue' Sources Tests IntegrationTests Examples Tools` finds nothing.
- [ ] A clean build in a new scratch path (`swift build --build-tests --scratch-path <new dir>`) has zero new compiler warnings.
- [ ] `swift test` (full suite, no `--filter`) passes. The count of tests goes down by the deleted tests only (expected: 1 test).
- [ ] `swift build --package-path IntegrationTests --build-tests` succeeds.
- [ ] Periphery (`periphery scan --skip-build --index-store-path <dir>/out --retain-public --relative-results`) reports no new finding in `Sources/`.

## Tests

This task removes code and adds no behavior. Record the full-suite count before the change (after ^qhf29tg: 1459 + 17 + 19 = 1495). The remaining suite is the regression guard.

#dead-code
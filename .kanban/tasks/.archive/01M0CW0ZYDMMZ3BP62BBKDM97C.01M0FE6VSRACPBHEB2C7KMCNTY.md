---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dptrac5cdmy4tffpr8gmn0
  text: |-
    Research findings:

    1. The router's own code never calls MLX directly for generation. `RoutedSessionActorTurnExecution` runs the model call as an unstructured `Task`, and `withTaskCancellationHandler` awaits `modelCall.value` fully — the router does not abandon GPU work on cancellation.
    2. The generation path is: `RoutedSession` -> Apple `LanguageModelSession` -> `MLXFoundationModels.MLXLanguageModel.Executor` (vendored fork) -> `MLXLMCommon.generateLoopTask` (vendored fork) -> `mlx-swift` Metal backend.
    3. The fork already contains guards for this crash class: the token producer task checks `Task.isCancelled` before each `iterator.next()`, synchronizes the GPU stream at task end, and each consumer loop cancels and awaits the producer task on the throw path before it synchronizes. Comments in the fork name the exact assertion this card records as the invariant those guards protect.
    4. `GatedEvalResidencyTrait.provideScope` catches the suite error, evicts the model, and rethrows. Eviction is cache removal plus ARC release — no direct GPU call.

    Next step: build the smallest reproduction in the integration target — cancel a 1B generation mid-flight, then evict and generate again — to see whether the abort reproduces and where the fault sits (this repository or the fork).
  timestamp: 2026-08-19T19:09:08.300670+00:00
- actor: claude-code
  id: 01m0dqra14nfb9zgg95e19xvkt
  text: |-
    Reproduction and fault location — the answers to the card's three questions:

    ## The abort is real and cheap to reproduce

    A throwaway probe suite in the integration target reproduced the abort in 70 seconds on the 1B model: a `.timeLimit(.minutes(1))` suite that generates sequential full-ceiling turns, so the limit always fires while a generation is on the GPU. The test failure report printed in full ("Time limit was exceeded: 60.000 seconds"), and the process then died on a signal — the same order the gated 30B run showed. Log: scratchpad/timelimit-probe.log. Crash report: ~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-08-19-142216.ips.

    The signal this time was 11 (SIGSEGV), not 6. It is the same crash class at a different point of the same residue: the crash report shows one cooperative-pool thread STILL inside MLX (`CompiledFunction.call` -> `mlx::core::detail::compile` -> `CompilerCache::find` -> `unordered_map::operator[]`, KERN_INVALID_ADDRESS at 0x0) AFTER the cancelled test ended, while a second thread commits a Metal command buffer. The gated run's signal 6 (`_MTLCommandBuffer addCompletedHandler:` after commit) is the same residue caught inside command-buffer teardown instead of the compile cache.

    ## Where the fault is (card question 1 and 2)

    1. Cancellation DOES reach the generation. A plain `Task.cancel()` on a `respond` call unwinds promptly as `CancellationError` (verified by the new green regression test below). Question 2 is answered: Swift Testing's time limit cancels the task and the generation observes it.
    2. BUT the awaiting caller gets its `CancellationError` back BEFORE the generation's GPU work has fully drained. The residue runs on for a short window (sub-second on the 1B; seconds on the 30B, whose one forward pass is long). When the process ends the test run inside that window — which a time-limit failure always does, because nothing runs after the throw — the exit races the still-running MLX work and the process dies.
    3. The unsafe layers are all vendored:
       - Apple `LanguageModelSession.respond` returns the cancellation to the caller while the fork's executor teardown still runs.
       - `mlx-swift-lm` `MLXFoundationModels/MLXLanguageModel.swift` cancels and drains its token-producer task and synchronizes the GPU stream, but that teardown is not synchronous with the `respond` throw the caller sees.
       - `mlx-swift`'s vendored mlx C++ is not safe against the residue: `gpu::eval` runs on the calling thread, `mlx::core::synchronize(Stream)` for GPU calls `gpu::synchronize` directly on the caller's thread (scheduler.cpp, lines 45-54), and both mutate the shared per-stream `stream.buffer` (backend/metal/device.cpp `get_command_buffer`/`commit_command_buffer`) — two threads on one stream give exactly "Completed handler provided after commit call". The global `CompilerCache` (compiled.cpp) is the other victim of the same residue.

    ## What this repository's code does, and does not, do

    - `RoutedSessionActorTurnExecution` awaits `modelCall.value` fully under `withTaskCancellationHandler`; nothing here abandons a generation.
    - No file under `Sources/` calls MLX generation or Metal directly.
    - The new regression test `CancelledGenerationTeardownIntegrationTests` (integration target) proves the safe path: cancel a 1B generation mid-decode -> `CancellationError` -> evict -> reload -> generate -> evict, all in one green 6-second run. It stays green because the process keeps running after the cancel, so the drain residue completes harmlessly.

    ## Verdict on acceptance criterion 2

    The fault is the VENDORED FORK's (mlx-swift-lm and its mlx-swift dependency, with Apple's `LanguageModelSession` cancellation delivery as the trigger), not this repository's. The fix must make the executor's cancellation path block the `respond` throw until the GPU drain completes (fork), or make the mlx core safe against a concurrent residue (mlx-swift). Neither change is possible in this repository.

    ## Blocker

    Acceptance criterion 1 ("A time-limit cancellation of a gated eval ends the test run without aborting the process") is reproducibly false today and cannot be fixed here. Per the card, this work belongs on the fork's own board. Reproduction recipe for that board: an integration-target suite with `.timeLimit(.minutes(1))` whose test runs sequential `respond` calls at `maxTokens: 4096` on `mlx-community/Llama-3.2-1B-Instruct-4bit` past the one-minute mark — 70 seconds, deterministic on this machine.
  timestamp: 2026-08-19T19:25:16.708600+00:00
- actor: claude-code
  id: 01m0dqspx48kk84z0acearec6v
  text: |-
    ### implement — stuck
    - evidence: 1 file added — Tests/FoundationModelsRouterIntegrationTests/CancelledGenerationTeardownIntegrationTests.swift (green: `swift test --filter CancelledGenerationTeardownIntegrationTests` — 1 test passed in 6.0 s). Verification: `Scripts/swift-test.sh --skip IntegrationTests` — 1008 tests in 93 suites passed (1 pre-existing known issue) plus 75 tests in 8 suites passed; `swift build --build-tests -Xswiftc -warnings-as-errors` — clean. The abort was reproduced with a throwaway probe (removed): time limit fired at 60 s mid-generation on the 1B, the report printed, and the process died on a signal; crash report shows a thread still inside vendored mlx (`CompilerCache::find`) after the test ended.
    - next: this card is stuck for this repository. The fault is the vendored fork's (mlx-swift-lm / mlx-swift, triggered by Apple `LanguageModelSession` returning a cancelled `respond` before the GPU drain completes). File the fix on the fork's own board with the 70-second reproduction recipe from the previous comment. Criterion 2 is done; criterion 1 needs the fork fix.
  timestamp: 2026-08-19T19:26:02.660058+00:00
- actor: claude-code
  id: 01m0dqxf32nx2hbc0xg59py3vq
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — the abort is reproduced in 70 s with a 1B time-limit probe, and the fault is located in the vendored mlx fork: the fork's executor leaves GPU work on the shared per-stream command buffer when a cancellation unwinds, and any two threads on one stream then hit the card's Metal assertion. Nothing in this repository's `Sources/` calls MLX directly, so the fix cannot land here.
    - test: green — the new `CancelledGenerationTeardownIntegrationTests` passes in 6.0 s; the hermetic suite 1008 + 75 passed; warnings-as-errors build clean
    - commit: 1555ac8
    - review: not run — the card is stuck on a cross-repo fix
    - blocker: per the no-cross-repo rule, the fix belongs on the mlx-swift-lm fork's own board. This card carries the 70-second reproduction recipe and the crash-report evidence.
    - next: a person files the fix on the fork's board and pins this repo to the fixed revision, then this card re-verifies with the probe recipe
  timestamp: 2026-08-19T19:28:05.730383+00:00
- actor: claude-code
  id: 01m0fe6qvjcbjyrn2d99th5vrv
  text: Moved to the mlx-swift-lm fork's board as card ^3axg80k (id 01M0FE5PQ21FYK42YK73AXG80K), per the cross-repo rule. That card carries the full fault location, the 70-second reproduction recipe, and the crash-report path. This card is archived. When the fork fix lands and this repository pins the fixed revision, re-verify here with the probe recipe; the safe-path regression `CancelledGenerationTeardownIntegrationTests` (commit 1555ac8) stays in this repository.
  timestamp: 2026-08-20T11:16:52.722546+00:00
position_column: doing
position_ordinal: '8380'
title: A gated eval cancelled by its time limit aborts the process on a Metal assertion — signal 6 from `_MTLCommandBuffer addCompletedHandler:`
---
Split out of `^6ssbakk`, which raised `compactionEvalSubsetTimeLimitMinutes` and left this criterion of its own open.

## What happens

The gated subset run of 2026-08-18 16:38 hit its 1800-second limit while sample 7 was inside its fold. The report printed in full, and the process then died on signal 6. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-crit5.log`.

```
-[_MTLCommandBuffer addCompletedHandler:]:1011: failed assertion `Completed handler provided after commit call'
... exited with unexpected signal code 6
```

The order in the log matters and is checked: the `counts:` line and the `unreached:` line both stand ABOVE the signal line, so the run lost no measurement. The abort happens when the time limit cancels a sample that still has work on the GPU.

## Why it is its own task, and not `^6ssbakk`'s

- `^6ssbakk` and `^xscp198` are about the tier's THRESHOLDS. This is about what cancellation does to the process, and the two do not interact: once the limit fits the tier, a healthy run never cancels a sample at all.
- Any fix touches the MLX generation path rather than an eval constant. Check first whether the fault is in the vendored `mlx-swift-lm` fork; if it is, this task belongs on that fork's own board and not on this one.
- The criterion cannot be verified without provoking a time-limit cancellation, which is a gated run.

## What to find out

1. Where the completed handler is added. The assertion says a handler was attached to a command buffer that was already committed, which is a lifecycle fault rather than a cancellation policy.
2. Whether task cancellation reaches MLX at all, or whether Swift Testing's time limit simply tears the task down under a generation in flight.
3. Whether a cancelled generation can be made to drain its command buffer before the task ends.

## Acceptance Criteria

- [ ] A time-limit cancellation of a gated eval ends the test run without aborting the process
- [x] The fault is located, and named as this repository's or as the vendored fork's
#compaction #defect #eval #real-model
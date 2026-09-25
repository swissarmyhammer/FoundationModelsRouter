---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3d926x5gbq2rf0tg43qfr24
  text: |-
    More failures under the same stress (12 processes, --repetitions 30, the filter also holds HumanWaitGateTests, GenerationStallTests, RecordingLanguageModelTests), 2026-09-25, load average 16 to 21:
    - `RecordingLanguageModelTests` "generate holds only the handle's own recording lock; the container's queue keeps two handles apart" fails at `RecordingLanguageModelTests.swift:530` (the check that a pass runs in the queue). HEAD dd1190a: 2 of 12 processes. Tree of ^a0ze9af: 3 of 12. The test waits with its local `spin(until:)`, which counts 100_000 yields and has no clock. Under load the count ends before the pass enters the model. `BoundedWait.spin(until:)` has a wall-clock bound for this reason.
    - `QueuedPassStallWatchTests` "after a queue wait and a tool body, a stall measures only the held pass, and its time in flight is the whole call" fails at `QueuedPassStallWatchTests.swift:213` (`stalls.allSatisfy`). HEAD dd1190a: 1 of 12. Tree of ^a0ze9af: 0 of 12.
  timestamp: 2026-09-25T21:55:38.021886+00:00
- actor: claude-code
  id: 01m3d9eqsae98snncpec6jq70k
  text: |-
    ### test — green
    - evidence: `swift test` at repo root: 1415 + 3 + 19 = 1437 tests, 0 failed, 0 skipped, 2 deliberate `withKnownIssue` assertions (not build failures). Matches the expected 1437 (1407 + 8 new `GenerationQueueWorkerTests`/`GenerationQueueWorkerTaskTests`). `swift build --build-tests`: 0 warnings in first-party files (only a known third-party `mlx-swift_Cmlx.bundle` build-system warning). 3 extra runs of `swift test --filter 'FoundationModelsRouterTests.(GenerationQueueWorkerTests|GenerationQueueWorkerTaskTests|GenerationQueueTests|GenerationQueueTurnTests|SharedGenerationQueueContentionTests|ForkConcurrencyTests|TurnCancellationTests|QueuedPassStallWatchTests)'`: each 54 tests in 8 suites, 0 failed, 0 skipped. `swift build --build-tests` in `IntegrationTests/`: builds clean (same lone third-party warning only).
    - fix: `Package.swift` — the `\(packageName)Tests` test target had no `exclude`/`resources` entry for the new `Tests/FoundationModelsRouterTests/Fixtures/` directory, so `swift build` reported "found 2 file(s) which are unhandled; explicitly declare them as resources or exclude from the target" for `Fixtures/PreRequestRenameRecording/.../session.json` and `transcript.jsonl`. Added `exclude: ["Fixtures"]` to that target, matching the existing `CompactionDemo` target's precedent (fixtures read from disk relative to the source file, not bundled as SwiftPM resources). Warning is gone after the fix.
    - next: none — all green, no commit made per instructions.
  timestamp: 2026-09-25T22:02:28.522705+00:00
position_column: todo
position_ordinal: '9780'
title: 'Find why two tests fail under parallel stress at HEAD: TurnCancellationTests streamEvents cancel, PooledResidencyTests shared model unload'
---
## What

Two tests fail under parallel stress. Both failures occur at HEAD dd1190a, before the change of ^a0ze9af. They are not the SDK crash ^vg6bmq6 and not the `HumanWaitGateTests` timeout ^1qpmghh.

1. `TurnCancellationTests` "cancelCurrentTurn finishes a streamEvents turn with CancellationError, leaving the consumer what it already received" fails at `TurnCancellationTests.swift:1154`: `await delivered.events.contains(.textDelta(HookedSessionBackend.firstStreamedChunk))` is false. This test uses `HookedSessionBackend` and no `GenerationQueue`.
2. `PooledResidencyTests` "a shared model stays loaded while either profile references it, and unloads only once both references are dropped" fails at `PooledResidencyTests.swift:323`: `await spy.evictions == ...`.

## Measurement (2026-09-25, load average about 21 to 28)

12 `swiftpm-testing-helper` processes, `--repetitions 30`, filter
`FoundationModelsRouterTests\.(GenerationQueueTests|GenerationQueueTurnTests|SharedGenerationQueueContentionTests|QueuedPassStallWatchTests|TurnCancellationTests|NestedGenerationReentryTests|PooledResidencyTests|ForkConcurrencyTests)/`
(the command is in the memory note `stub-backend-producer-race.md`).

- HEAD dd1190a: failure 1 in 2 processes, failure 2 in 1 process.
- The tree of ^a0ze9af: failure 1 in 2 processes, failure 2 in 0 processes.

## Next

- Failure 1: find if the consumer loop can miss the first streamed chunk when the cancel comes at once after `insideTool.wait()`. The stream may end before the consumer appends the chunk that it already received.
- Failure 2: find which eviction count the test sees, and why it differs under load.

## Acceptance

- [ ] The stress above gives 0 failures of these two tests over 3 rounds.
- [ ] A regression test or a changed assertion shows the cause, and does not make an assertion weaker. #test-flake
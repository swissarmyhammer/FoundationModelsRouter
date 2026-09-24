---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a2zb3wbfsy198j373a5f64
  text: |-
    Picked up by /implement. Research:
    - Wrapper template: `LanguageModelBoundaryProbeTests.PassthroughProbeModel` and `RecordingLanguageModel.Executor` (`makePassthroughGeneric` builds `Wrapped.Executor(configuration:)` once and calls `respond` directly).
    - The unit target and the gated `IntegrationTests` package both need the wrapper. SwiftPM cannot share source between test targets, so the wrapper, the event log, and the holding tool go in `Tests/FoundationModelsRouterTestSupport` (no `@testable` there). The wrapper is generic over `Wrapped: LanguageModel` and calls `Wrapped.Executor` directly.
    - Scripted model: `ScriptedToolCallingModel` emits `{"value": ...}` arguments. The probe tool thus takes `@Generable { value: String }`.
    - Gated model: `mlx-community/Qwen3-4B-4bit` (the 4B that `PropagationProbeIntegrationTests` and `RealToolTurnComparisonTests` use for tool turns), loaded with `RealModelContainer.load(ref:)`; suite traits `.serialized, .exclusiveRealModel`.
    - Order is read from the POSITION of each event in one locked log, not from clock instants, so two events at the same instant cannot tie.
  timestamp: 2026-09-24T16:11:29.276069+00:00
- actor: claude-code
  id: 01m3a39zm6kxy3541daf0hpd8x
  text: |-
    RESULT: YES. One executor call ends BEFORE the SDK starts the tool body of that call, on the respond path and on the stream path, over the scripted model AND over the real MLXLanguageModel (Qwen3-4B-4bit). The best result holds: "executor exit" comes before "tool body start", with a tool body that holds 1 s (scripted) and 2 s (MLX). The next pass starts only after the tool body ends. A queue place held for one executor call is thus NOT held across a tool body. The queue work (^8csj2hw) can go on; the seam does not need to move into the fork.

    Slow stream consumer:
    - Scripted model: the consumer waits 300 ms after each snapshot. Each of the 2 passes took less than 300 ms, so no pass waited for the consumer.
    - MLX: the tool path of the MLX executor buffers its output and sends few events, so the stream gave only 4 snapshots. Measured with a 20 ms pause: passDurations = [2.42 s, 2.47 s], consumeTotal = 7.10 s, consumer lag after the last pass = 0.09 s. The pass that emits the tool call still ended before the tool body under the slow consumer (asserted). With only 4 events, this run cannot show if a much slower consumer can hold the LAST pass open for its last send; the scripted run shows that the channel does not wait for the consumer.

    Runs:
    - `swift test --filter ExecutorPassBoundaryTests`: 3 tests, 3 passed, 1.6 s. No warnings from the new files (the one build warning, "missing creator for mutated node ... mlx-swift_Cmlx.bundle", is from the build system and existed before).
    - `swift test --package-path IntegrationTests --filter ExecutorPassBoundaryIntegrationTests`: 3 tests, 3 passed, 35.0 s. No warnings.
  timestamp: 2026-09-24T16:17:17.958124+00:00
- actor: claude-code
  id: 01m3a3acb6rfz5krkkq46sdhjw
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTestSupport/ExecutorPassBoundaryProbe.swift (new: PassBoundaryLog, PassBoundaryProbeModel, PassBoundaryProbeTool, PassBoundaryExpectations), Tests/FoundationModelsRouterTests/ExecutorPassBoundaryTests.swift (new, 3 tests), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/ExecutorPassBoundaryIntegrationTests.swift (new, 3 gated tests). `swift test --filter ExecutorPassBoundaryTests` 3/3 passed; `swift test --package-path IntegrationTests --filter ExecutorPassBoundaryIntegrationTests` 3/3 passed; 0 new warnings.
    - next: /review
  timestamp: 2026-09-24T16:17:30.982621+00:00
- actor: claude-code
  id: 01m3a5n4321ndw0rxmjw2f60a6
  text: 'Double-check fix: the doc comment of `slowConsumerPause` in `ExecutorPassBoundaryIntegrationTests.swift` said "A real turn gives hundreds of snapshots". The measured run gave 4. The comment now states the measurement and what this test cannot show. `swift build --package-path IntegrationTests --build-tests`: Build complete, no warning. The design link of this card now points to `generation-queue.md` (repository root), not to the peer session''s temporary scratchpad.'
  timestamp: 2026-09-24T16:58:20.130438+00:00
- actor: claude-code
  id: 01m3aeg1f40qw79mapzmkvdx4q
  text: |-
    ### commit — changed
    - evidence: a818fcc test(queue): prove an executor pass ends before the SDK runs its tool body (^8nqkten); pushed 294dd23..a818fcc to origin/main. Committed at the user's request before /review.
    - next: /review
  timestamp: 2026-09-24T19:32:50.788682+00:00
position_column: doing
position_ordinal: '80'
title: Prove that one executor call ends before the SDK runs the tool body of that call
---
## Why

The per-model generation queue (design: `generation-queue.md` at the repository root; first proposed by the FoundationModelsAgents session on 2026-09-24) holds one queue place for one call of `LanguageModelExecutor.respond(to:model:streamingInto:)`. This is safe only if that call does not stay open while the SDK runs a tool body that the call emitted.

The code did not prove this:

- The doc comment of `runToolGeneration` in the fork's `MLXLanguageModel.swift` (`.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/`) says: "This executor releases the model container BEFORE the SDK runs a tool body: the caller's `perform` closure sends the tool-call delta, then it returns". The fork had to make the `perform` scope small. This is a sign that the tool body can start while the executor call is still open.
- `emitToolCall` in the same file does `await channel.send(...)`. If `send` waits for the SDK to use the event, and the SDK runs the tool before it takes the next event, the executor call stays open for the full tool body.
- If the executor call stays open, a queue place held for that call is held across the tool body. A tool that waits for a child turn on the same model then deadlocks. This is the same deadlock that the queue must remove.

## What to do

1. Write a wrapper `LanguageModel` for tests that records these events in order, with a clock: executor enter, executor exit, tool body start, tool body end. Use it around `ScriptedToolCallingModel` (`Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift`).
2. Do the same test in the gated real-model suite over `MLXLanguageModel`, because the scripted model and the MLX executor can send events in different ways.
3. Do the same test for the stream path (`LanguageModelSession.streamResponse`). Also measure: does a stream consumer that reads slowly keep the executor call open?
4. Do the same test with a tool body that waits (for example 2 s) before it returns.

## Acceptance Criteria

- [x] A test shows, for the respond path, that "executor exit" comes before "tool body end" for a tool body that waits. Best result: before "tool body start".
- [x] The same for the stream path, and a statement about a slow stream consumer.
- [x] The same in the gated real-model suite over `MLXLanguageModel`.
- [x] A comment on this task gives the result. If the executor call stays open across the tool body, stop the queue work and tell the FoundationModelsAgents session. The seam must then move into the fork (release the queue place at the tool-call send, as the fork does for `perform`). #generation-queue
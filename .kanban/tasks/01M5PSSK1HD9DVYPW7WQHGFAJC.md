---
comments:
- actor: wballard
  id: 01m5q4zqxaxzmg9f8xywj5mf8r
  text: 'Done in the card-1 commit. Each pass of SessionLanguageModel calls the model through Extras PooledGeneration.run(ref:channel:_:) under the prompt-cache scope of the session; the whole-call queue submits, ModelHold.queue use, LoadedLLMContainer.submitting(to:), LanguageModelSessionBackend.generationQueue, the GenerationQueue alias, RouterMetrics.recordGenerationQueueWaiting (and its metric name) and SessionEvent.submissionQueued are removed. The start wiring stays: run(_:reportingTo:onStart:) calls observer.submissionStarted() and onStart before the SDK call. Stall watch: generation-queue.md is deleted, so the choice is stated in GenerationStall/GenerationStallWatch.measuredFrom: a pass counts only from its first output event (GenerationCallPhase.firstOutputEvent(at:)) to its end; the wait for the MLX lock and the read of the prompt before the first output count nothing. The containers and backends now carry a ModelRef for the in-flight meter (MLXFoundationModelsContainer.make(wrapping:ref:)). Deviation: GenerationQueueSubmissionTests'' two in-band-wait tests had to be restated here (they are answered now, because the queue check is gone); card ^hga4td7 keeps the own-session refusal, the Router mark and the background case. Tests: ChildStarvationRegressionTests failed first (bounded wait expired at 60 s), then passed; restated suites are listed in the commit body. Dependent packages are not edited (FoundationModelsAgents, FoundationModelsACPAgent, FoundationModelsMultitool); their files are listed in the commit body.'
  timestamp: 2026-10-24T14:28:10.794208+00:00
depends_on: []
position_column: done
position_ordinal: ffffffffc280
title: Call the model through Extras PooledGeneration, with no whole-call queue job
---
## What

Stop submitting whole SDK calls to the per-model `GenerationQueue`. Each routed generation calls the model through Extras `PooledGeneration.run(ref:channel:_:)`, the direct MLX call with the in-flight meter and the cancel. Only MLX's lock serializes, and only for one generation. Tool bodies run outside every lock.

**Depends on FoundationModelsExtras** (other board): "Call the MLX model directly, with an in-flight meter and a cancel that does not wait for the MLX lock" (01M5PSQ1XBPRF64B1NPTCWS0HJ). Start when it is on Extras main, and `swift package update` resolves it.

**Why.** bench24-1023b, django__django-14999: the root started a diagnose child at 07:30:16 UTC. The child's first generation started at 07:53:31, after the root's one SDK call ended. That call was one queue job for 23 min. Transcripts: FoundationModelsACPAgent `bench/preds.bench24-1023b.transcripts/django__django-14999/` (root `01M5PD1HK75AXDHWGW9C9ATHR5`, child `agent-runs/01M5PD2HHJEYZZCTNHR3XE4NR6`).

- [ ] **Call through the helper.** `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift` (`Executor.respond` → `innerRespond`, about 133-152) calls the real model through `PooledGeneration.run`, once for each pass.
- [ ] **Remove every queue seam:**
  - `ModelHold.generationContainer()` → `submitting(to: queue)` (`SlotPoolLoader.swift:145-153`)
  - the requirement `LoadedLLMContainer.submitting(to:)` (`ModelLoader.swift:53`)
  - `LanguageModelSessionBackend.generationQueue` (`LanguageModelSessionBackend.swift:250`)
  - the `LiveModelLoader.swift` uses (about 62-98, 143, 300)
  - `RouterMetrics.recordGenerationQueueWaiting`
- [ ] **Remove the whole-call submits:** `RoutedSessionActorAnswerExecution.swift` (about 1005-1021) and `RoutedSessionActorCompaction.swift:473`. Keep the task-local wrapper `Self.submission(...)` (946-977), because the tool bodies read its bindings. Run it directly in the `modelCall` task.
- [ ] **Keep the start wiring.** `run(_:on:...)` at `:1016-1020` is the only caller of `observer.submissionStarted()` and `onStart`. Call both when the SDK call starts. Several things depend on them: `SessionEvent.submissionStarted`, the stall watch (`GenerationStall.swift:293`), time to first token, and the ACP agent's `promptDidStart` (`SessionProjector.swift:392`).
- [ ] **The stall watch must not count the wait for the MLX lock.** `submissionStarted` and `passStarted` now come before that wait. MLX sends its metadata before it takes the lock (`MLXLanguageModel.swift` about 1067). Arm the "no output" stall at the first generated output of a pass (text, reasoning or a tool call), not at its start, or exclude the MLX lock wait in an other way. Say which in `generation-queue.md`.
- [ ] **`submissionQueued` no longer has a cause.** Stop sending it.
- [ ] **Dependent packages' tests.** These read the removed seams or wait for `submissionQueued`:
  - Agents: `ScriptedProfileTests.swift:153` and `ScriptedSessionBackend.swift:29-137`
  - ACP agent: `QueuedScriptedFixture.swift:116`, `PromptExecutionTests.swift:992`, `ScriptedModel.swift:269-811`, `QueuedScriptedModel.swift:147-192`, and `ACPEventTranslator.swift:370`

  List each one in the commit body. Tell the FoundationModelsACPAgent session, which has a card for its part. Tell the user about the Agents part, because Agents has no session.

## Acceptance Criteria

- [ ] **Regression (fails before the change):** a parent routed session runs one SDK call with a tool body that waits until the test signals it. A child routed session on the same model generates during that wait. Its first generation ends before the parent's call ends.
- [ ] `submissionStarted` and `submissionEnded` come once for each SDK call.
- [ ] A call that waits behind an other session's long generation (on a stub FIFO lock) gives no `GenerationStall`. A pass that has the lock and gives no output for longer than the limit still gives one.
- [ ] `rg -n 'submitting\(to|generationQueue|hold\.queue|queue\.submit|recordGenerationQueueWaiting' Sources` finds nothing in Router.

## Tests

- [ ] New: `Tests/FoundationModelsRouterTests/ChildStarvationRegressionTests.swift` (write it first, and see it fail). Stub generations use a FIFO serial lock, as MLX does, and wait on signals.
- [ ] Restate `Tests/FoundationModelsRouterTests/GenerationQueueSubmissionTests.swift`: `aToolBodyThatWaitsHoldsTheModelUntilItsSubmissionEnds` becomes "a tool body that waits holds nothing", and `twoToolLoopsRunWholeSubmissionsInOrder` becomes "they take turns per generation".
- [ ] Restate or remove as necessary:
  - `GenerationQueueTests`
  - `SubmissionQueueSpikeTests` (`aChildResultDeliveredAsMailCausesTheNextSubmission` must still pass)
  - `SharedGenerationQueueContentionTests`
  - `SummarizerSubmissionTests`
  - `QueuedPassStallWatchTests`
  - `PooledResidencyTests`
  - `SessionChokepointTests`
  - `Tests/FoundationModelsRouterPublicSurfaceTests/GenerationQueuePublicSurfaceTests`

  `ExecutorPassBoundaryTests` must still pass.
- [ ] `swift test` in FoundationModelsRouter: all tests pass, with no new warnings.
- [ ] `swift test` in FoundationModelsAgents and in FoundationModelsACPAgent, resolved against this Router, after their own updates: all pass.

## Workflow

- Use `/tdd`: write the failing tests first, then implement until they pass.
- After the push, tell the FoundationModelsMultitool session that `SearchToolsTool+Seams.swift:30-41` (the selection model must not be the caller's model) is no longer necessary.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3dac6e9sp1w3c5wxyj1sca4
  text: |-
    ### Research done (implement)

    Read: the task, `generation-queue.md` section 5, commit 10cae0b (^a0ze9af), `SubmissionQueueSpikeTests`, the memory notes, and the code of `GenerationQueue`, `GenerationWorker`, `QueuedLanguageModel`, `GenerationPassObserver`, `runCancellableModelCall`, `ModelCallMark`, the stall watch, the compaction summarizers, and the queue test suites.

    Facts that are not in the task description:

    1. `RoutedModel.makeLanguageModel()` gives a consumer a `RecordingLanguageModel` over `container.languageModel`. The consumer drives its own `LanguageModelSession` over it, so the Router never makes that SDK call and cannot submit it as one item. Now its GPU order comes only from the per-pass queue of `QueuedLanguageModel`. `RecordingLanguageModelTests` asserts that two handles never overlap.
    2. Stub backends in `ForkConcurrencyTests` and `PooledResidencyTests` submit each scripted call to their own queue inside `respond` (`runPass`). With no `generationQueue` on the backend, the session runs their call directly, so this pattern still works.
    3. The SDK gives the task-locals of the caller to the executor (`GenerationQueueWorkerTaskTests.theSDKGivesTheCallerTaskLocalToThePass`). So a tool body of a submission that runs on the worker task sees the `ModelCallMark` that the submission closure binds.

    Decisions (and why):

    - D1. `container.languageModel` keeps one item for each pass: `SessionLanguageModel(wrapping:passQueue:)`. A backend wrapper has no queue (`SessionLanguageModel(wrapping:)`). Reason: fact 1. Without it, a recording handle would generate at the same time as a routed submission on one GPU.
    - D2. The refusal check is in `GenerationQueue.submit`, so every submitter gets it (a routed submission, a summarizer call, a pass of a recording handle). `ModelCallMark` names the queue and the `ModelRef` of its submission, and the error takes the model from the mark: `GenerationQueueError.waitInsideOpenSubmission(model: ModelRef)`.
    - D3. `GenerationQueue.runPass` becomes `GenerationQueue.submit`, because the item is no longer a pass. No sibling repository calls `runPass` (checked with `rg`).
    - D4. `.submissionQueued` and `.submissionStarted` are events of an item of a queue. A backend with no queue has no item, so it sends neither event. This is the same rule as `passQueued`/`passStarted` for a backend with no executor seam. ^x7cxsg3 adds the payload (`SubmissionStart`).
    - D5. The session also sends the two events for a summarizer call, because that call is one submission of the session on a queue.
  timestamp: 2026-09-25T22:18:33.801770+00:00
- actor: claude-code
  id: 01m3ddqt1gn80ttbnjp68k0vf1
  text: |-
    ### Implementation landed

    What changed (production):
    - `GenerationQueue.runPass` is now `GenerationQueue.submit` (D3). `submit` refuses a submission from a task with an OPEN `ModelCallMark` on the same queue with the new `GenerationQueueError.waitInsideOpenSubmission(model: ModelRef)` (new file `Concurrency/GenerationQueueError.swift`).
    - `QueuedLanguageModel` is now `SessionLanguageModel` (`Concurrency/SessionLanguageModel.swift`), state `SessionLanguageModelState`. A backend wrapper has no queue and reports pass start and pass end to the observer. The recording handle (`container.languageModel`) gets `SessionLanguageModel(wrapping:passQueue:)` (D1).
    - `LanguageModelSessionBackend.generationQueue` (default `nil`). `MLXFoundationModelsSessionBackend` names the queue of its container; a fork and a replaced transcript name it too.
    - `runCancellableModelCall(composedPrompt:submittingTo:_:)` submits the whole SDK call as one item. The submission binds `ServiceContext`, `ModelCallMark`, `ToolResultAppendBoundary` and `ToolContext`. `ModelCallMark` holds a `SubmissionTarget` (queue + model).
    - Each summarizer tier (`BackendSummarizerTier`) submits to the queue of its own backend (flash container or own model).
    - `SessionEvent.passQueued`/`.passStarted` are now `.submissionQueued`/`.submissionStarted`. `GenerationPassPhase` is now `GenerationCallPhase` (submissionQueued, submissionStarted(at:), passStarted(at:), passEnded). The stall watch counts nothing before the submission starts, and counts from the start of the submission for a backend with no pass reports.
    - Docs updated: `GenerationQueue`, `RoutedSession` (type, `respond`, `streamResponse`, `streamEvents`, `streamSessionEvents`, `awaitingUser`, `cancelCurrentTurn`, `setGenerationStallReportInterval`), `RunToCompletionRunner`, `BackgroundTool.inlineSettleGrace`, `ModelLoader`, `LiveModelLoader`, `RecordingLanguageModel`, `ExecutorPassthrough`, `generation-queue.md` 5.3 (two new bullets).

    More decisions (and why):
    - D6. `GenerationWorker.Ticket` now holds the task of a running item and cancels it synchronously in `markCancelled()`. Reason: the item is now a whole SDK call. `noteToolResult` (compaction yield) and the repetition watch cancel `inFlightModelCall` inside a tool body; the old path cancelled the running item only after a hop to the worker actor, so the SDK could start its next pass first.
    - D7. `beginTurn()` also runs `backend.generationQueue?.refuseWaitInsideOpenSubmission()` before it waits for `turnLock`. Reason: design 5.5 rule 2 refuses "a wait for an answer on a session over Q". Without it, an in-band tool body that asks a BUSY session on the same model waits for that session's turn lock forever, because that session's own submission waits behind the tool body's submission. Test: `anInBandWaitForABusySessionOnTheSameModelIsRefused`.
    - D8. The submission binds the tracing `ServiceContext`. Reason: the worker task inherits no task-local, and `ToolTracingTests` ("a turn with two tool calls opens one turn span and two tool spans, each a child of it") failed without it.
    - D9. `SessionEvent.submissionStarted` is also printed by `Examples/MultiModelGeneration`, because it now fires for each submission of a live container (the example doc said "silent by construction").
    - D10. `SessionReentryError.sameSessionTurnInFlight` text no longer says "Generate on a different session over the same model", because that is now refused in band.

    Tests restated (none deleted, count 1437 -> 1448):
    - `GenerationQueueTurnTests`: `aToolBodyThatWaitsLetsAnotherSessionCompleteATurn` -> `aToolBodyThatWaitsHoldsTheModelUntilItsSubmissionEnds`; `twoToolLoopsTakeAlternatePasses` -> `twoToolLoopsRunWholeSubmissionsInOrder`; `aParentWaitsInAToolBodyForAChildTurnOnTheSameModel` -> `anInBandWaitForASessionOnTheSameModelIsRefused`; new `anInBandWaitForABusySessionOnTheSameModelIsRefused`.
    - `HumanWaitGateTests`: the stub container now owns a queue its backends name. `humanWaitLetsAnotherSessionOnTheSameModelGenerate` -> `humanWaitHoldsTheModelForAnotherSession`; `turnEndingDuringAnOutOfTurnWaitStrandsNothing` now waits for B's submission behind A's.
    - `QueuedPassStallWatchTests`: `aWaitForAQueuePlaceIsNotAStall` -> `aWaitForTheWorkerIsNotAStall` (also asserts the free-worker session sends only `submissionStarted`); 3 new unit tests of the watch and of `GenerationCallPhase.sessionEvent`.
    - `GenerationQueueTests`: backend calls go through `queue.submit`; new `liveBackendDeclaresTheQueueOfItsContainer`.
    - `ForkConcurrencyTests.generationQueueSerializesPassesAndIsFIFO` -> `generationQueueSerializesSubmissionsAndIsFIFO` (the stub backend names the queue).
    - `NestedGenerationReentryTests.cancelOnASessionWaitingForAQueuePlaceCancelsItAtOnce` -> `cancelOnASessionWhoseSubmissionWaitsRemovesItAtOnce` (adds the next item that the worker runs).
    - `GenerationQueueWorkerTests`: 3 new refusal tests; `GenerationQueueWorkerTaskTests`: new `aWholeSDKCallRunsOnTheWorkerTask`.
    - New suite `SummarizerSubmissionTests`; public surface: `GenerationSubmissionEventPublicSurfaceTests` (renamed file) and `aConsumerMatchesTheRefusedWait`.

    RED evidence: with the session submitting nothing (`ownSubmissionTarget` = nil) the FIFO, tool-body and flash tests failed (flash peak 2); with the refusal check removed, both refusal tests failed inside their bound; with the `beginTurn` check removed, the busy-session test failed inside its bound.
  timestamp: 2026-09-25T23:17:20.048735+00:00
- actor: claude-code
  id: 01m3ddr549dqybq5s0rt8j8f4w
  text: |-
    ### Stress runs (parallel repetitions)

    Tool: `swiftpm-testing-helper` over the test bundle, 8 processes at once, each with `--repetitions`. HEAD was built from `git archive HEAD` in the scratchpad for the comparison (no worktree, no stash).

    - New tree, queue + cancellation + stall + tracing + compaction-yield suites, 8 x 20: 6 processes passed with 0 issues; 2 processes crashed with `_ContiguousArrayStorage deallocated with non-zero retain count 2` (^vg6bmq6).
    - HEAD 4bc3a93, same filter, 8 x 20: 6 passed; 2 crashed with the same message. So the crash rate is the same, and it is not caused by this task.
    - New tree, second round 8 x 20: 1 issue in `TurnCancellationTests` "cancelCurrentTurn finishes a streamEvents turn with CancellationError, leaving the consumer what it already received" (TurnCancellationTests.swift, `delivered.events.contains(.textDelta(...))`). This is the known ^zr22hpd (the test uses no queue). 2 crashes, the same ^vg6bmq6 message.
    - New tree, third round 8 x 30 (queue suites, `SummarizerSubmissionTests`, `HumanWaitGateTests`, `NestedGenerationReentryTests`, `PooledResidencyTests`, `RecordingLanguageModelTests`, spike): 0 test issues; 2 crashes, the same ^vg6bmq6 message.
    - Load average during the runs: 8 to 17.

    Scope note: item 8 names the doc of `awaitingUser`, which ^f33q8gw removes later. I only changed its doc comment (a wait in a tool now holds the model), and did not remove it.
  timestamp: 2026-09-25T23:17:31.401278+00:00
- actor: claude-code
  id: 01m3ddr9b41h6ba4m5m3mnewxt
  text: |-
    ### implement — changed
    - evidence: 44 files (production: GenerationQueue, GenerationQueueError (new), GenerationWorker, SessionLanguageModel (renamed from QueuedLanguageModel), GenerationPassObserver, ExecutorPassthrough, BackgroundTool, RunToCompletionRunner, RecordingLanguageModel, LiveModelLoader, ModelLoader, GenerationReentry, GenerationStall, LanguageModelSessionBackend, RoutedSession, RoutedSessionActor, RoutedSessionActorCompaction, RoutedSessionActorPassReports, RoutedSessionActorTurnExecution, RoutedSessionActorTurnGating, SessionEvent, SessionProjection, TurnOutcome; Examples/MultiModelGeneration; generation-queue.md; tests as listed above). `swift test`: 1425 + 4 + 19 = 1448 passed, 0 failed, 2 known issues (withKnownIssue). `swift build --build-tests`: 0 warnings in first-party files (only the known `mlx-swift_Cmlx.bundle` note). `swift build --package-path IntegrationTests --build-tests`: clean. `swift test --package-path IntegrationTests --filter ExecutorPassBoundaryIntegrationTests`: 3 passed. Stress: see the comment above.
    - next: review
  timestamp: 2026-09-25T23:17:35.716354+00:00
depends_on:
- 01M3CYHCGYFC6JMYTVZA0ZE9AF
position_column: doing
position_ordinal: '80'
title: Make one submission to Foundation the item of the generation queue
---
## Why

The user said on 2026-09-25: "right -- going to Foundation to generate -- or call tools which might be multiple 'steps' inside Foundation -- that submission to Foundation needs to be queued". So the item of the queue of a model is one submission to Foundation: one SDK call (`LanguageModelSession.respond` or `streamResponse`), with all of its steps (generation passes and tool bodies). Now the item is one executor pass. Design: `generation-queue.md`, sections 5.1, 5.3, 5.5 and 5.7.

A submission holds the worker of its model for all of its steps. A tool body that waits in-band for a session on the same model can thus never end: the submission of that session waits behind the submission of the tool. The spike `SubmissionQueueSpikeTests` proves that a background tool avoids this, and that the result comes back as mail. It also proves the other side: the same test with an in-band tool times out.

## What to do

1. The per-session wrapper no longer takes the queue for each pass. Rename `QueuedLanguageModel` to `SessionLanguageModel` (and its state to `SessionLanguageModelState`). It stays one instance for each backend, with the identity key of ^8csj2hw. It keeps the pass observer (for the stall watch) and it is the seam of R2 ^cc2tezn (`promptCacheScope` inside its executor `respond`, on the SDK's executor task).
2. The session submits its whole model call as one item. `runCancellableModelCall` (`Session/RoutedSessionActorTurnExecution.swift`) gives the queue of its backend one closure. The closure binds `ModelCallMark`, `ToolResultAppendBoundary` and `ToolContext` (the worker task inherits no task-local) and runs `body(composedPrompt)`. The backend names its queue: add `generationQueue: GenerationQueue?` to `LanguageModelSessionBackend`, `nil` by default. A backend with no queue runs the call directly, as now. `inFlightModelCall` and cancel keep working: a cancel removes a waiting item, or cancels the running item.
3. Each summarizer call (`CancellableCompactionSummarizer`, the flash tier and the own-model tier) is one item on the queue of the container that runs it. The own-model summarizer runs between two submissions of its session, so it cannot wait for itself.
4. Events: replace `SessionEvent.passQueued` and `.passStarted` with `.submissionQueued` (only when the submission must wait) and `.submissionStarted` (for each submission). Update every exhaustive switch (`SessionProjection`, `TurnOutcome`, `Examples/MultiModelGeneration`, `ScriptedToolTurnComparisonTests`, IntegrationTests `RealToolTurnComparisonTests`).
5. Stall watch: count only the time inside a pass of the running submission (the wrapper reports pass start and pass end, with no queue phase). A wait for the worker and a tool body give no `generationStalled`. For a backend with no pass reports, count from the start of the submission, not from the call (the wait for the worker is not a stall). `GenerationStall.timeInFlight` stays the whole model call.
6. The wait-cycle refusal: `ModelCallMark` also names the queue of its submission. A submission to queue Q from a task with an OPEN mark on Q (an in-band tool body of a running submission on the same model) throws at once a new typed error, `GenerationQueueError.waitInsideOpenSubmission(model:)`, and does not hang. A background body has a closed mark (`withBackgroundRunMark`), so it is not refused. Keep `SessionReentryError` for now; task "Replace turnLock with a per-session message queue" removes it.
7. Restate the tests that assume an in-band wait on the same model, to the new contract: `GenerationQueueTurnTests.aToolBodyThatWaitsLetsAnotherSessionCompleteATurn` (the other session now runs after the submission), `.twoToolLoopsTakeAlternatePasses` (whole submissions in FIFO order), `.aParentWaitsInAToolBodyForAChildTurnOnTheSameModel` (now the refusal; the background shape is the spike), `HumanWaitGateTests` (a wait in a tool holds the model), `QueuedPassStallWatchTests`, `SharedGenerationQueueContentionTests`, `ForkConcurrencyTests.generationQueueSerializesPassesAndIsFIFO`, `GenerationQueueTests`. Do not delete an assertion to make the suite green: restate it or replace it with the assertion of the new contract.
8. Update the doc comments that say "a tool body holds no place": `GenerationQueue`, `RoutedSession` (type doc, `respond`, `streamResponse`, `streamEvents`, `awaitingUser`, `cancelCurrentTurn`), `RunToCompletionRunner`, `BackgroundTool.inlineSettleGrace` (an in-band wait now holds the model for every session on it).

## Acceptance Criteria

- [x] A test over the scripted model: two sessions with tool loops over one model run whole submissions in FIFO order; the second SDK call starts only after the first ends. <!-- GenerationQueueTurnTests.twoToolLoopsRunWholeSubmissionsInOrder -->
- [x] A test: an in-band tool body that asks a session over the same model for an answer gets `GenerationQueueError.waitInsideOpenSubmission` at once (bounded, no hang). A background body that does the same completes (`SubmissionQueueSpikeTests` stays green). <!-- GenerationQueueTurnTests.anInBandWaitForASessionOnTheSameModelIsRefused, GenerationQueueTurnTests.anInBandWaitForABusySessionOnTheSameModelIsRefused, GenerationQueueWorkerTests.aSubmissionInsideAnOpenSubmissionOnTheSameQueueIsRefused, GenerationQueueWorkerTests.aBackgroundRunOfAnOpenSubmissionIsNotRefused, SubmissionQueueSpikeTests.aChildResultDeliveredAsMailCausesTheNextSubmission -->
- [x] A test: a wait for the worker and a tool body give no `generationStalled`; a held pass with no fragment still reports `.fragments(0)`. <!-- QueuedPassStallWatchTests.aWaitForTheWorkerIsNotAStall, .aToolBodyIsNotAStall, .aHeldPassWithNoFragmentStillReportsAStall, .aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass, .aWatchCountsFromTheStartOfTheSubmissionAndOfEachPass -->
- [x] A test: `submissionQueued` comes before `submissionStarted` for a submission that waits, and a submission with a free worker sends only `submissionStarted`. A public-surface test names both cases. <!-- QueuedPassStallWatchTests.aWaitForTheWorkerIsNotAStall; GenerationSubmissionEventPublicSurfaceTests.aConsumerMatchesTheSubmissionEvents -->
- [x] A test: a flash summarizer call and a flash submission of another session never overlap. <!-- SummarizerSubmissionTests.aFlashSummarizerCallAndAFlashSubmissionNeverOverlap -->
- [x] A test: a cancel of a session whose submission waits removes the item at once; the caller gets `CancellationError`; the worker then runs the next item. <!-- NestedGenerationReentryTests.cancelOnASessionWhoseSubmissionWaitsRemovesItAtOnce; GenerationQueueTests.cancelledWaitingSubmissionNeverRuns -->
- [x] `ExecutorPassBoundaryTests` and `ExecutorPassBoundaryIntegrationTests` stay green. <!-- swift test (unit); swift test --package-path IntegrationTests --filter ExecutorPassBoundaryIntegrationTests: 3 tests passed -->
- [x] Full `swift test` green, 0 new warnings; `swift build --package-path IntegrationTests --build-tests` clean. <!-- swift test: 1425 + 4 + 19 = 1448 passed, 2 known issues (withKnownIssue); IntegrationTests build clean --> #generation-queue
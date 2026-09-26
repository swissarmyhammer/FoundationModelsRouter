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
- actor: claude-code
  id: 01m3dfa0rfskkmhqv021q8r3dk
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 4 findings (4 confirmed, 0 refuted) — Examples/MultiModelGeneration/main.swift:95, Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift:70, Sources/FoundationModelsRouter/Concurrency/GenerationQueue.swift:125, Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:39
    - next: Correct each item in the "Review Findings (2026-09-25 18:27)" section. Then do the review again. The task stays in review.
  timestamp: 2026-09-25T23:44:45.327318+00:00
- actor: claude-code
  id: 01m3dfcmwbrynp1tn1xvv387zf
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 44 files (the queue item is one SDK call)
    - test: green — swift test, 1448 passed (1425+4+19), 0 failed, 0 skipped; 9 queue and cancel suites 3 extra runs clean; all products and IntegrationTests build clean
    - commit: 7dc8ee4
    - review: findings — Examples/MultiModelGeneration/main.swift:95, Concurrency/GenerationPassObserver.swift:70, Concurrency/GenerationQueue.swift:125, Concurrency/SessionLanguageModel.swift:39
  timestamp: 2026-09-25T23:46:11.467754+00:00
- actor: claude-code
  id: 01m3dfw2nkxzczd830fqcngfab
  text: |-
    ### Review findings of 2026-09-25 18:27 — correction (implement)

    Finding 1 (`Examples/MultiModelGeneration/main.swift:95`, `code-hygiene/disallowed-constructs-swift`):
    - Decision: follow the idiom of `Examples/CompactionDemo/main.swift`. Each `print` gets `// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output` on the line directly above it. Reason: the output on standard out is the purpose of an example program, and the rule names this directive with a reason as the permitted form.
    - Scope: all 13 `print` calls in the file, not only the one at the finding.
    - Evidence: swiftlint 0.65.1 with the custom rule `no_direct_standard_out_logs` (`match_kinds: [identifier]`): 13 violations on the HEAD file, 0 on the new file.

    Finding 2 (`GenerationPassObserver.swift:70`, `completeness/inverse-operation-coverage`):
    - Result: NOT a real gap. The calls exist in a file that the reviewer did not read. Call site: `RoutedSessionActor.run(_:on:reportingTo:)` in `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`. It calls `queue.submit(onQueued: { observer.submissionQueued() }) { observer.submissionStarted(); ... }`. `runCancellableModelCall(composedPrompt:submittingTo:_:)` calls `run` for each model call (turns and all summarizer tiers).
    - Removal proof (remove, run, see the failure, restore):
      - A. Without `observer.submissionQueued()`: 3 tests fail — `QueuedPassStallWatchTests.aWaitForTheWorkerIsNotAStall`, `QueuedPassStallWatchTests.aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass`, `SummarizerSubmissionTests.aFlashSummarizerCallAndAFlashSubmissionNeverOverlap`.
      - B. Without `observer.submissionStarted()`: 3 tests fail — `aWaitForTheWorkerIsNotAStall`, `aHeldPassWithNoFragmentStillReportsAStall`, `aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass`.
    - Same check for the other observer methods (callers in `SessionLanguageModel.Executor.respond(to:model:streamingInto:)`):
      - E. Without `observer?.passStarted()`: `aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass` fails.
      - F. Without `observer?.passEnded()`: `aToolBodyIsNotAStall` and `aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass` fail.
    - So each of the 4 observer methods has a caller and a test that fails without it. No new test is necessary.
    - Visible link: the doc comment of each of `submissionQueued()`, `submissionStarted()`, `passStarted()` and `passEnded()` now names its caller.

    Finding 3 (`GenerationQueue.swift:125`, `completeness/invariant-propagation`):
    - Result: NOT a real gap. The mark is set in `RoutedSessionActor.runCancellableModelCall(composedPrompt:submittingTo:_:)` (`RoutedSessionActorTurnExecution.swift`). It makes `ModelCallMark(sessionID: id, submission: target)` with `target` = `ownSubmissionTarget` (or the summarizer target), and `RoutedSessionActor.submission(of:composedPrompt:mark:boundary:context:serviceContext:)` binds it with `ModelCallMark.$current.withValue(mark)` around the SDK call, on the task of the worker. The SDK gives it to each in-band tool body. `defer { modelCallMark.close() }` closes it.
    - Removal proof:
      - C. The submission binds no mark (`withValue(nil)`): 6 tests fail — `GenerationQueueTurnTests.anInBandWaitForASessionOnTheSameModelIsRefused`, `.anInBandWaitForABusySessionOnTheSameModelIsRefused`, and 4 `NestedGenerationReentryTests` (a tool body that generates on its own session / forks its own session / reads its own transcript mid-turn; a declared background body that generates on the session that started it). So the test set covers all three mark readers: `GenerationQueue.refuseWaitInsideOpenSubmission()`, `RoutedSessionActor.refuseReentryOntoThisSession()` and `isInsideOwnTurnToolCall`.
      - D. The mark names no queue (`submission: nil`): the 2 `GenerationQueueTurnTests` refusal tests fail.
      - The removal of the check in `GenerationQueue.submit` and in `beginTurn()` was proven in the first implement pass (see the comment "Implementation landed", RED evidence).
    - No new test is necessary. Visible link: the doc comment of `refuseWaitInsideOpenSubmission()` now names where the mark is made and bound, and when it closes.

    Finding 4 (`SessionLanguageModel.swift:39`, `duplication/duplication`):
    - One `init(wrapping:passQueue:)` with `passQueue: GenerationQueue? = nil`. All callers (`LiveModelLoader.languageModel`, the backend wrapper in `LiveModelLoader`, `RecordingLanguageModelTests`, `GenerationQueueWorkerTests`, `GenerationQueueTests`) compile unchanged.

    What did not work: a `swift test` output filter that dropped lines with "passed after" also dropped the summary line "Test run with ... passed after". Save the whole log to a file and read the summary from it.
  timestamp: 2026-09-25T23:54:37.107405+00:00
- actor: claude-code
  id: 01m3dfwdwvxxa46jeayxzaj6ms
  text: |-
    ### implement — changed
    - evidence: 4 files — Examples/MultiModelGeneration/main.swift (13 directives), Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift (one init), Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift (docs name the callers), Sources/FoundationModelsRouter/Concurrency/GenerationQueue.swift (doc names where the mark is set). `swift test`: 1425 + 4 + 19 = 1448 passed, 0 failed, 2 known issues (withKnownIssue). Queue, cancel and re-entry suites (15 suites, 120 tests) 3 extra runs: all passed. `swift build --build-tests` and both example targets recompiled: 0 warnings in first-party files (only the known `mlx-swift_Cmlx.bundle` note). `swift build --package-path IntegrationTests --build-tests`: clean. Removal experiments A to F: each removed call fails 1 to 6 tests, then restored.
    - next: review
  timestamp: 2026-09-25T23:54:48.603567+00:00
- actor: claude-code
  id: 01m3dgbs1658k45qrm1p1y822k
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c465a16); 0 findings (0 confirmed, 0 refuted; 7 validator runs, 0 failed); 4 files reviewed, 2 `.kanban/` files excluded by `.reviewignore`. All 4 items of "Review Findings (2026-09-25 18:27)" are checked. Call sites verified at HEAD: `RoutedSessionActor.run(_:on:reportingTo:)` in `Session/RoutedSessionActorTurnExecution.swift` calls `queue.submit(onQueued: { observer.submissionQueued() })` and `observer.submissionStarted()`; `runCancellableModelCall(composedPrompt:submittingTo:_:)` calls `Self.run(submission, on: target?.queue, reportingTo: observer)`, makes `ModelCallMark(sessionID: id, submission: target)` with `defer { modelCallMark.close() }`, and `submission(of:...)` binds it with `ModelCallMark.$current.withValue(mark)`. `GenerationQueue.submit` and `beginTurn()` call `refuseWaitInsideOpenSubmission()`.
    - next: none. The task moved to done.
  timestamp: 2026-09-26T00:03:11.526715+00:00
- actor: claude-code
  id: 01m3dgcr44fjm07y5c372mkrxj
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files (one SessionLanguageModel init; doc comments name the callers; swiftlint lines in the demo). Findings 2 and 3 were not real gaps; removal experiments are in the comments.
    - test: green — swift test, 1448 passed (1425+4+19), 0 failed, 0 skipped; queue and cancel suites 2 extra runs clean
    - commit: c465a16
    - review: clean — 0 findings
  timestamp: 2026-09-26T00:03:43.364984+00:00
depends_on:
- 01M3CYHCGYFC6JMYTVZA0ZE9AF
position_column: done
position_ordinal: ffffff8980
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

## Review Findings (2026-09-25 18:27)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 43 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `generation-queue.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Concurrency/QueuedLanguageModel.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift, so its declarations are unread

- [x] `Examples/MultiModelGeneration/main.swift:95` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Sources/FoundationModelsRouter/Concurrency/GenerationPassObserver.swift:70` `completeness/inverse-operation-coverage` — The new observer methods `submissionQueued()` and `submissionStarted()` are defined to record submission-lifecycle events (lines 70–78), but these methods are never called in the marked code. The probe confirms zero callers for both methods. The infrastructure for reading these events exists (lines 28–34 map phases to `SessionEvent`), and test code handles the resulting event cases (main.swift:94–95, RealToolTurnComparisonTests.swift:361), but the write side is absent, breaking the round-trip: events are defined but never generated. Consumers are prepared to receive these events, but no code in the marked lines actually emits them. Call `observer?.submissionQueued()` when a submission joins the queue behind other work (likely in `GenerationWorker.runWaitingItems` before item execution), and `observer?.submissionStarted()` when the worker begins executing it. The `onQueued` callback parameter in `GenerationQueue.submit` (lines 76–81, 96) appears designed for this; ensure the session's observer is invoked through that path.
- [x] `Sources/FoundationModelsRouter/Concurrency/GenerationQueue.swift:125` `completeness/invariant-propagation` — The new `refuseWaitInsideOpenSubmission()` method reads `ModelCallMark.current?.openSubmission(on: self)` to check if the calling task is already inside an open submission on this queue, but nowhere in the marked code is `ModelCallMark.current` ever set or initialized to mark an open submission. The method's own documentation (lines 110–122) states that a session must mark open submissions so that tool bodies can detect and refuse reentrant submissions. Without the mark being set, the check will always find it absent and permit submission, leaving the deadlock prevention invariant broken. Before or during submission, establish `ModelCallMark.current` to track the open submission on this queue. This likely belongs in the session's submission handler or in the pass execution context in `SessionLanguageModel` (around line 136, when the pass starts), using a pattern like `try await ModelCallMark.withOpenSubmissionMark(on: passQueue) { ... }` or equivalent, so that tool bodies running in the pass can see the mark and refuse nested submissions.
- [x] `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:39` `duplication/duplication` — Two init methods differ only in the passQueue parameter. Both create SessionLanguageModelState with identical logic — one passes passQueue: nil, the other passes the parameter value. These should consolidate into a single init with a default parameter. Consolidate into one init: `init(wrapping wrapped: any LanguageModel, passQueue: GenerationQueue? = nil) { state = SessionLanguageModelState(wrapped: wrapped, passQueue: passQueue) }`. Delete the first init (lines 39-41) and keep the second (lines 50-51) with the default parameter added.

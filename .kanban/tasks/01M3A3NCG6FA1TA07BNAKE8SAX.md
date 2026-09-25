---
comments:
- actor: claude-code
  id: 01m3a5qg56y26104c0x3sqdc7q
  text: '2026-09-24: the FoundationModelsACPAgent session confirmed the recommended GenerationStall meanings (step 4). Their `_stalled` rule reads only `visibility == .fragments(0)` and `timeWithoutProgress >= 30 min`, and only when the prompt made no output. With `timeWithoutProgress` counted only while a pass holds its queue place, a request that only waits can never reach their bound. They never use `timeInFlight` for a stop decision, so it can stay the whole model call. They still need the comment with the final shape and names (acceptance criterion) before the change lands.'
  timestamp: 2026-09-24T16:59:38.022678+00:00
- actor: claude-code
  id: 01m3cs79ghcnfn0wj1ett6mfsk
  text: |-
    Picked up. Final shape for the ACP card ^rfn4m87 (written before the change lands):

    (1) Shape: option (b), two new `SessionEvent` cases with no payload:
    - `SessionEvent.passQueued`: a generation pass of the turn in flight waits for the place of the generation queue of its model, because a pass of another session holds the place. The session sends it only when the pass must wait. A pass that finds the place free sends no `passQueued`.
    - `SessionEvent.passStarted`: the pass that sent `passQueued` took the place and now generates. The session sends it only after a `passQueued`. A wait that is cancelled ends with the turn (`turnEnded`, or the error of the turn) and sends no `passStarted`.
    Both travel on the turn stream of `streamEvents(to:maxTokens:)` and on `streamSessionEvents()`, as `generationStalled` does. `SessionEvent` has no library evolution, so a consumer with a `default` arm is not affected; a consumer with an exhaustive switch adds the two cases.
    The session sends the events only for a backend that runs over the per-session queued wrapper (the live MLX container). A stub container with no executor seam sends none.

    (2) Meaning of each `GenerationStall` field after this change:
    - `timeWithoutProgress`: measured only over the time a pass holds its queue place, from the later of the last progress and the moment the current pass took its place. While no pass holds a place (a wait for a queue place, or a tool body between two passes), the session makes no stall report. For a backend with no executor seam (no pass reports) the value is as before: from the last progress.
    - `timeInFlight`: unchanged: the whole model call, queue waits and tool bodies included.
    - `visibility` (`.fragments(n)` / `.wholeAnswer`): unchanged: the text fragments of the whole model call.
    - `lastProgress`: unchanged. A pass that takes its queue place is not progress.
    Result for the `_stalled` rule: a request that only waits for the GPU, or only runs a tool body, never gets a stall report, so it never reaches the 30-minute bound. A pass that holds its place and makes no fragment still reports `.fragments(0)` as now.
  timestamp: 2026-09-25T17:18:47.313833+00:00
- actor: claude-code
  id: 01m3ct1trhtvvfsq4s95d7xymw
  text: |-
    Implementation landed (not committed). What changed and why:
    - Seam: new `Concurrency/GenerationPassObserver.swift` (`GenerationPassObserver`, `GenerationPassPhase`, internal protocol `GenerationPassReporting`). `QueuedLanguageModelState` holds the installed observer under a `Mutex`; the executor of `QueuedLanguageModel` calls `passQueued()` (only when the place is taken), `passStarted()` (inside the place), and `passEnded()` (in a `defer`, just after the place is given back, also after a cancelled wait). The calls are synchronous: each appends one phase under a lock and wakes the reader. `MLXFoundationModelsSessionBackend` conforms to `GenerationPassReporting` and keeps the state of its wrapper.
    - `AsyncSemaphore.waitUnlessCancelled(onQueued:)` and `withPermitUnlessCancelled(isolation:onQueued:_:)` are new overloads (the old signatures forward to them, so no DocC link and no caller changed). `GenerationQueue.runPass(isolation:onQueued:_:)` is internal; the public `runPass(isolation:_:)` is unchanged.
    - Session actor: `nonisolated let generationPassObserver`; `backend` has a `didSet` and the init calls `observeGenerationPasses(of:)`, so every backend of the session (replaced transcript, compaction, priming) reports to it. New `Session/RoutedSessionActorPassReports.swift`: `runCancellableModelCall` opens a per-call reader task (stored and cancelled, as the stall watchdog is) and closes it before the stall watch ends; the close drains the last phases, so the events reach the turn before `turnEnded`. `reportGenerationStall` drains first, so it reads the pass state of now.
    - Watch: `GenerationStallWatch.reportsPasses`, `passHeldSince`, `measuredFrom`, `apply(_:)`. A call with no pass report (stub backend, summarizer backend) measures as before.
    - Events: `SessionEvent.passQueued` and `.passStarted` (no payload). Exhaustive switches updated: SessionProjection, TurnOutcome, Examples/MultiModelGeneration, ScriptedToolTurnComparisonTests, IntegrationTests RealToolTurnComparisonTests.
    - Docs: `GenerationStall` (each field), `GenerationProgressVisibility`, `watchGenerationForStalls`, `reportGenerationStall`, `SessionEvent.generationStalled`, `RoutedSession` (respond, streamResponse, streamEvents, streamSessionEvents, setGenerationStallReportInterval), `generation-queue.md` section 2.
    - Tests: new `QueuedPassStallWatchTests` (4 tests: queue wait = no stall and passQueued before passStarted, and a free-place session sends neither; tool body of 1 s = no stall between its open and close records; a held pass with no fragment still reports `.fragments(0)`; pins timeWithoutProgress < tool hold and timeInFlight >= wait + tool hold). `GenerationQueueTests.aPassReportsItsWaitOnlyWhenThePlaceIsTaken`. Public surface: `GenerationPassEventPublicSurfaceTests`. Shared `Helpers/SessionEventLog.swift` replaces the private EventLog and watch helper of `GenerationStallDiagnosticTests` (no assertion changed there).
    - RED seen before the production change: 11 issues in QueuedPassStallWatchTests + GenerationQueueTests; the held-pass test passed before (it pins the kept behavior).
    - Not done here (other tasks): summarizer calls still run over wrappers with no observer (^6wqketz); a consumer stub container with no executor seam sends no pass events.
  timestamp: 2026-09-25T17:33:16.945522+00:00
- actor: claude-code
  id: 01m3ct242jqj6vy05q9m6zdt0z
  text: |-
    ### implement — changed
    - evidence: 20 files (5 new). Sources: Concurrency/GenerationPassObserver.swift (new), Concurrency/AsyncSemaphore.swift, Concurrency/GenerationQueue.swift, Concurrency/QueuedLanguageModel.swift, Resolution/LiveModelLoader.swift, Session/RoutedSessionActorPassReports.swift (new), Session/RoutedSessionActor.swift, Session/RoutedSessionActorTurnExecution.swift, Session/GenerationStall.swift, Session/SessionEvent.swift, Session/RoutedSession.swift, Session/SessionProjection.swift, Session/TurnOutcome.swift, Examples/MultiModelGeneration/main.swift, generation-queue.md. Tests: QueuedPassStallWatchTests.swift (new, 4), Helpers/SessionEventLog.swift (new), GenerationQueueTests.swift (+1), GenerationStallDiagnosticTests.swift (uses the shared log), ScriptedToolTurnComparisonTests.swift, PublicSurface GenerationPassEventPublicSurfaceTests.swift (new, 1), IntegrationTests RealToolTurnComparisonTests.swift.
    - build: FoundationModelsRouter.build removed, then `swift build --build-tests`: Build complete, 0 compiler warnings (only the known mlx-swift_Cmlx "missing creator" line). `swift build --package-path IntegrationTests --build-tests`: Build complete.
    - tests: `swift test --skip-build` 5 runs, each "Test run with 1403 tests in 161 suites passed ... with 2 known issues" (the 2 known issues were there before), plus 3 tests (public surface) and 19 tests in the other bundles. Filter run of QueuedPassStallWatchTests + GenerationQueueTests + GenerationStallDiagnosticTests: 23 tests in 3 suites passed.
    - stress (swiftpm-testing-helper): QueuedPassStallWatchTests 8 processes x 15 repetitions, all passed; GenerationQueue*/GenerationStallDiagnostic/NestedGenerationReentry/TurnCancellation/SharedGenerationQueueContention 8 processes x 20 repetitions ("60 tests in 6 suites passed" in each), 0 issues, 0 crashes.
    - next: /review
  timestamp: 2026-09-25T17:33:26.482352+00:00
- actor: claude-code
  id: 01m3ct4wsfzzw8hasyktaxgc70
  text: |-
    Acceptance criteria checked (7 of 7). Proof for each item:
    1. Queue wait gives no `.fragments(0)` stall: `QueuedPassStallWatchTests.aWaitForAQueuePlaceIsNotAStall` (two sessions on one `PassObservingFixture` container, held pass, 1 s wait at a 50 ms interval, `stallsDuringTheWait.isEmpty`).
    2. Tool body gives no stall: `QueuedPassStallWatchTests.aToolBodyIsNotAStall` (`PassBoundaryProbeTool` holds 1 s; no `generationStalled` between its open and close `toolInvocation` records).
    3. Consumer sees the wait: `QueuedPassStallWatchTests.aWaitForAQueuePlaceIsNotAStall` (one `passQueued` before one `passStarted`; the session with a free place sends neither), `GenerationQueueTests.aPassReportsItsWaitOnlyWhenThePlaceIsTaken`, and `Tests/FoundationModelsRouterPublicSurfaceTests/GenerationPassEventPublicSurfaceTests.swift`.
    4. A held pass with no fragment still reports: `QueuedPassStallWatchTests.aHeldPassWithNoFragmentStillReportsAStall` (`.fragments(observed: 0)`, `timeWithoutProgress >= interval`); `GenerationStallDiagnosticTests` (12 tests) still pass for the stub backends.
    5. Field meanings pinned: `QueuedPassStallWatchTests.aStallAfterAWaitAndAToolBodyMeasuresOnlyTheHeldPass` (`timeWithoutProgress < 1 s` tool hold, `timeInFlight >= 2 s` wait plus tool hold, every stall has `lastProgress == .toolResult`).
    6. ACP comment before the change: the task comment that starts "Picked up. Final shape for the ACP card ^rfn4m87" (names `SessionEvent.passQueued` and `SessionEvent.passStarted`, and the meaning of all four `GenerationStall` fields). It was posted before any production code changed.
    7. Full suite green: `swift test --skip-build` 5 runs, each "1403 tests in 161 suites passed ... with 2 known issues" (the 2 known issues were there before), plus 3 and 19 tests in the other bundles; details in the "implement — changed" step record.
  timestamp: 2026-09-25T17:34:57.327497+00:00
depends_on:
- 01M39ZNSNZGBYEY5G8R93KJN94
position_column: doing
position_ordinal: '80'
title: Do not count a wait for a queue place as a stalled generation, and tell the consumer about the wait
---
## Why

With the per-model generation queue (^8csj2hw, ^93kjn94), a request can wait a long time for a queue place while other sessions generate. The stall watchdog starts at the start of the whole model call (`runCancellableModelCall` → `beginGenerationStallWatch` / `watchGenerationForStalls` in `Session/RoutedSessionActorTurnExecution.swift`). The queue wait is inside that model call. Thus a request that only waits for the GPU reports `generationStalled` with `.fragments(0)`, the same report as a model that cannot generate.

A consumer cannot see the difference. FoundationModelsACPAgent ends a prompt with `_stalled` when a stall report shows zero fragments for 30 minutes and the prompt has made no output (`PromptTurn.endsTurn(_:sawOutput:)`). With some agent sessions on one model, a request that only waits in the queue can be ended as a broken model. Consumer card: FoundationModelsACPAgent ^rfn4m87. Design: `generation-queue.md`, section 2.

## The seam

The queue wait happens in the executor of the per-session queued wrapper (^8csj2hw), not on the session actor. A task-local bound on the session actor does not reach that executor through `LanguageModelSession` (the SDK can run the executor on another task). Thus the per-session wrapper state of ^8csj2hw gets a pass observer that the session actor installs when it makes its backend. The wrapper calls it at three points of each pass: the pass starts to wait for a queue place, the pass takes its place, and the pass ends (in the `defer` that signals the queue). The session actor turns these calls into its own state. This needs one executor for each session, which ^8csj2hw requires.

## Decision: tool-body time is not watched

The stall watch measures generation. It runs only while a pass holds its queue place. It does not run while the request waits for a place, and it does not run while a tool body runs between two passes (the model does not generate then). Now the watch covers the whole model call, tool bodies included, so this is a change of behavior: a tool body that runs longer than the stall interval gives no `generationStalled` report after this task.

The FoundationModelsACPAgent session confirmed on 2026-09-24 that it needs no report during a tool body. Its `_stalled` rule ends a prompt only on `.fragments(0)` AND no output, and a tool call sets `sawOutput`, so a report during a tool body can never end a prompt (their test `aStallPastTheBoundAfterAToolCallDoesNotEndTheTurn`). The only other use is one `notice` log line. The change also removes a known false signal: on 2026-09-08 the Router reported "0 fragments" for a whole healthy run while `runCode` and shell calls completed (their comment on `stalledGenerationBound`).

## What to do

1. Add the pass observer to the per-session wrapper state (see "The seam").
2. Start the stall watch of a pass when the pass takes its queue place, and stop it when the pass ends. Do not count the queue wait or the tool-body time.
3. Tell the consumer that a request waits for a queue place. Choose one:
   (a) a field on `GenerationStall` (for example `waitingForQueue: Bool` or a new `visibility` case), or
   (b) new `SessionEvent` cases, for example `passQueued` and `passStarted`.
   Option (b) also lets a client show "waiting for the model". Remember the `@unknown default` contract of `SessionEvent` for consumers.
4. Decide the meaning of each `GenerationStall` field after this change, and write it in its doc comment. Recommendation:
   - `timeWithoutProgress`: measured only over the time a pass holds its queue place, from the later of the last progress and the moment the current pass took its place.
   - `timeInFlight`: keeps its meaning, the whole model call (queue waits and tool bodies included), so a consumer still sees how long the request has run.
   - `visibility` (`.fragments(n)`): keeps its meaning, the fragments of the whole model call.
   - `lastProgress`: keeps its meaning; a pass that takes its queue place is not progress.
5. Update the doc comments of `generationStalled` in `Session/RoutedSession.swift` and `Session/SessionEvent.swift`, of `GenerationStall`, and of `watchGenerationForStalls`.

## Acceptance Criteria

- [x] A request that waits for a queue place longer than the stall interval gets no stall report with `.fragments(0)` for that wait (test with two sessions on one pool entry and a held pass).
- [x] A tool body that runs longer than the stall interval gives no stall report for that time (test with a holding tool, as `PassBoundaryProbeTool` in the test support target).
- [x] The consumer can see that the request waits for a queue place (test on the chosen event or field).
- [x] A pass that runs and makes no fragment still gets the stall report as now.
- [x] A test pins the meaning of `timeWithoutProgress` and `timeInFlight` for a request that waited for a queue place and ran a tool.
- [x] Before the change lands, a comment on this task gives, for the ACP card ^rfn4m87: (1) the final shape (a `GenerationStall` field or new `SessionEvent` cases) with the exact names, and (2) the meaning of each `GenerationStall` field (`timeWithoutProgress`, `timeInFlight`, `visibility`, `lastProgress`) after this change.
- [x] The full suite is green. #generation-queue
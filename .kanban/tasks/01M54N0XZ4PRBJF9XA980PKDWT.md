---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54rv5a6z56byj4wxjag5xdg
  text: |-
    Condition met: the coordinating session said that Extras pushed the depth metric fix (Extras main f9b5496; commits e87e88f and caae75b).

    Research:
    - The local Extras pin was 1f586a7. `swift package --manifest-cache local update FoundationModelsExtras` moved the root and IntegrationTests to f9b5496 (the Extras main head). f9b5496 contains e87e88f and caae75b.
    - Extras GenerationQueue.enqueue(_:resume:) now does these steps in one `unfinished.withLock`: `job.wait(resume)`, `jobs.yield(job)`, `job.recordAccepted()` (the depth increment), `count += 1`. A job that was cancelled first gets none of them and goes to `job.refuse(resume)`. `Job.init` makes the ticket only (it keeps the metrics factory that is bound now), so the probe still counts by the factory of the submitting task. The admission queue and the model queues are both GenerationQueue.
    - A sourcekit-lsp process with cwd in this repo (PID 87551) started during the root update. I stopped it with `kill 87551` before the test runs. No SwiftPM fatalError.

    Changes (doc comments only, no production code):
    - Tests/FoundationModelsRouterTests/Helpers/QueueDepthProbe.swift: the type doc now says that the queue records the increment in the step that puts the job in its input, under the enqueue lock; that the job is in the queue when `enqueued` signals; and that a job that the queue refuses before that step gets no increment. Three other lines said "made" a job; they now say "accepted".
    - PoolEntryQueueTests, ExtrasPoolResolveTests, ResolveCancellationTests: the wait comments said "records its depth meter when it makes the job ... in the same `submit` call, with no suspension point between". They now state the enqueue step under the enqueue lock.
    - SummarizerSubmissionTests: the suite doc said "the job that the flash queue makes"; it now says "the job of the summarizer call that the flash queue accepts".

    Results:
    - 4 suites: 14 tests in 4 suites passed. No compiler warning.
    - Full `swift test`: 1827 tests in 224 suites passed with 6 known issues (the existing `withKnownIssue` tests of the wait helpers and of the harness embedding stub); 26 tests in 14 suites passed; 19 tests in 3 suites passed; XCTest 0 tests. 0 failures.
    - `swift build --package-path IntegrationTests --build-tests`: Build complete.
    - The only "warning:" line in each build is the llbuild note "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It is not a source warning.
    - CI was not run: this step does not commit or push.
  timestamp: 2026-10-17T11:09:37.990151+00:00
- actor: claude-code
  id: 01m54rv8dn2949086sch32qcw9
  text: |-
    ### implement — changed
    - evidence: Extras f9b5496 (root and IntegrationTests); 5 files: Tests/FoundationModelsRouterTests/Helpers/QueueDepthProbe.swift, Tests/FoundationModelsRouterTests/PoolEntryQueueTests.swift, Tests/FoundationModelsRouterTests/ExtrasPoolResolveTests.swift, Tests/FoundationModelsRouterTests/ResolveCancellationTests.swift, Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift; 4 suites 14/14 passed; full swift test 1827 tests in 224 suites (6 known issues) + 26 in 14 + 19 in 3, 0 failures; IntegrationTests build complete.
    - next: review
  timestamp: 2026-10-17T11:09:41.173921+00:00
position_column: doing
position_ordinal: '80'
title: 'QueueDepthProbe doc: the depth increment comes in the enqueue step (after the Extras fix)'
---
Source: request of the coordinating session (swissarmyhammer-96), 2026-10-17.

Extras will push a fix (local e87e88f, in the push of Extras card ^7n7bnkz). The GenerationQueue depth increment now comes under the enqueue lock, after the job is in the worker input, and not in `Job.init`. A job that the queue refuses before the enqueue gets no depth change. There is no public API change. Thus `QueueDepthProbe` signals a little later, in the step that queues the job.

Condition: start only after the coordinating session says that Extras pushed this fix. Do not change the order of the `t1-followup` chain for this card. Put the change in the next batch after that message.

- [x] Change the doc at Tests/FoundationModelsRouterTests/Helpers/QueueDepthProbe.swift:6-11 to say: "the queue records the increment in the step that puts the job in its input, under the enqueue lock".
- [x] With the new Extras head, check that these 4 suites give the same results: ResolveCancellationTests, ExtrasPoolResolveTests, PoolEntryQueueTests, SummarizerSubmissionTests. If CI on the new Extras head fails in one of them, tell the coordinating session.
- [x] Run the full suite one time.
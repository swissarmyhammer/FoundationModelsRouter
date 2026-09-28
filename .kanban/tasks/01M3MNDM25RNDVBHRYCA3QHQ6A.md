---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n1a3f6av203zvfwat7q62v
  text: |-
    Research (implement, iteration 1):
    - Extras is at 6c399a4. `TelemetryCapture` binds its `TestMetrics` with `withMetricsFactory` (a task-local). A metric that a detached task makes does not reach the capture. swift-metrics 2.11.0 is already in the checkouts (the Extras pin `from: "2.11.0"`). `TestMetrics.makeX` gives the same handler for the same label and dimensions, so a metric made at each call adds to one test handler.
    - Places with no task-local of the caller: the session pump (`Task.detached`), the worker task of `GenerationQueue` (`Task.detached`), and the admission job of `ModelPool.admit` (a task of its own; the router already carries the `ServiceContext` into it by hand).
    - Decisions: (1) No stored metric. `RouterMetrics` makes each metric at the record call, from an explicit factory or else from `MetricsSystem.factory`. (2) A session has an explicit metrics factory (`nil` by default, `useMetricsFactory(_:)`), the same shape as the explicit logger of ^rag2e91; a fork copies it. (3) The resolve reads `MetricsSystem.factory` on the task of the caller and binds it with `withMetricsFactory` around the admission job, as it does for the `ServiceContext`. (4) The footprints task of `PromptCacheSizing` is a plain `Task {}`, so it inherits the task-local factory of the code that made the router.
    - Names: each metric name starts with `FoundationModelsRouter.`. A dimension key has the same text as the span attribute key (`model.ref`, `slot`, `compaction.trigger`), as the Extras tool metrics do (`tool.name`, `tool.outcome`).
    - The session message queue has no bounded session dimension. A gauge with no dimension would hold only the value of the last session that wrote it. Thus the depth is a recorder (a histogram): each session records its waiting count at each post and at each take.
    - The resident-bytes gauge has no dimension. Each router over one pool reads the same pool footprint, so two routers over one pool write the same value.
  timestamp: 2026-09-28T22:14:03.494600+00:00
- actor: claude-code
  id: 01m3n1zc9hndr0wesz6bp2n234
  text: |-
    Implementation (iteration 1):
    - Package.swift: swift-metrics `from: "2.11.0"` (the Extras pin). `Metrics` on the library target; `Metrics` and `MetricsTestKit` on the unit test target. The resolve changed no pin (swift-metrics 2.11.0 was already resolved through Extras).
    - Vocabulary: `RouterTelemetry.MetricName` (9 names, each `FoundationModelsRouter.`-prefixed, `allNames`) and `RouterTelemetry.MetricDimension` (`model.ref`, `slot`, `compaction.trigger`, the same text as the span attribute keys).
    - `RouterMetrics` (Tracing/RouterMetrics.swift) makes each metric at the record call, from an explicit factory or `MetricsSystem.factory`. No stored metric.
    - Session: `explicitMetricsFactory`, `useMetricsFactory(_:)`, `sessionMetrics`; a fork copies the explicit logger and the explicit factory in one hop (`inheritTelemetry(logger:metricsFactory:)`).
    - Record sites: tokens in/out and tokens per second in `takeGenerationCall` (the ledger has `callStartedAt`; a tool close restarts it); time to first token in `noteGenerationProgress` (first progress after `submissionStartedAt`); load duration in `withLoadSpan` (the resolve binds the caller's factory with `withMetricsFactory` around the admission job, beside the `ServiceContext`); resident bytes from each value of the footprints task; session queue depth (a recorder, no dimension) at each post and each take; generation queue waiting (a gauge, `model.ref`) at the start of each queue job on the worker task; compaction count in `withCompactionSpan`.
    - Invariants: each record is synchronous. The only new `await` is `queue.waitingCount` inside the queue job, on the worker task, not on the pump.
    - Tests: `RouterMetricsTests` (9 tests) were written first; they did not compile before the implementation. `swift test --filter RouterMetricsTests`: 9 tests in 1 suite passed.

    ### implement — changed
    - evidence: 16 files — Package.swift, Tracing/RouterTelemetry.swift, Tracing/RouterMetrics.swift (new), Session/RoutedSessionActor.swift, Session/RoutedSessionActorMetrics.swift (new), Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorQueueing.swift, Session/RoutedSessionActorPump.swift, Session/RoutedSessionActorCompaction.swift, Session/RoutedSessionActorGenerationCalls.swift, Session/RoutedSessionActorRunJournal.swift, Session/GenerationStall.swift, Session/RoutedSessionActorAnswerExecution.swift, Router.swift, Sizing/PromptCacheSizing.swift, Tests RouterMetricsTests.swift + Helpers/MetricAssertions.swift (new)
    - next: /test
  timestamp: 2026-09-28T22:25:40.657290+00:00
- actor: claude-code
  id: 01m3n3a855ba92er58ndf4fw83
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (421e6b0) — 1 finding (2 refuted): Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCalls.swift:162 (completeness/invariant-propagation)
    - next: implement the finding

    ### finish iteration 1 — findings
    - implement: changed — swift-metrics in Package.swift, `RouterTelemetry.MetricName` / `MetricDimension`, `RouterMetrics`, explicit session metrics factory, 7 record sites, `RouterMetricsTests` (9 tests).
    - test: green — swift test: 1409 + 22 + 19 tests passed (2 known issues), exit 0. The clean build with a separate scratch path has no warning from this package (only the vendored mlx-swift Metal header warnings). IntegrationTests builds.
    - commit: changed — 421e6b0 feat(telemetry): record router metrics through swift-metrics (^a3qhq6a)
    - review: findings — 1 (RoutedSessionActorGenerationCalls.swift:162 completeness/invariant-propagation)
  timestamp: 2026-09-28T22:49:05.445122+00:00
- actor: claude-code
  id: 01m3n3es03j3hyj6g8ajx9c0vy
  text: |-
    ### implement — changed
    - evidence: the finding RoutedSessionActorGenerationCalls.swift:162 (completeness/invariant-propagation). `restartGenerationCallClock()` had one caller (`deliver(invocation:)` in RoutedSessionActorRunJournal.swift), but the reset lived away from the handling of the open record. Now one method, `noteGenerationCallBoundary(at:)` in RoutedSessionActorGenerationCalls.swift, moves the ledger across each tool invocation record: an open record reports the ended call, and a close record resets `callStartedAt`. `deliver(invocation:)` calls it. `restartGenerationCallClock()` is gone. 2 files: Session/RoutedSessionActorGenerationCalls.swift, Session/RoutedSessionActorRunJournal.swift.
    - test: swift test — 1409 + 22 + 19 tests passed (2 known issues), exit 0; the build has no warning.
    - next: /commit, then /review HEAD~1..HEAD
  timestamp: 2026-09-28T22:51:33.763444+00:00
- actor: claude-code
  id: 01m3n3jst95et8tacfss7typtw
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (e272bc3) — 0 findings, 0 refuted; the prior finding (RoutedSessionActorGenerationCalls.swift:162) is corrected and checked.
    - next: none; the task is done.

    ### finish iteration 2 — clean
    - implement: changed — `noteGenerationCallBoundary(at:)` moves the ledger across each tool invocation record; `restartGenerationCallClock()` is gone.
    - test: green — swift test: 1409 + 22 + 19 tests passed (2 known issues), exit 0.
    - commit: changed — e272bc3 refactor(session): move the ledger across each tool invocation record in one method (^a3qhq6a)
    - review: clean — 0 findings; the review moved the task to done.
  timestamp: 2026-09-28T22:53:45.673696+00:00
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: done
position_ordinal: ffffffb380
title: 'OTel router B: record metrics for tokens, time to first token, load time, resident memory, queue depth and compactions'
---
## What
Design approved by the user on 2026-09-28 (see task 01M3MND1G818WNMRPDFRAG2E91 for the rules). The router records metrics through the swift-metrics API only (product `Metrics`; no backend, no swift-otel). Each metric name and each dimension key is in `RouterTelemetry.MetricName` / `RouterTelemetry.MetricDimension` (the vocabulary from task A), prefixed with the module name. A dimension carries only identifiers, names and slots (for example `model.ref`, `slot`, `compaction.trigger`), never content.

Depends on router task 01M3MND1G818WNMRPDFRAG2E91 (the vocabulary rename and swift-log). Blocked by Extras task 01M3MN838VZ4QX57C3965XMGKV (^65xmgkv, swift-metrics pin).

Metrics, and where the number exists today:
- Tokens in and out for each generation call (counters): `GenerationCallUsage` (`Session/GenerationCallUsage.swift:20-25`), built in `RoutedSessionActorGenerationCalls.swift:118-133`; the submission span already sets them (`RoutedSessionActorSubmissionEvents.swift:112-113`).
- Tokens per second (a recorder): output tokens divided by the duration of the generation call.
- Time to first token (a timer): not measured today. Measure from `submissionStarted(at:)` / `submissionStartedAt` (`GenerationPassObserver.swift:13-16,96-104`, `GenerationStall.swift:203`) to the first generation progress (`noteGenerationProgress`, `GenerationStall.swift:299`, called at `RoutedSessionActorGeneration.swift:251`). Use `ContinuousClock`.
- Model load duration (a timer, dimension `model.ref`, `slot`): not measured today; measure in `withLoadSpan` (`Router.swift:752-764`).
- Resident model memory (a gauge, bytes): the Extras `ModelPool.footprints` stream (`ModelPoolFootprint.totalBytes`, `resident`). The router already reads this stream in `PromptCacheSizing` (`Sizing/PromptCacheSizing.swift:48,65-68`); record the gauge from the same task. Only one router may own a process-wide gauge value; choose and document how two routers on one pool avoid two writers (for example, record the value, which is the same for each reader).
- Submission queue depth (a gauge, dimension `session.id` is NOT allowed if it makes an unbounded label set; use no session dimension or a bounded one): `messageQueueDepth()` (`RoutedSessionActorQueueing.swift:66`, Extras `MessageQueueDepth`), and `GenerationQueue.waitingCount` for each model (dimension `model.ref`).
- Compaction count by trigger (a counter, dimension `compaction.trigger`): `withCompactionSpan(trigger:)` at `RoutedSessionActorCompaction.swift:164,210,235`, with `RouterTelemetry.CompactionTrigger`.

- `Package.swift`: add swift-metrics; product `Metrics` to the library target; `MetricsTestKit` (or the Extras `TelemetryCapture`) to the unit test target.
- Keep every construct in the memory file `routed-session-cancellation-invariants.md`; a metric record must not add a suspension point inside the pump's no-suspension windows.

Facts from the Extras OTel work (swissarmyhammer session, 2026-09-28; do not start until Extras OTel A-D are on Extras `origin/main`):
- Extras already records the tool metrics `FoundationModelsExtras.tool.calls` and `FoundationModelsExtras.tool.duration`, with the dimensions `tool.name` and `tool.outcome` only (names in `ExtrasTelemetry.swift`). The router must not record a second tool metric.
- A metric that is made before the first `TelemetryCapture` does not go to the capture. Do not store the router's metrics in `static let`s that a test can touch first; make them per call or per instance, or make sure that the capture starts first. A test process that uses `TelemetryCapture` must not bootstrap logging itself.

## Acceptance Criteria
- [ ] Each metric above is recorded through swift-metrics with its name and dimensions in the vocabulary.
- [ ] No dimension value carries content, and no dimension makes an unbounded label set.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Unit tests with a test metrics backend (`MetricsTestKit` or `TelemetryCapture`) and a scripted session: each metric is recorded with the expected name, dimensions and value (tokens, a compaction by each trigger, a load, a resolve that changes the footprint, a queue with waiting messages). Time values: check that they are recorded and not negative; do not wait on the clock.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo

## Review Findings (2026-09-28 17:35)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 17 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCalls.swift:162` `completeness/invariant-propagation` — Function `restartGenerationCallClock()` is defined to reset the call timer after a tool result, but is never called anywhere in the marked changes. The comment states 'The model reads the tool output in the next generation call, which starts now', but the integration point is missing, leaving the call start time unreset and causing incorrect duration measurements for calls following tool invocations. Identify the location where tool results are processed (likely in `noteToolResult` or a similar handler, not shown in marked lines) and add a call to `restartGenerationCallClock()` there to reset the clock before the next generation call.

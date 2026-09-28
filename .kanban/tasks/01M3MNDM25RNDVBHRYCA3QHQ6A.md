---
assignees:
- claude-code
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: todo
position_ordinal: ab80
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

## Acceptance Criteria
- [ ] Each metric above is recorded through swift-metrics with its name and dimensions in the vocabulary.
- [ ] No dimension value carries content, and no dimension makes an unbounded label set.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Unit tests with a test metrics backend (`MetricsTestKit` or `TelemetryCapture`) and a scripted session: each metric is recorded with the expected name, dimensions and value (tokens, a compaction by each trigger, a load, a resolve that changes the footprint, a queue with waiting messages). Time values: check that they are recorded and not negative; do not wait on the clock.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo
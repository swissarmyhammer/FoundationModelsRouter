---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: FoundationModelsRouterEvals gated suites are unserialized — two resident 27B models possible
---
Found during the `^ce4hb6n` audit of which gated suites reach the metallib bootstrap. Not a metallib defect — a RAM-exhaustion risk that only became reachable now that the Evals target can actually load real models.

`Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` gives the integration target a process-wide value-1 permit precisely because "with real ~15-20GB models in the `.standard`/`.flash` slots, that concurrency is a real RAM risk". Its own doc comment records that the permit covers that target only, since `FoundationModelsRouterEvals` is a separate module in a separate `swift test` process.

`FoundationModelsRouterEvals` has no equivalent:
- No gate. Neither gated eval suite is `.serialized`, and neither carries a `.timeLimit`, unlike all 8 gated integration suites.
- `CompactionEvalRealSubjectRunner` and `CompactionContinuityEvalRealSubjectRunner` are independent actors, each caching its own `loaded` container. Both resolve the SAME `mlx-community/Qwen3.6-27B-mxfp4` (`Support/CompactionEvalRealSubjectRunner.swift`, `CompactionEvalRealModel.ref`, reused by the continuity runner).
- Distinct `@Suite` types run concurrently by default in Swift Testing, so both containers can be resident simultaneously — two copies of a 27B model in one process.

Observed in the 2026-08-08 gated run: the two eval tests took 299.8s and 511.4s and overlapped. It did not OOM on this machine, but nothing prevents it.

Second, related defect in the same target: `evictIfLoaded()` is called inside each `@Test` body, which runs AFTER the `.evaluates(...)` trait has finished all inference, and is skipped entirely if an earlier `#expect` traps. Eviction is therefore not guaranteed on the failure path — and both eval tests currently fail (see `^5m97h14`), so today eviction is being skipped in practice.

## Acceptance Criteria
- [ ] The two gated eval suites cannot hold two real models at once — a target-wide permit mirroring `GatedSuiteSerialGate`, or one shared container, or `.serialized` at the right scope
- [ ] Rationale recorded for whichever mechanism is chosen, including whether the two runners should share one container rather than caching two
- [ ] Model eviction happens even when a test fails or traps, not only on the success path
- [ ] Gated eval suites carry a `.timeLimit` like every gated integration suite, so a hung real-model load cannot run unbounded
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Gated run shows the two eval suites no longer overlapping their model residency. Gated runs: one at a time, one shell command per run. #phase-1
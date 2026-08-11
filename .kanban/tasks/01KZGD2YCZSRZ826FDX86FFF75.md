---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzpq9rgndc6hfcsfqhr6m2d6
  text: |-
    Research done.

    Findings that decided the mechanism:

    1. The two runners CANNOT share one container. `LiveModelLoader` stores `samplingMode` on the `MLXFoundationModelsContainer` it builds (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` — `MLXFoundationModelsContainer(model:samplingMode:)`), and every session made from that container inherits it. `CompactionContinuityEvalRealSubjectRunner` pins `samplingMode: .greedy` on purpose (task f80n046: the provider default samples at temperature 0.6 from MLX's clock-seeded process-global PRNG, which made `mean(AnswersCorrect)` read 0.5/0.8/0.7 across three runs of identical code). `CompactionEvalRealSubjectRunner` leaves the provider default in place. One shared container would silently change one eval's decoding. So: a permit, mirroring `GatedSuiteSerialGate`, not a shared container.

    2. `.serialized` cannot close the hole. Swift Testing's `ParallelizationTrait` serializes WITHIN a suite; distinct `@Suite` types still run concurrently with each other. That is the exact sentence `GatedSuiteSerialGate`'s own doc comment records.

    3. The permit must be taken at SUITE scope, not in the `@Test` body. `.evaluates(...)` does its inference inside a `TestScoping` trait that runs ahead of the body (both runners' `container()` already carry that comment), so a body-level permit would be taken after the model is already resident. A `SuiteTrait & TestScoping` scope wraps the suite's whole plan step, so it is outside every test-level trait regardless of trait order.

    4. Same scope solves eviction. `evictIfLoaded()` inside the body is skipped whenever the body does not run (the `.evaluates` trait threw) or exits early on a `try`. Evicting inside the suite scope, on both the success and the throw path, runs regardless of outcome — and evicting BEFORE the permit is released is what makes double residency structurally impossible rather than merely scheduled against.

    5. `.timeLimit` values in the 8 gated integration suites: 30 (IntegrationTests), 20 (SessionTreeRestoration), 15 (CompactionSpike), 15 (LanguageModelSessionBackend), 15 (TranscriptReconstruction), 20 (CompactionRoundTrip), 15 (RecordingHandle), 15 (PropagationProbe). `CompactionRoundTripIntegrationTests` is the one that loads the SAME `mlx-community/Qwen3.6-27B-mxfp4` into `.standard` and drives multi-turn compaction, and it uses 20.
  timestamp: 2026-08-10T20:54:48.085838+00:00
- actor: claude-code
  id: 01kzpqhgd5jb1hkmka7yv129hp
  text: |-
    Implementation landed.

    Mechanism: a target-wide value-1 permit (`GatedEvalSerialGate.shared`, an `AsyncSemaphore`) held by a new `GatedEvalResidencyTrait`, which is a `SuiteTrait & TestScoping` applied to each gated eval suite. Rationale is recorded in `GatedEvalSerialGate`'s own doc comment, in three sections: why a permit and not one shared container (the two runners carry different `samplingMode`, which lives on the container), why not `.serialized`, and why the permit is taken at suite scope.

    Structural argument, since the gated path cannot be run here:

    - The trait's `scopeProvider(for:testCase:)` is written out rather than inherited, and returns `self` only when `test.isSuite`. Without that, the `Trait where Self: TestScoping` default would also provide a per-test-case scope, and the same value-1 permit would be taken twice — a deadlock. The suite-only scope is also what puts the permit outside `.evaluates(...)`, whose own `TestScoping` scope is where the model actually loads.
    - `provideScope` runs the whole suite inside `AsyncSemaphore.withPermit`. Inside it, `try await function()` is caught into a `Result`, `await runner.evictIfLoaded()` runs next on BOTH the success and the throwing path, and only then is the `Result` rethrown. `withPermit`'s own `defer { signal() }` releases the permit after that. So eviction always precedes release, and the next suite cannot acquire the permit while the previous suite's model is still resident. Double residency is now impossible by construction, not merely scheduled against.
    - The `@Test` bodies no longer call `evictIfLoaded()`; eviction is only in the trait.

    `.timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))` with the constant set to 20, matching `CompactionRoundTripIntegrationTests` — the gated integration suite that loads the SAME `mlx-community/Qwen3.6-27B-mxfp4` into `.standard` and drives multi-turn compaction. `TimeLimitTrait` declares its own `isRecursive` and has `TestScopeProvider == Never`, so the runner applies the limit to each test case rather than wrapping the suite; the time a suite spends waiting on the permit is therefore not charged against its limit.

    Not run, deliberately: the gated suites. `FM_ROUTER_INTEGRATION_TESTS=1` loads a 27B model and costs 8-11 minutes per suite. The Tests checkbox stays unticked.

    Also checked: `python3 Scripts/check-doc-links.py` — 1293 symbol links scanned, 0 stale, 0 unresolved. Every `- Parameter` key I added uses the INTERNAL name (`test`, `testCase`, `function`, `runner`), never the external label (`for`, `performing`, `of`); the checker is blind to that class of error, so it was checked by hand.
  timestamp: 2026-08-10T20:59:01.925936+00:00
- actor: claude-code
  id: 01kzpqhv8q8df4zsfz6rj93gha
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift (new), Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluationTests.swift. `swift build --build-tests` clean, 0 compiler warnings. Ungated `swift test`: 783 tests in 75 suites + 24 tests in 9 suites + 24 tests in 5 suites, all passed, exit 0; the 1 known issue is the pre-existing `withKnownIssue` at BoundedWait.swift:114. `Scripts/check-doc-links.py`: 0 stale, 0 unresolved. NOT RUN: the gated eval suites (FM_ROUTER_INTEGRATION_TESTS).
    - next: /review
  timestamp: 2026-08-10T20:59:13.047474+00:00
- actor: claude-code
  id: 01kzpr39rrc7g4y66heypednqf
  text: |-
    ### review — clean
    - scope: `review sha HEAD~1..HEAD` (commit 70ca94b), 9 validators attempted, 0 failed, 0 skipped
    - engine counts: 1 finding, 1 confirmed, 0 refuted. The one finding — `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift:212` "Magic numbers should be replaced by named constants" (`maxTokens: 64`) — is DROPPED under the review skill's blanket exception on existing test code. `git blame` puts that line at 10955bea (2026-07-24); this commit touched only line 26 (protocol conformance) and the `evictIfLoaded()` doc comment in that file. No recordable findings.
    - structural verification (the gated path cannot run here; a gated suite loads a 27B model for 8-11 minutes):
      - eviction precedes permit release: `GatedEvalSerialGate.swift:127-137` catches `try await function()` into `Result`, calls `await runner.evictIfLoaded()` unconditionally after the do/catch, then `try outcome.get()` rethrows. No early return or rethrow sits between the catch and the eviction. `AsyncSemaphore.withPermit` (`Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:98-102`) is `await wait()` / `defer { signal() }` / `try await body()`, so the permit is handed back after the body, that is after the eviction.
      - no deadlock: `scopeProvider(for:testCase:)` is stated, not inherited, at `GatedEvalSerialGate.swift:107-109` — `test.isSuite ? self : nil`. No per-test-case scope, so the value-1 permit is taken once.
      - eviction on the trap path: `evictIfLoaded` appears in the Evals target only as the protocol requirement (`GatedEvalSerialGate.swift:82`), the two actor definitions (`CompactionEvalRealSubjectRunner.swift:180`, `CompactionContinuityEvalRealSubjectRunner.swift:264`), and the single call site `GatedEvalSerialGate.swift:135`. Neither `@Test` body calls it. The trait receives the same file-scope runner instance each `@Test` body reads.
      - cancellation: `AsyncSemaphore` waits on `CheckedContinuation<Void, Never>` (`AsyncSemaphore.swift:38,58,79`), so `wait()` cannot throw and the `defer { signal() }` is always installed after a real acquire. The release path holds under cancellation.
      - time limit: `gatedEvalSuiteTimeLimitMinutes = 20` (`GatedEvalSerialGate.swift:77`) matches `.timeLimit(.minutes(20))` at `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift:69`. The limit applies per test case, so permit wait time is not charged against it.
      - both gated eval suites covered: `CompactionEvaluationTests.swift:415-418` and `CompactionContinuityEvaluationTests.swift:243-246` each carry `.exclusiveResidentModel(of:)` and `.timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))`. Both runners conform to `GatedEvalRealModelRunner` (`CompactionEvalRealSubjectRunner.swift:68`, `CompactionContinuityEvalRealSubjectRunner.swift:26`).
      - rationale recorded in code (AC #2): `GatedEvalSerialGate.swift:8-38` carries both arguments in the doc comment — `samplingMode` is stored on the container and the continuity runner pins `.greedy` against the provider default, so one shared container would silently re-measure one eval; `.serialized` serializes within a suite only.
    - DocC checked by hand, not by `Scripts/check-doc-links.py`: `- Parameter`/`- Parameters` keys use internal names throughout `GatedEvalSerialGate.swift` (`test`, `testCase`, `function`, and `runner` for `exclusiveResidentModel(of runner:)`). Symbol links use external labels (`scopeProvider(for:testCase:)`). `` ``MetalLibraryTestBootstrap`` `` resolves — the Evals target depends on `FoundationModelsRouterTestSupport` (`Package.swift:167`), where it is defined. `GatedSuiteSerialGate` correctly uses single backticks as a cross-target reference.
    - The Tests line stays unticked as not-run by design: a gated run costs 8-11 minutes per suite and was not spent. Not treated as a finding.
    - next: none — task advanced to done.
  timestamp: 2026-08-10T21:08:44.952755+00:00
- actor: claude-code
  id: 01kzpr7397d6jhzk8v8ebk2hef
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 test files; new GatedEvalSerialGate.swift (target-wide value-1 permit + GatedEvalResidencyTrait + gatedEvalSuiteTimeLimitMinutes=20 + GatedEvalRealModelRunner)
    - test: green — ungated swift test exit 0: 783/75 + 24/9 + 24/5, 0 warnings; 1 pre-existing known issue at BoundedWait.swift:114; check-doc-links.py 0 stale / 0 unresolved
    - commit: 70ca94b
    - review: clean — 1 engine finding dropped under the existing-test exception (CompactionContinuityEvalRealSubjectRunner.swift:212, blame 10955bea, untouched by this commit); card moved to done
    - mechanism rationale (AC#2), recorded in GatedEvalSerialGate.swift:8-38: a permit was chosen over ONE SHARED CONTAINER because samplingMode is stored on the container and the two runners deliberately differ (continuity runner pins .greedy; the other keeps the provider default), so sharing would silently re-measure one eval. `.serialized` was rejected because it serializes within a suite only, not across two distinct suites.
    - eviction on the trap path proved structurally at GatedEvalSerialGate.swift:127-137 — function() is caught into a Result, evictIfLoaded() runs unconditionally, then the Result is rethrown; withPermit's `defer { signal() }` releases after, so eviction always precedes release
    - deadlock avoided at GatedEvalSerialGate.swift:107-109 — scopeProvider is stated, not inherited, returning self only when test.isSuite, so the value-1 permit is taken once
    - AC NOT SATISFIED (environment limit, not a defect): the Tests line "Gated run shows the two eval suites no longer overlapping their model residency" was NOT RUN — 27B model, 8-11 min per suite. Left unticked deliberately. The residency argument above is structural, not empirical; a gated run is still the only empirical confirmation.
  timestamp: 2026-08-10T21:10:49.383591+00:00
position_column: done
position_ordinal: ff8380
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
- [x] The two gated eval suites cannot hold two real models at once — a target-wide permit mirroring `GatedSuiteSerialGate`, or one shared container, or `.serialized` at the right scope
- [x] Rationale recorded for whichever mechanism is chosen, including whether the two runners should share one container rather than caching two
- [x] Model eviction happens even when a test fails or traps, not only on the success path
- [x] Gated eval suites carry a `.timeLimit` like every gated integration suite, so a hung real-model load cannot run unbounded
- [x] Ungated `swift test` stays green

## Tests
- [ ] Gated run shows the two eval suites no longer overlapping their model residency. Gated runs: one at a time, one shell command per run. NOT RUN — a gated run loads a 27B model and costs 8-11 minutes per suite, which this environment cannot spend. Never report this line as passed on the strength of the ungated run. The structural argument is in the comments and in `GatedEvalSerialGate`'s doc comment. #phase-1
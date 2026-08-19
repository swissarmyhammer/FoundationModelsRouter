---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dzy4aa79z1x2fs05s4q9dp
  text: |-
    Picked up. Research results, from the current source:

    - The card is older than commit efd3b58 (task ^k0d30s4). The tiers now drive the 1B model, and the env-var gate is gone. The runs of 2026-08-19 drove the samples one at a time and cost less than 2 minutes for each tier.
    - `Evaluation.run(info:)` in the installed `Evaluations.framework` interface has no concurrency parameter. The trait cannot ask for a dispatch shape. This agrees with the card.
    - `CompactionEvalProgressLog` no longer prints `elapsed=0.0s` on a sample's first step. The runner passes `nil`, and the line has no `elapsed=` clause. The doc comment there records the old misread.
    - `^9cw5g6n`'s description now carries the correction and points at this card. Its comment thread on ^h2xxsse still states the old concurrent conclusion; that text is history in an append-only comment.
    - The tier limits in `CompactionEvalTiers.swift` rest on per-sample figures "read off that sample's own progress lines". Those figures are clean only when one sample runs at a time. Under concurrent dispatch, each sample's clock would include waits for the one resident container.
    - Both runners (`CompactionEvalRealSubjectRunner`, `CompactionContinuityEvalRealSubjectRunner`) are actors, and actor methods interleave at each `await`. Neither runner holds the shape today.

    Plan:
    1. Add a hermetic test in `Tests/FoundationModelsRouterEvals` that drives `Evaluation.run(info:)` over the real seed dataset with a fake subject and no `ModelJudgeEvaluator`, records how many samples are in flight at the same time, and states the answer. No model.
    2. Make the dispatch shape a decision the code holds: each runner takes a value-1 `AsyncSemaphore` permit at the top of `run`, so one sample runs at a time whatever shape the framework dispatches. The sample's clock and label start after the permit, so a wait is charged to no sample.
    3. Add a short correction comment on ^h2xxsse, so no card thread ends on the elapsed=0.0s misread.
    4. Run the subset tier once (about 1 minute) to record a serial trail against the changed runner.
  timestamp: 2026-08-19T21:48:16.074733+00:00
- actor: claude-code
  id: 01m0e0a8w29z2q4ygxqe7n18f8
  text: |-
    Implementation is done. What landed, and the evidence for each criterion:

    1. Hermetic dispatch-shape test — new `Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift`. It drives `Evaluation.run(info:)` over all 24 seeds with a fake subject that suspends 20 ms, records in-flight counts through an actor, and uses no `ModelJudgeEvaluator`. Measured answer: the framework drives ONE sample at a time (0.639 s for 24 samples, max in-flight 1). The assertion is live: a temporary `== 2` failed, and the restored `== 1` passes.
    2. The dispatch shape is now a decision the code holds. `CompactionEvalRealSubjectRunner` and `CompactionContinuityEvalRealSubjectRunner` each hold a value-1 `AsyncSemaphore` around one sample's whole `run`, taken before the sample's label and clock, so a wait is charged to no sample's trail. The tier limit docs in `CompactionEvalTiers.swift` now rest their sum arithmetic on this permit (and no longer on an MLX serial-access claim).
    3. `elapsed=0.0s` sweep: `CompactionEvalProgressLog` already prints no `elapsed=` clause on a first step and its doc records the old misread; `^9cw5g6n`'s description was already corrected; a correction comment now sits on `^h2xxsse`, whose thread carried the last statement of the misread. `^azd033m` reads the ORDER of the lines, which is valid.
    4. One measured gated run of the subset tier against the changed runner: strictly serial trail, all 7 samples complete, suite green in 17.4 s (log: scratchpad/gated-subset-23qeprz.log). Per-sample costs 1.9-3.5 s, inside the pinned dearest constant.

    Tests: `Scripts/swift-test.sh --skip IntegrationTests` green — 1020 tests (1 pre-existing known issue) + 76 tests (75 baseline + the 1 new test). `swift build --build-tests` clean, no warnings.

    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift (new), Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionContinuityEvalRealSubjectRunner.swift, Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift; Scripts/swift-test.sh --skip IntegrationTests = 1020 + 76 passed; Scripts/swift-test.sh --filter CompactionEvaluationIntegrationTests = 1 test passed in 17.4 s with a serial trail
    - next: review
  timestamp: 2026-08-19T21:54:53.954061+00:00
- actor: claude-code
  id: 01m0e0d3h5hznrw4s7d5n13493
  text: |-
    ### test — green
    - Command 1: Scripts/swift-test.sh --skip IntegrationTests
    - Result: 1020 tests in 96 suites passed, 1 known issue (the known BoundedWaitTests issue). 76 tests in 9 suites passed, 0 known issues.
    - Command 2: swift build --build-tests -Xswiftc -warnings-as-errors
    - Result: build complete, exit code 0. No swift compiler warnings. One llbuild infra note about a bundle output node, not a code warning.
    - No real-model IntegrationTests suites run. No FM_ROUTER_* env vars used. No swift format run.
    - next: hand off to review step.
  timestamp: 2026-08-19T21:56:26.789817+00:00
- actor: claude-code
  id: 01m0e104nfkfmne25tn6fpvfh6
  text: |-
    ### review — findings
    - evidence: `review sha b05508d~1..b05508d` (local backend) — counts: 1 finding, 1 confirmed, 0 refuted. Finding at `Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift:12` (`reuse/reuse`): the recorder actor duplicates `ConcurrencyPeakObserver`.
    - next: reuse or extend `ConcurrencyPeakObserver` from `ConcurrencyObservingContainer.swift`, then run the review again. The task stays in `review`.
  timestamp: 2026-08-19T22:06:50.543590+00:00
- actor: claude-code
  id: 01m0e1gks42yhdkb3b5vq3jr8f
  text: |-
    The reuse finding is corrected. What changed:

    - `ConcurrencyPeakObserver` moved to a new file `Tests/FoundationModelsRouterTestSupport/ConcurrencyPeakObserver.swift`, made `public`, and given the `enteredCount` property the dispatch-shape test needs. SwiftPM cannot share source between two test targets, so the shared support target is the one place both test targets can read.
    - `Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift` no longer declares the actor. It imports `FoundationModelsRouterTestSupport` and a note points at the shared copy. `SharedGenerationGateContentionTests.swift` gets the same import.
    - `Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift` no longer declares the duplicate `CompactionEvalDispatchShapeRecorder`. The test uses the shared `ConcurrencyPeakObserver` (`enter`/`exit`, `maximumActive`, `enteredCount`). The assertions did not change in meaning.
    - `Package.swift` adds `FoundationModelsRouterTestSupport` to the `FoundationModelsRouterEvals` target, with a comment that states why.

    Sweep for other copies of the pattern: `ForkConcurrencyTests.SerialObserver` and `HumanWaitGateTests.TurnObserver` also count entries, but each records the ORDER of entries in a list, which `ConcurrencyPeakObserver` does not hold. Both actors existed before this change, and no line of this change touches them. The one duplicate this change added is removed.

    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterTestSupport/ConcurrencyPeakObserver.swift (new), Tests/FoundationModelsRouterTests/Helpers/ConcurrencyObservingContainer.swift, Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift, Package.swift; Scripts/swift-test.sh --skip IntegrationTests = 1020 tests in 96 suites passed (1 known issue) + 76 tests in 9 suites passed; swift build --build-tests -Xswiftc -warnings-as-errors = exit 0, no compiler warnings
    - next: review
  timestamp: 2026-08-19T22:15:50.308853+00:00
- actor: claude-code
  id: 01m0e1kpskck8cp1fjcpjzcbtv
  text: |-
    ### test — green
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` builds all targets clean, no warnings. `Scripts/swift-test.sh --skip IntegrationTests` — 1020 tests in 96 suites passed (1 known issue, the pre-existing BoundedWaitTests issue) plus 76 tests in 9 suites passed. No test failed. No test was skipped. No warning was found.
    - next: hand off to the next step in the pipeline.
  timestamp: 2026-08-19T22:17:31.699843+00:00
position_column: doing
position_ordinal: '8480'
title: Two gated runs of the same eval code drove the samples two different ways, so the tier's dispatch shape is unmeasured
---
Found while correcting `^9cw5g6n`. `^9cw5g6n` states that `Evaluations` drives this tier's samples concurrently. The raw trails say that is true of one run and false of another, and no code changed between them.

## The two trails

Both logs sit in this session's scratchpad, and both ran `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` over the same seven subset seeds.

`gated-run-3.log`, 2026-08-18 07:34 (task `^h2xxsse`, right after commit `523689b`):

```
sample=1/7 ... fold started elapsed=0.0s
sample=2/7 ... fold started elapsed=0.0s
sample=3/7 ... fold started elapsed=0.0s
sample=4/7 ... fold started elapsed=0.0s
sample=5/7 ... fold started elapsed=0.0s
sample=6/7 ... fold started elapsed=0.0s
✘ Time limit was exceeded: 1800.000 seconds
sample=7/7 ... fold started elapsed=0.0s
```

Six samples in flight together. No fold returned in 1800 s. `0 of 7 seeds measured`.

`gated-crit5.log`, 2026-08-18 16:38 (task `^6ssbakk`, commit `3b433fb`):

```
sample=1/7 ... fold started elapsed=0.0s
sample=1/7 ... fold returned elapsed=241.7s took=241.7s
sample=1/7 ... answer started elapsed=241.7s
sample=1/7 ... answer returned elapsed=295.1s took=53.4s
sample=2/7 ... fold started elapsed=0.0s
...
```

Strictly one sample at a time, samples 1 through 7 in order, every sample's four lines complete before the next sample's first line. `6 of 7 seeds measured`.

`git diff 523689b 3b433fb -- Tests/FoundationModelsRouterEvals Sources/` touches `Summarization.swift`, `UTF8Budget.swift`, `ToolOutputCapping.swift` and `CompactionEvaluationTests.swift`. It touches NOTHING that dispatches a sample: `CompactionEvalRealSubjectRunner`, `CompactionEvaluation` and the `.evaluates(...)` trait are all identical across the two runs.

## Why this matters

Both time limits rest on how the tier spends its time, and the shape decides that. Six samples in flight cost the run all seven samples when the limit fires; one sample at a time costs the run only the tail. `^h2xxsse` reported `0 of 7` and `^6ssbakk` reported `6 of 7` for the same seven seeds, and the difference is the shape rather than the model.

A per-sample cost read off a trail is only clean when the samples ran one at a time. `^6ssbakk`'s figures are clean by that test. `^h2xxsse`'s would have carried each sample's wait on the other five.

## One correction this card carries

`elapsed=0.0s` on a `fold started` line proves NOTHING about concurrency. `CompactionEvalRealSubjectRunner.run(entries:prompt:budget:question:)` passes `elapsedSeconds: 0` as a literal, so the field is the sample's own elapsed time and it is zero at every fold start. `^9cw5g6n`'s description reads that field as evidence. The real evidence is the ORDER of the lines: seven `fold started` lines with no `fold returned` line between them.

## What to do

- Measure the dispatch shape rather than reading it off a trail. A hermetic `Evaluation` — a small dataset, a `subject(from:)` that records how many samples are in flight, and no `ModelJudgeEvaluator` — drives `Evaluation.run(info:)` with no model at all and states the answer.
- Decide what the tier should do with the answer. `Evaluation.run(info:)` and `.evaluates(_:info:recordTranscripts:)` take no concurrency limit, so the tier cannot ask for one. Serialising the samples inside `CompactionEvalRealSubjectRunner` is the seam that is available.
- Correct `^9cw5g6n`'s description, which states the concurrent shape as a settled fact.

## Acceptance Criteria

- [x] A hermetic test states how many samples `Evaluations` drives at once, and it needs no model
- [x] The tier's dispatch shape is a decision the code holds, or the code records that the shape is the framework's and states what a reader must not conclude from it
- [x] No document reads `elapsed=0.0s` as evidence of concurrency

## Related

- `^9cw5g6n` — the card whose premise this bounds.
- `^6ssbakk` — the serial trail, and the per-sample figures both limits now rest on.
- `^h2xxsse` — the concurrent trail, and the instrumentation that made both legible.

## Review Findings (2026-08-19 16:58)

> Scope: `review sha b05508d~1..b05508d` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterEvals/CompactionEvalDispatchShapeTests.swift:12` `reuse/reuse` — CompactionEvalDispatchShapeRecorder reimplements a near-identical observer pattern that already exists as ConcurrencyPeakObserver in the test suite. Both track concurrent entry/exit and peak concurrency, differing only in naming (enter/exit vs recordEntry/recordExit) and the addition of enteredCount. The existing observer should have been extended or reused rather than creating a parallel implementation. Reuse or extend ConcurrencyPeakObserver from ConcurrencyObservingContainer.swift, adding enteredCount tracking if needed, rather than defining a duplicate actor. This keeps one canonical implementation of the concurrent-entry observer pattern. #compaction #eval #real-model #test-debt
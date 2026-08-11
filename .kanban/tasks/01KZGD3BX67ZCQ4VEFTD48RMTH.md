---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzprzzrp0m4h9z1txrqbbvkk
  text: |-
    Implementation notes.

    Mechanism. Both gated targets now trigger `MetalLibraryTestBootstrap` from one suite-scoped `SuiteTrait & TestScoping`, never from a test body.
    - Integration: new `GatedRealModelSuiteTrait` in `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift`, applied as `.exclusiveRealModel` to all 8 gated `@Suite`s. Its `provideScope` reads `MetalLibraryTestBootstrap.ensureColocatedMetallib`, then holds `GatedSuiteSerialGate.shared` for the whole suite.
    - Evals: the existing `GatedEvalResidencyTrait` (built by `^86fff75`) gained the same bootstrap read at the head of `provideScope`. No second trait was invented.

    Chokepoints. Three became two, one per `swift test` process, with no duplicate left behind:
    - removed from `GatedSuiteSerialGate.shared`'s initializer (the property is now a plain `AsyncSemaphore(value: 1)`),
    - removed from `CompactionEvalRealSubjectRunner.container()` and `CompactionContinuityEvalRealSubjectRunner.container()` (both files also dropped the now-unused `import FoundationModelsRouterTestSupport`),
    - added to the two traits. `grep -rn ensureColocatedMetallib` returns the declaration plus exactly those two reads.

    Ordering against `.evaluates(...)`. A `SuiteTrait`'s scope wraps the suite's whole plan step, so it is outside every test-level trait whatever order the traits are written in — including `.evaluates(...)`, which runs the entire evaluation (model load included) ahead of the `@Test` body. That is why the trigger is suite-scoped rather than test-scoped, and it is written down in three places: `GatedEvalResidencyTrait.provideScope(for:testCase:performing:)`, `GatedRealModelSuiteTrait`'s "Ordering against test-level traits" section, and `MetalLibraryTestBootstrap.ensureColocatedMetallib`.

    Per-test requirement removed. All 19 `GatedSuiteSerialGate.shared.withPermit { ... }` wrappers and the `wait()`/`defer signal()` pair in `IntegrationTests.endToEnd` are gone. The permit is now taken once per suite; a body that took it again would deadlock on the value-1 permit, and both traits' `scopeProvider(for:testCase:)` states `test.isSuite ? self : nil` for the same reason.

    Side effect worth knowing: a suite that parks waiting for the permit now parks OUTSIDE its tests, so the wait is no longer charged against each `@Test`'s `.timeLimit`. That is the behavior `GatedEvalSerialGate` already documents for the eval target.

    Dead end recorded so a later agent does not repeat it: the first unwrap pass matched the wrapper's closing brace by "first line equal to <indent>}". Most of these call sites never re-indented their body inside the wrapper, so that matched an inner `defer` block's brace and swallowed the rest of the function. The matching close is the line immediately before the function's own close; the second pass keyed on that pair and decides the dedent per site.
  timestamp: 2026-08-10T21:24:24.982835+00:00
- actor: claude-code
  id: 01kzps0bma6z0a249gz1kqb7vp
  text: |-
    AC #1 is DEMONSTRATED, both directions, on real hardware. It needed no model: mlx aborts on any GPU-device `MLXArray` evaluation, not on a 27B load.

    New file `Tests/FoundationModelsRouterIntegrationTests/MetalLibraryBootstrapIntegrationTests.swift` holds one gated `@Suite` carrying `.exclusiveRealModel` and one `@Test` that names no gate, no bootstrap, and no router type — it sums four integers with `sum(stream: .gpu)` and reads the result. It is the forgetful test the card describes, written on purpose, and it is a permanent regression guard.

    Positive, with the symlink deleted first so the pass cannot come from a leftover:

        rm -f .build/out/Products/Debug/FoundationModelsRouterIntegrationTests.xctest/Contents/MacOS/mlx.metallib
        FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter 'MetalLibraryBootstrapIntegrationTests'
        -> 1 test in 1 suite passed after 0.398s; the symlink exists again afterward, pointing at
           Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib

    Counterfactual, the same test with `.exclusiveRealModel` temporarily deleted from its `@Suite` line and the symlink deleted again:

        -> "MLX error: Failed to load the default metallib. library not found ... array.cpp:232"
           and the process died mid-test.

    The trait was restored and the positive run repeated green. Run in its own `--filter` invocation so an abort could not destroy other suites' results.

    NOT RUN, and not claimed: `FM_ROUTER_INTEGRATION_TESTS=1 swift test` and `MULTITOOL_INTEGRATION=1` over the full gated suites (27B model, 8-11 min). AC #4 and the Tests line stay unchecked.
  timestamp: 2026-08-10T21:24:37.130459+00:00
- actor: claude-code
  id: 01kzps0nd82t50r2289wmwc8sm
  text: |-
    ### implement — changed
    - evidence: 16 files. New `Tests/FoundationModelsRouterIntegrationTests/MetalLibraryBootstrapIntegrationTests.swift`; rewritten `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` (adds `GatedRealModelSuiteTrait` / `.exclusiveRealModel`, drops the bootstrap from the semaphore initializer); `.exclusiveRealModel` added and the per-test permit removed in IntegrationTests, SessionTreeRestoration, CompactionSpike, LanguageModelSessionBackend, TranscriptReconstruction, CompactionRoundTrip, RecordingHandle, PropagationProbe; Evals `Support/GatedEvalSerialGate.swift` (bootstrap moved into `provideScope`), both eval runners (trigger + unused import removed), both eval test files (stale doc reference), `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift` (doc).
    - verified: `swift build --build-tests` clean, 0 Swift errors/warnings; `swift test` green — 783 tests / 75 suites (1 pre-existing known issue in BoundedWait), 25 tests / 10 suites, 24 tests / 5 suites; `Scripts/check-doc-links.py` 1295 links scanned, 0 stale, 0 unresolved; `- Parameter` keys checked by hand (internal names `test`, `testCase`, `function`).
    - not run: full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` and any `MULTITOOL_INTEGRATION=1` run — AC #4 and the Tests line remain unchecked.
    - next: /review
  timestamp: 2026-08-10T21:24:47.144167+00:00
- actor: claude-code
  id: 01kzptbx5d9fet151de43cdd1f
  text: |-
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (46a56ae), 18 files.
    - engine counts: 6 findings, 8 confirmed, 3 refuted, 18 attempted, 0 failed. 1 finding recorded; 5 dropped under the skill's blanket exception on refactoring test code that already existed (4 name pre-existing helpers in SessionTreeRestoration/TranscriptReconstruction/RecordingHandle; 1 names a line in CompactionContinuityEvalRealSubjectRunner that this commit only removed an import and the bootstrap read from).
    - open finding: `Tests/FoundationModelsRouterIntegrationTests/MetalLibraryBootstrapIntegrationTests.swift:29`.

    Targeted verification of the removal risk — all six checks pass.

    1. Trait coverage. Nine gated `@Suite`s in the integration target, every one carrying `.exclusiveRealModel`: IntegrationTests.swift:205, SessionTreeRestorationIntegrationTests.swift:66, CompactionSpikeIntegrationTests.swift:50, LanguageModelSessionBackendTests.swift:47, TranscriptReconstructionIntegrationTests.swift:43, CompactionRoundTripIntegrationTests.swift:66, RecordingHandleIntegrationTests.swift:62, PropagationProbeIntegrationTests.swift:107, MetalLibraryBootstrapIntegrationTests.swift:56. Every file that lost a permit gained the trait, one for one — 19 `withPermit` removals across 7 files plus the `wait()`/`defer signal()` pair in IntegrationTests. The only trait-less suite is `ScriptedTurnSizingTests` (CompactionRoundTripIntegrationTests.swift:507), which is ungated, loads no model, and touches no MLX. No gated suite lost its gate.

    2. Permit residue. The permit is taken in exactly two places, both inside `provideScope`: GatedSuiteSerialGate.swift:92 and GatedEvalSerialGate.swift:139. No test body takes it, so nothing can deadlock on the value-1 permit. Every other mention in the two gated targets is doc-comment prose.

    3. Ordering against `.evaluates(...)` — CONFIRMED against swift-testing's source, not accepted on assertion. `Runner._runStep` wraps the whole step body, including the `_runChildren` recursion, in `_applyScopingTraits(for: step.test, testCase: nil)`; a suite step's scope therefore opens before any child step exists. A test-level scoping trait is reachable only from `_runChildren` -> `_runStep(child)` -> `_runTestCases` -> `_runTestCase` -> `_applyScopingTraits(..., testCase:)`, strictly inside. Written trait order decides nesting only within one declaration's own list, never across the suite/test boundary. `EvaluationTrait` (Evaluations.framework, `arm64-apple-macos.swiftinterface`) is `TestTrait, TestScoping` — test-level — and declares no `scopeProvider`, so it takes the default returning `self` only when `testCase != nil`. Its model load runs per test case, inside the suite trait's scope. The bootstrap is not too late.

    4. Chokepoints 3 -> 2, no duplicate. `ensureColocatedMetallib` has exactly two runtime reads: GatedSuiteSerialGate.swift:91 and GatedEvalSerialGate.swift:138, one per `swift test` process. All other hits are the declaration (MetalLibraryTestBootstrap.swift:41,58), string literals, or doc prose. In Evals, both real-model runners are file-private singletons reachable only from their own suite's `.exclusiveResidentModel(of:)` and the `.evaluates(...)` closure inside that same suite; the four hermetic suites import no MLX. No entry point in either target reaches a GPU `MLXArray` evaluation without passing through a trait.

    5. Demonstration test is real, and re-verified on hardware by this review. Its body names no gate, no permit, and no bootstrap — only `MLXArray`, `.sum(stream: .gpu)`, `#expect`, `.item`, `reduce`; the gate and bootstrap tokens in that file appear only in the doc comment above the suite. It is gated at :60 and carries the trait at :61. Reproduced the positive control: deleted the symlink, then `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter 'MetalLibraryBootstrapIntegrationTests'` -> 1 test in 1 suite passed after 0.039s, and the symlink was reinstalled pointing at `Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`. Since the trait is the only thing between that body and the abort, removing it would still surface the regression.

    6. `GatedEvalResidencyTrait` keeps its `^86fff75` job. The new bootstrap read was only prepended ahead of `withPermit`; nothing inside the closure moved. `evictIfLoaded()` (:147) still runs before `try outcome.get()` (:148) and both before the closure returns, so the `70ca94b` eviction-before-permit-release ordering holds on the success and failure paths alike.

    Also checked: `swift build --build-tests` clean; DocC `- Parameter` keys on the added code use internal names (`test`, `testCase`, `function`, `runner`) and match their declarations.

    Not run, per instruction and unchanged: full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` and any `MULTITOOL_INTEGRATION=1` run. AC #4 and the Tests line stay unticked as not-run, which is an environment limit rather than a finding.

    - next: address the open finding at MetalLibraryBootstrapIntegrationTests.swift:29, then re-review.
  timestamp: 2026-08-10T21:48:24.109678+00:00
- actor: claude-code
  id: 01kzpv6mg1cwtresks8k1ezf2m
  text: |-
    Review round 2 — the one open finding is closed, and the ordering documentation is corrected.

    Finding: `MetalLibraryBootstrapIntegrationTests.swift:29` — "Magic numbers should be replaced by named constants". Read the rule before fixing it: the Swift rule is swiftlint `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`. Run against the file as it stood, it reported three violations on that one line, at columns 54, 57 and 60 — the `2`, the `3` and the `4` of `[1, 2, 3, 4]`. The `1` was already allowed, and `reduce(0, +)` on the assertion line was never reported.

    The array is now built from two named bounds, so the run keeps its four operands and the probe's behaviour is byte-for-byte identical:

        private let metalLibraryProbeFirstOperand: Int32 = 1
        private let metalLibraryProbeLastOperand: Int32 = 4
        private let metalLibraryProbeOperands: [Int32] = Array(
            metalLibraryProbeFirstOperand...metalLibraryProbeLastOperand
        )

    The names state meaning, not value: the first and last operand of the run. Their doc comments carry the two reasons — the values themselves carry no meaning (evaluating *any* GPU-device `MLXArray` is what aborts the process), while the length does (four operands make the sum differ from every term, so a `sum` that returned one of its own terms would still fail the expectation). Re-running the rule over the file reports nothing.

    Ordering claim: MEASURED, not asserted. The previous round wrote "whatever order the traits are written in", which overstates the rule. A throwaway probe suite in the ungated target settled both halves on this toolchain, then was deleted:
    - Two `SuiteTrait & TestScoping` traits on ONE `@Suite` line, labelled A then B, printed `enter A, enter B, body, exit B, exit A`. Within one declaration's trait list the FIRST written is the outermost.
    - One suite trait plus a test-level trait on the `@Test` printed `enter SUITE-TRAIT, enter TEST-TRAIT, body, exit TEST-TRAIT, exit SUITE-TRAIT`. The suite scope encloses the test-level trait.
    - Third fact, from the compiler rather than the run: a `TestTrait` cannot be written on a `@Suite` line at all ("argument type 'OrderProbeTestTrait' does not conform to expected type 'SuiteTrait'"), so across the suite/test boundary written order is not even expressible.

    All four sites that carried the overstated wording now state the accurate rule — a suite scope opens before any child step exists, so it encloses every test-level trait no matter where among the suite's own traits it is written; but among the traits on one declaration the first written is the outermost:
    - `GatedRealModelSuiteTrait`'s "Ordering against test-level traits" section, which also names the consequence: a second suite trait that itself reached the GPU would have to be written after this one to run inside its scope.
    - `GatedEvalResidencyTrait.provideScope(for:testCase:performing:)`, whose "It is the outermost thing a gated eval suite runs" is replaced — it is outermost against test-level traits, not against a suite trait written before it.
    - `GatedEvalSerialGate`'s "Why the permit is taken at suite scope" section, which carried the same sentence and was not in the round's list.
    - `MetalLibraryTestBootstrap.ensureColocatedMetallib`, which now tells a future author where a GPU-touching suite trait belongs.

    `grep` for "whatever order", "regardless of written order", "regardless of the order" and "outermost thing" over Sources, Tests and the Markdown returns nothing.
  timestamp: 2026-08-10T22:02:59.969023+00:00
- actor: claude-code
  id: 01kzpv6zws6swbf75kn352pspf
  text: |-
    ### implement — changed
    - evidence: 4 files — `Tests/FoundationModelsRouterIntegrationTests/MetalLibraryBootstrapIntegrationTests.swift` (named constants `metalLibraryProbeFirstOperand` / `metalLibraryProbeLastOperand`, array built from the run), `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift`, `Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift` (both the enum doc and `GatedEvalResidencyTrait.provideScope`), `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift` — the last three carry the corrected trait-ordering rule.
    - verified: `swift build --build-tests` complete, no Swift error or warning; ungated `swift test` green — 783 tests / 75 suites (the 1 pre-existing BoundedWait known issue), 25 tests / 10 suites, 24 tests / 5 suites; `Scripts/check-doc-links.py` 1295 links scanned, 0 stale, 0 unresolved; `- Parameter` keys checked by hand and unchanged (internal names `test`, `testCase`, `function`, `runner`); swiftlint `no_magic_numbers` with the rule's own `allowed_numbers: [0, 1, -1, 100]` reports nothing on the edited file.
    - probe re-verified after the rename: symlink deleted first, then `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter 'MetalLibraryBootstrapIntegrationTests'` -> 1 test in 1 suite passed after 0.597s (test body 0.036s), and the symlink was reinstalled pointing at `Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`. The probe still forces a GPU-device `MLXArray` evaluation.
    - not run, and not claimed: full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` and any `MULTITOOL_INTEGRATION=1` run (27B model, 8-11 min). AC #4 and the Tests line stay unticked as not-run.
    - next: /review
  timestamp: 2026-08-10T22:03:11.641959+00:00
- actor: claude-code
  id: 01kzpx81nr88ewxymt5gg4nx0c
  text: |-
    ### review — clean
    - scope: `review sha HEAD~1..HEAD` (080a401), 4 source files.
    - engine counts: 0 findings, 0 confirmed, 0 refuted, 9 attempted, 0 failed, 0 skipped. Round 1's single finding (`MetalLibraryBootstrapIntegrationTests.swift:29`) stays checked; no new finding replaces it.

    Four targeted confirmations, all VERIFIED.

    1. Operands unchanged. `metalLibraryProbeFirstOperand: Int32 = 1` and `metalLibraryProbeLastOperand: Int32 = 4` build `Array(1...4)` = `[1, 2, 3, 4]` — the same four values in the same order. The commit touches only the constant declarations and their doc comments; the `@Suite` line and the test body are not in the diff.

    2. The probe still forces a GPU-device evaluation — the risk that mattered. `MLXArray(metalLibraryProbeOperands).sum(stream: .gpu)` selects the GPU stream, so the Metal kernel and therefore the metallib load stay necessary. `total.item(Int32.self)` materializes the lazy array, and its result is an operand of `#expect`, so the compiler cannot remove it. Nothing moved to `.cpu` and no materialization was dropped. Empirical: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter 'MetalLibraryBootstrapIntegrationTests'` exits 0 — 1 test in 1 suite passed after 0.081s, test body 0.077s, Testing library 2074. The symlink beside the integration test binary points at `Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`. The negative control (delete the symlink, watch the abort) was not repeated this round; it stands on the round-1 record.

    3. The documented ordering rule is correct, measured a second time and independently. swift-testing's implementation source is NOT on this machine — the toolchain ships `Testing.framework` with `.swiftinterface` files only, which carry public declarations and no bodies, and `Runner._runStep` / `_applyScopingTraits` are internal. `Runner.swift` is absent from `.build/checkouts`, `~/.swiftpm`, the SwiftPM repository cache, and every toolchain directory. So this round did not quote the source; it re-measured on the same toolchain and the same Testing 2074 with a probe package built OUTSIDE the repository, using two suite-scoped markers `S1`,`S2` written in that order and two test-scoped markers `T1`,`T2`:

        PROBE enter S1 / PROBE enter S2 / Suite started / PROBE enter T1 / PROBE enter T2 / body
        / PROBE exit T2 / PROBE exit T1 / PROBE exit S2 / PROBE exit S1

        Both halves hold. Suite scopes open before the suite step and close after it, and `S2` — the LAST suite trait written — still encloses `T1` and `T2`, so position among the suite's own traits does not change the suite/test relation. Within one declaration `S1` encloses `S2` and `T1` encloses `T2`, so the first written is the outermost. This reproduces the implementer's throwaway-probe result on a separate probe package.

        All four doc sites state exactly that and overstate nothing: `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift:51-53` and `:60-64`; `Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift:45-50` (type doc) and `:120-128` (`provideScope`); `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift:55-61`. The `provideScope` clause "this trait is outermost against test-level traits, not against a suite trait written before it" is exactly the limit the probe shows. No reversal at any site.

    4. No scratch file survived. `080a401` adds no probe file. `git log --all --diff-filter=A` finds no `ZZTraitOrderProbe` or `TraitOrder` file ever added in history. The only `*probe*` files in the tree are the long-standing `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift` and `Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift`. `git status` shows no untracked source file — only kanban cards. Remaining: 7 gitignored build products under `.build/` (`ZZTraitOrderProbe.o-*`, `.swiftdeps`) and stale symbols in `.code-context/index.db`; `.gitignore:13` covers `.build/`, so they cannot be committed and the ungated target builds without them.

    5. Nothing from `46a56ae` regressed. All 9 gated suites still carry `.exclusiveRealModel`: IntegrationTests.swift:210, SessionTreeRestorationIntegrationTests.swift:71, CompactionSpikeIntegrationTests.swift:55, LanguageModelSessionBackendTests.swift:52, TranscriptReconstructionIntegrationTests.swift:48, CompactionRoundTripIntegrationTests.swift:71, RecordingHandleIntegrationTests.swift:67, PropagationProbeIntegrationTests.swift:112, MetalLibraryBootstrapIntegrationTests.swift:73. The tenth suite, CompactionRoundTripIntegrationTests.swift:507, is ungated by name and carries no `.enabled(if:)`. Both eval suites keep `.exclusiveResidentModel(of:)` (CompactionEvaluationTests.swift:417, CompactionContinuityEvaluationTests.swift:245). The permit is taken in exactly two places, both inside `provideScope` — GatedSuiteSerialGate.swift:99 and GatedEvalSerialGate.swift:145; the only other `withPermit` calls are AsyncSemaphoreTests.swift:50,77,138,146 on locally created semaphores. `ensureColocatedMetallib` is read only from GatedSuiteSerialGate.swift:98 and GatedEvalSerialGate.swift:144. Evict-before-release is intact: GatedEvalSerialGate.swift:153 `await runner.evictIfLoaded()` runs after the success and failure paths converge into `outcome` and before the rethrow at :154, with the permit released only when the closure returns at :155 — no error path can skip the eviction.

    Not run, per instruction and unchanged: full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` and any `MULTITOOL_INTEGRATION=1` run. AC #4 and the Tests line stay unticked as not-run, which is an environment limit rather than a finding.

    - next: none — task moved to done.
  timestamp: 2026-08-10T22:38:43.384818+00:00
- actor: claude-code
  id: 01kzpxb0t1kn1f0cc9envyzynq
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files; named probe operands (metalLibraryProbeFirstOperand/LastOperand), corrected the overstated trait-ordering doc claim in 4 sites
    - test: green — ungated swift test 783/75 + 25/10 + 24/5; check-doc-links.py 1295 links, 0 stale / 0 unresolved; filtered gated probe passes with symlink deleted first
    - commit: 080a401
    - review: clean — 0 findings, 9 validators attempted; card moved to done
    - AC#1 DEMONSTRATED both directions (round 1): with the symlink deleted, the deliberately forgetful gated test passed and reinstalled it; with .exclusiveRealModel temporarily removed, the same run aborted with "MLX error: Failed to load the default metallib ... array.cpp:232". No 27B model needed — mlx aborts on any GPU-device MLXArray evaluation.
    - ordering rule re-measured independently by the reviewer on Testing 2074 (swift-testing implementation sources are NOT on this machine; the toolchain ships .swiftinterface only): a probe package built outside the repo produced enter S1 -> enter S2 -> enter T1 -> enter T2 -> body -> exit T2 -> exit T1 -> exit S2 -> exit S1. Both halves of the documented rule hold.
    - coverage: all 9 gated suites carry .exclusiveRealModel; the 10th (CompactionRoundTripIntegrationTests.swift:507) is ungated and MLX-free. Permit taken only at GatedSuiteSerialGate.swift:99 and GatedEvalSerialGate.swift:145.
    - AC#4 + Tests line NOT SATISFIED (environment limit, not a defect): full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` was NOT RUN. Left unticked deliberately.
  timestamp: 2026-08-10T22:40:20.801919+00:00
position_column: done
position_ordinal: ff8480
title: Make the metallib bootstrap trigger structural, not per-test discipline
---
Follow-up to `^ce4hb6n`, which ported `MetalLibraryTestBootstrap` and wired it in. The wiring works today — audited, all 22 gated live tests reach `ensureColocatedMetallib` before any model resolution — but it rests on convention, and the failure mode when convention breaks is severe.

The bootstrap installs a symlink beside the running test binary and must run before the first GPU-device `MLXArray` evaluation, otherwise mlx aborts THE WHOLE TEST PROCESS with "Failed to load the default metallib". It is triggered from exactly three chokepoints:
- `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` — inside `shared`'s initializer
- `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift` — in `container()`
- `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift` — in `container()`

For the integration target that means all 20 gated `@Test` bodies must each remember to touch `GatedSuiteSerialGate.shared` as their first statement. All 20 currently do (19 via `withPermit`, `IntegrationTests.endToEnd` via `wait()`/`defer signal()`). Nothing enforces it. A new gated `@Test` written without that line does not fail an assertion — it crashes the entire test process on first GPU evaluation, taking every other suite's results with it, with an error message that points at mlx rather than at the missing line.

The same latent gap exists in Evals: a third live entry point that does not route through a bootstrap-touching `container()` would crash that process the same way.

Suggested direction (not prescriptive): a suite-level `TestScoping` trait applied to each gated `@Suite` that touches the bootstrap and takes the permit, making both concerns structural and removing the per-test requirement entirely. Note the constraint the port already discovered — `.evaluates(...)` is itself a `TestScoping` trait that runs inference ahead of the `@Test` body, which is exactly why the Evals target triggers from `container()` rather than a test body; any trait-based design must order correctly against it.

## Acceptance Criteria
- [x] A newly added gated `@Test` that forgets the per-test gate line cannot crash the process on metallib — demonstrated, not asserted
- [x] Ordering against `.evaluates(...)`'s own `TestScoping` behavior is handled and documented
- [x] The three existing chokepoints are reduced to whatever the new mechanism needs, with no duplicate trigger left behind
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` still shows zero metallib errors in both gated targets — NOT RUN in this environment (full gated suites load the 27B model, 8-11 min); the isolated filtered gated run is recorded in the comments
- [x] Ungated `swift test` stays green

## Tests
- [ ] Gated run confirming both targets still bootstrap. Gated runs: one at a time, one shell command per run. — NOT RUN (see above)

## Review Findings (2026-08-10 16:29)

- [x] `Tests/FoundationModelsRouterIntegrationTests/MetalLibraryBootstrapIntegrationTests.swift:29` — Magic numbers should be replaced by named constants. #phase-1
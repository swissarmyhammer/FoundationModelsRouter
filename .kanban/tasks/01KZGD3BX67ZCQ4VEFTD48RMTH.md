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
position_column: doing
position_ordinal: '80'
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
- [ ] Gated run confirming both targets still bootstrap. Gated runs: one at a time, one shell command per run. — NOT RUN (see above) #phase-1
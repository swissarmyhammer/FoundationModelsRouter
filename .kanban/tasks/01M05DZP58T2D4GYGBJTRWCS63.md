---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m05e51mcrfcq1h0h2ee0hk1s
  text: |-
    ### Open question answered — the six suites are defective

    The `FoundationModelsMultitool` session settled this from the consumer side.

    Their probe never constructs a handle. It uses the production path only: `router.resolve(profile:reporting:)`, then `profile.standard` and `profile.flash`. Nothing in their target mints a `RoutedLLM` or passes a gate. Every handle they touch comes from the resolver, over one `PoolEntry` — and that path deadlocks, measured at `permits=0 waiters=1`.

    So the two constructions are not equivalent, and the difference is the one that matters. Resolver-built handles share the entry's single semaphore and contend. Hand-built handles get one semaphore each and cannot.

    This is a second reason the defect stayed hidden. Even if some test had generated from inside a tool call, six of those suites could not have deadlocked, because their handles never shared a gate.

    ### A larger finding: the configuration is consumer-reachable

    The peer described the hand-built shape as "a configuration no consumer can obtain". That is not correct, and the truth is worse.

    - `LanguageModelProfile.init(...)` is `public`, and it takes `generationGate: AsyncSemaphore? = nil` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:178`, `:188`).
    - `AsyncSemaphore` is `public`, and `init(value:)` is `public` (`Concurrency/AsyncSemaphore.swift:32`, `:47`).
    - With `nil`, the initializer mints a fresh gate (`LanguageModelProfile.swift:199`).

    The documentation says the fresh gate matches "the pre-pooling behavior for a handle constructed directly (e.g. in tests)" (`:136-137`). Nothing enforces "in tests". A consumer can build two handles over one resident container and get two gates.

    That inverts the gate's purpose: two gates over one container permit two concurrent generations, which is the exact condition the gate exists to prevent. Decide whether this initializer should stay public in this form.

    ### Suggested shape for the test

    - Resolve a profile. Do not build handles. The test must exercise the object graph a consumer gets.
    - Keep a hand-built variant as the control. It must **not** deadlock, and that asymmetry is worth asserting on its own.
  timestamp: 2026-08-16T14:03:32.876142+00:00
- actor: claude-code
  id: 01m05e7dtcmjwm6e4e7a96k4fk
  text: |-
    ### Wording for the control assertion

    Use this note beside the hand-built control, or the test will make the hazard look sanctioned:

    > The control demonstrates that two gates over one container permit concurrent generation, which is the condition the gate exists to prevent. It passes today, and it must stop passing when the initializer is fixed.

    The point is that "hand-built handles do not contend" is not a property to keep. It is the second defect. An assertion that records it without that note bakes the hazard into the suite.

    ### Consumer exposure, for scale

    The `FoundationModelsMultitool` session checked their own code:

    ```
    grep -rn "LanguageModelProfile(|RoutedLLM(|AsyncSemaphore(" Sources Tests   ->  no matches
    ```

    They construct no profile, no handle, and no semaphore. Every handle comes from `router.resolve(profile:reporting:)`. So they cannot reach the two-gates hazard.

    They ask that this is not recorded as care. They only ever needed a resolved profile. Nobody considered the alternative. Any consumer that reaches for the public initializer to avoid resolution — a test double, a fixed pin, or a warm handle held across resolutions — lands on the reverse defect with no warning.

    That is the argument for making "e.g. in tests" a constraint instead of guidance.
  timestamp: 2026-08-16T14:04:50.892316+00:00
depends_on:
- 01M05DYCWJPBSXEY8681ZT7VYG
position_column: todo
position_ordinal: '8380'
title: No test drives generation from inside a tool call, or exercises gate contention
---
Two shapes have no coverage in any target. This is why the nested-generation deadlock reached a consumer.

## Gap 1 — no test generates from inside a tool call

Every `func call(arguments:` body in all four test targets was scanned for `.respond(to:`, `.fork(`, `makeSession`, and `makeGuidedSession`. There are no hits. The real-model tool test's body is a table lookup (`Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift:112-114`).

`mlx-swift-lm` has the matching test at their layer — `Tests/MLXFoundationModelsTests/ToolBodyContainerReentryTests.swift`, "A tool body may generate on the same model while its turn is in flight". We have no equivalent.

## Gap 2 — no gated test exercises gate contention

The closest tests, and why each one misses:

- `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:460` — two root sessions over one model, B generating from inside A's mid-turn hook. This is the shape, but A wraps its wait in `awaitingUser`, which frees the permit. Remove that wrapper and it should hang. Stub backend.
- `Tests/FoundationModelsRouterTests/ForkConcurrencyTests.swift:407` — root plus three forks over one model, asserting `maxActive == 1`. It proves the gate serializes, but all four callers are independent top-level tasks. None is nested inside another's turn, so there is no circular wait. Stub backend.
- `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:399` — two profiles over one pooled entry, concurrent and not nested. Stub backend.

In the gated targets there is no gate-contention coverage at all. Every gated suite is `.serialized` with `.exclusiveRealModel`, one turn at a time.

`Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift:214` is the only gated test that resolves two real generation slots, and because `RealModels.standard == RealModels.flash` it pools to one entry with one shared gate. That is exactly the consumer's configuration, and it never nests or overlaps anything.

Six other gated suites construct `standard` and `flash` handles over one container but pass no `generationGate:`, so `LanguageModelProfile.init` mints a fresh semaphore for each (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:199`). Those handles hold **separate** gates, so they would not show contention even if they tried. Check whether that is correct or is itself a defect.

## Acceptance Criteria

- [ ] A test drives generation from inside a tool call, for a session over the same resident container
- [ ] A test covers the same-session case and asserts it fails cleanly
- [ ] A test exercises gate contention with two sessions over one shared pool entry
- [ ] Recorded whether the six gated suites that mint separate gates for one shared container are correct or defective
- [ ] The tests use the real `PoolEntry` gate, not a fresh semaphore that hides contention #Coverage-Gap #nested-generation
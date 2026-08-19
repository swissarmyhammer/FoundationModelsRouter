---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqpn57jj2zmc3qb2abjmr
  text: |-
    ## Audit at `dd55fcd2c` — LIVE, and not a duplicate of `^hxyj3q1`

    This card is the CONTAINER LOAD. `^hxyj3q1` is the PROFILE BUILD. They are different work.

    `RealModelContainer.load` (`Tests/FoundationModelsRouterIntegrationTests/Support/RealModelContainer.swift:33`) has 12 callers, all of them in the integration target. The two eval runners were not converted. Each still builds its own `LiveModelLoader` and casts:

    - `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift:141-164`
    - `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift:47-73`

    ## Do this card and `^hxyj3q1` in one session

    Both cards touch the same continuity runner, and both answer the same cross-target question. One session for the two of them.
  timestamp: 2026-08-18T23:19:05.125469+00:00
- actor: claude-code
  id: 01m0bvds7d5phd8zjd99fza7y6
  text: |-
    ## The cross-target question is now MEASURED, not assumed

    The card says the shared helper "cannot move to `FoundationModelsRouterTestSupport` because `MLXFoundationModelsContainer` is internal to `FoundationModelsRouter` and that plain `.target` links neither the Hub macros nor `@testable import`". Half of that reason is wrong and the other half is decisive. Both halves were measured rather than read.

    ### What DOES work

    `FoundationModelsRouterTestSupport` can link the Hub macros. Adding `mlxProducts + hubProducts` to its dependency list and putting a probe there that uses `#hubDownloader()`, `#huggingFaceTokenizerLoader()`, `LiveModelLoader` and `@testable import FoundationModelsRouter` builds clean under `swift build --build-tests`. A `public` function can even return the internal `MLXFoundationModelsContainer` there — `@testable` admits it in a public signature.

    ### What does NOT work, and why the card's answer stands

    `swift build -c release` compiles `FoundationModelsRouterTestSupport`, and a release build of `FoundationModelsRouter` carries no testability:

    ```
    error: Tests/FoundationModelsRouterTestSupport/SpikeProbe.swift:8:18 unable to resolve
    Swift module dependency to a compatible module: 'FoundationModelsRouter'
    error: Build failed
    ```

    Baseline `swift build -c release` at HEAD is green, so this is the change's own breakage.

    Declaring `FoundationModelsRouterTestSupport` a `.testTarget` does NOT rescue it. SwiftPM permits a `.testTarget` to depend on another `.testTarget`, and `swift build --build-tests` is clean — but `swift build -c release` STILL compiles it, with a fresh plan, and fails identically. Meanwhile `FoundationModelsRouterIntegrationTests`, which is full of `@testable import`, is NOT compiled in release.

    The empirical rule: a target that other test targets depend on is built in release, whatever kind it is declared, so it can never use `@testable import`. Only a LEAF test target can, and SwiftPM has no way to share source between two leaf test targets.

    ### The choice

    One shared loader in `Tests/FoundationModelsRouterEvals/Support/`, exactly as this card's acceptance criteria state. The integration target keeps `RealModelContainer`. Making `MLXFoundationModelsContainer` public to dissolve the boundary was rejected: widening production visibility to host a test helper is a worse trade than one loader per module.

    Package.swift was restored; the spike left nothing behind.
  timestamp: 2026-08-19T01:50:57.261729+00:00
- actor: claude-code
  id: 01m0by99yn585x2e7955hsxngh
  text: |-
    ## Done

    `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealModelContainer.swift` is the one shared loader, and both runners call it.

    ### How the three differences were kept

    - **The greedy pin survives**, on the continuity runner alone, as `samplingMode: .greedy`. Its whole reason — the 0.5/0.8/0.7 coin flip against a 0.8 threshold, task `f80n046` — is still written at the call site, and the parameter's own doc states it again for the next caller.
    - **The progress lines stopped being a difference.** `^aktsp2e` wanted them on the continuity runner too, so the shared loader emits them and BOTH tiers now time the model load apart from their samples. The load is still excluded from the first sample's time.
    - **Neither error case lost its thrower.** The loader takes the error to throw as a parameter, so `CompactionEvaluationError.unexpectedContainerType` and `CompactionContinuityEvaluationError.unexpectedContainerType` each still have exactly one call site. Collapsing them into one type was not needed and was not done.

    Caching stays per-runner, as the card says: each runner keeps its own `loaded` property.

    ### Acceptance criteria

    - [x] One shared loader in `Tests/FoundationModelsRouterEvals/Support/`, called by both runners.
    - [x] The greedy pin survives with its reason.
    - [x] The progress lines still come out, and still exclude the load from the first sample.
    - [x] Neither error case is left with no thrower.
    - [x] `swift build`, `swift build --build-tests -Xswiftc -warnings-as-errors` and `swift test` clean.

    `swift test`: 995 + 37 + 67 = 1099 tests pass, one expected pre-existing `withKnownIssue`.
    `FM_ROUTER_COMPACTION_SMOKE=1 swift test`: the same 1099 pass; the integration bundle goes from 0.005 s to 20.8 s, so the smoke suite really ran.
    `swift build --build-tests -Xswiftc -warnings-as-errors`: clean.
    `swift build -c release`: clean — checked because the spike had broken it.

    `review working`: 0 findings, after fixing the 5 it reported on earlier passes.
  timestamp: 2026-08-19T02:40:56.277805+00:00
- actor: claude-code
  id: 01m0byawkgse3xqzmyqhy1rwzn
  text: |-
    ### implement — changed
    - evidence: 13 files. New: `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealModelContainer.swift`, `Tests/FoundationModelsRouterEvals/Support/SequenceKeyedByFirst.swift`, `Tests/FoundationModelsRouterIntegrationTests/RealModelHarnessTests.swift`. Modified: `CompactionEvalProgressLog.swift`, `CompactionEvalSeed.swift`, `CompactionContinuityDataset.swift`, `CompactionEvaluationTests.swift`, `CompactionContinuityEvaluationTests.swift`, `Support/CompactionEvalRealSubjectRunner.swift`, `Support/CompactionContinuityEvalRealSubjectRunner.swift`, `CompactionRoundTripIntegrationTests.swift`, `SessionTreeRestorationIntegrationTests.swift`, `Support/RealModelHarness.swift`. No `Sources/` file changed. `swift test` 1099 pass; `FM_ROUTER_COMPACTION_SMOKE=1 swift test` 1099 pass; `review working` 0 findings.
    - next: `/review`. This card and `^aktsp2e` are complete; `^hxyj3q1` has one acceptance criterion open — the gated run — which this session was instructed not to make.
  timestamp: 2026-08-19T02:41:48.144120+00:00
position_column: doing
position_ordinal: '8380'
title: The two eval real-subject runners each carry their own copy of the real-model container load
---
`Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift` and `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift` each hold a private `container()` that runs the same three-step body: build a `LiveModelLoader` over `#hubDownloader()` and `#huggingFaceTokenizerLoader()`, call `loadLLM(ref:slot:context:reporting:)` for `CompactionEvalRealModel` at `.standard`, then cast the result to `MLXFoundationModelsContainer`.

This is the same clone family the `reuse/reuse` finding on `^w1cz46m` reported. That card collapsed the NINE copies inside `FoundationModelsRouterIntegrationTests` onto one shared helper, `RealModelContainer.load(ref:context:samplingMode:)`, in that target's `Support/` directory. It could not reach these two, for two reasons stated on that card: `FoundationModelsRouterEvals` is a separate test target and a separate module, and the shared helper cannot move to `FoundationModelsRouterTestSupport` because `MLXFoundationModelsContainer` is internal to `FoundationModelsRouter` and that plain `.target` links neither the Hub macros nor `@testable import`.

## What differs between the two copies

Merging must keep all three, so each becomes a parameter or stays at the call site:

- `CompactionContinuityEvalRealSubjectRunner` pins `samplingMode: .greedy`; `CompactionEvalRealSubjectRunner` takes the provider default.
- `CompactionEvalRealSubjectRunner` emits a model-load started line and a model-load returned line with its own elapsed seconds, around the load. The other emits nothing.
- Each maps a failed cast to its OWN domain error — `CompactionEvaluationError.unexpectedContainerType` and `CompactionContinuityEvaluationError.unexpectedContainerType`. Do not collapse two error types into one without checking what reads them; an error case left with no thrower becomes dead code.

Both also cache the loaded container in a stored property, which is per-runner state and stays with the runner.

## Acceptance Criteria

- [ ] One shared loader in `Tests/FoundationModelsRouterEvals/Support/`, called by both runners.
- [ ] The greedy pin on the continuity runner survives, with the reason it carries today (task `f80n046`) still written down.
- [ ] The progress lines around the load still come out for `CompactionEvalRealSubjectRunner`, and still exclude the load from the first sample's time.
- [ ] Neither error case is left with no thrower.
- [ ] `swift build`, `swift build --build-tests -Xswiftc -warnings-as-errors` and `swift test` are clean: zero failures, zero warnings, one expected pre-existing `withKnownIssue`.

## Constraints

- Never run `swift format` or `swiftformat` in this repository.
- Do not run `FM_ROUTER_INTEGRATION_TESTS=1` or `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET`.
- Do not weaken any assertion. This is an extraction.

#compaction #eval #real-model
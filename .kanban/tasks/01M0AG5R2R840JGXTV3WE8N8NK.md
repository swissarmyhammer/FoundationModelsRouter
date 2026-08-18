---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
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
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37jrwrjm65kvymwx50ebpxb
  text: |-
    ### Research and design choices

    - Check result: `mlx-swift-lm` (`Libraries/MLXFoundationModels/MLXLanguageModel.swift:843`) does not need a number. When `maximumResponseTokens` is `nil`, the executor applies its own `private static let defaultMaxTokens = 4096` (lines 1777, 2126, 2311, 2404, 2512). This limit is in the dependency, not in this package.
    - Choice 1: `makeGenerationOptions(maxTokens:)` passes `maxTokens` through as `maximumResponseTokens`. `nil` stays `nil`. The backend adds no number and no constant.
    - Choice 2: the backend does not learn the window. A routed session already gives every call `contextTokens` (the window, after ^24hrxdj) through `RoutedSessionActor.responseTokenCeiling(requested:contextTokens:)`. Only a direct backend call with `nil`, or a session whose context is not positive, sends `nil`.
    - Choice 3: `appliedCeiling`, its log line and the `SessionBackend` logger are deleted; nothing else used the logger. `import os` in LiveModelLoader.swift is deleted with it.
    - Choice 4: `CeilingProbeLanguageModel.spentCeiling(_:scriptedTokenCount:)` gives the scripted length when the ceiling is `nil`. The scripted lengths are sums of `emittedTokenCount` (`truncatedAnswerScriptedTokenCount`, `toolCallScriptedTokenCount`), in the test helper only.
    - Choice 5: `Core/ProfileDefinition.swift` no longer names the floor (^24hrxdj removed those lines). `floorIsNotDefaultContext` is already gone.
    - New work: the 4096 default of the engine is an invented limit in the dependency. A separate card records it for the owner.
  timestamp: 2026-09-23T16:49:51.890697+00:00
- actor: claude-code
  id: 01m37js4yh30ha1d2q015jb5dk
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/ResponseTokenCeiling.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift, Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift, Examples/MultiModelGeneration/main.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift. `rg 'responseTokenFloor|appliedCeiling'` finds nothing. `swift test`: 1326 tests in 149 suites passed (2 known issues, expected), 1 test in 1 suite passed, 19 tests in 3 suites passed. `swift build --build-tests --package-path IntegrationTests`: exit 0.
    - next: commit, then review.
  timestamp: 2026-09-23T16:50:00.273839+00:00
- actor: claude-code
  id: 01m37jxhyty9kpcnp9xg95shzz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 53586c8 — 0 findings, 0 confirmed, 0 refuted; 7 files reviewed.
    - next: done.

    ### finish iteration 1 — done
    - commits: 53586c8 refactor(session): delete responseTokenFloor; a call with no ceiling sends none
    - `swift test`: Test run with 1326 tests in 149 suites passed (2 known issues, expected); Test run with 1 test in 1 suite passed; Test run with 19 tests in 3 suites passed.
    - `swift build --build-tests --package-path IntegrationTests`: exit 0.
    - New card for the owner: the 4096 `defaultMaxTokens` of the mlx-swift-lm executor.
  timestamp: 2026-09-23T16:52:24.666842+00:00
depends_on:
- 01M34PH8G88KM01QGSS24HRXDJ
position_column: done
position_ordinal: fffff780
title: Remove responseTokenFloor; a call with no ceiling decodes to the model's window
---
## Decision (from the owner, 2026-09-22)

`MLXFoundationModelsSessionBackend.responseTokenFloor` (`Resolution/LiveModelLoader.swift:197`, 8,000 since 15ec721, 8,192 before) is an invented limit and must go. A call whose caller names no ceiling decodes under the model's window and nothing else.

## Why

The floor's doc says it exists "so that the MLX executor still gets a finite budget" when a caller gives `maxTokens: nil` and the session has no context. A routed session always has a resolved context (`RoutedSessionActor.responseTokenCeiling(requested:contextTokens:)` gives `contextTokens` when the caller names none), and with ^24hrxdj that context is the model's window. The window is the finite budget.

## Sites

- `Resolution/LiveModelLoader.swift:197`: the constant.
- `LiveModelLoader.swift:208-231`: `makeGenerationOptions(maxTokens:)` and `appliedCeiling(maxTokens:)` with its log line (both added or changed in 15ec721). `makeGenerationOptions` passes `maxTokens` through as `maximumResponseTokens`; `nil` stays `nil`. Delete `appliedCeiling` and the `SessionBackend` logger if nothing else uses it.
- `Core/ProfileDefinition.swift:22-25`: a doc comment that names the floor. Delete those lines (the whole constant goes in ^24hrxdj).
- `Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift:124`: asserts the floor is the requested ceiling when the caller names none. Change it: with no ceiling, the backend requests `nil`. `:128` `floorIsNotDefaultContext`: delete.
- `Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift:204-207, 323, 348`: `spentCeiling` maps `nil` to the floor. With no floor, a `nil` ceiling means the probe model decodes to its own scripted end; make `spentCeiling` take the scripted length in that case, and update the three doc comments.
- `IntegrationTests/.../IntegrationTests.swift:227, 383` and `Examples/MultiModelGeneration/main.swift:35`: comments that name the floor. Rewrite: an uncapped call runs to the model's window.

## Check first

What `mlx-swift-lm` does with `maximumResponseTokens == nil`. If the executor needs a number, the backend passes the session's resolved context (the window), which the actor already gives on every routed call. Do not add a constant. Record what you find on this card.

## Acceptance

- `rg 'responseTokenFloor|appliedCeiling'` finds nothing.
- A backend call with `maxTokens: nil` requests `nil` (or the window, per the check above) from the engine. A test asserts it.
- All tests pass.

## Order

After ^24hrxdj, which deletes `ProfileDefinition.defaultContext` and the test that compares the two. #compaction #limits
---
assignees:
- claude-code
depends_on:
- 01M34PH8G88KM01QGSS24HRXDJ
position_column: todo
position_ordinal: '8880'
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
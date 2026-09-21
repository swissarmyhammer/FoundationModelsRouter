---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Move ScriptedToolCallingContainer and CeilingProbeContainer onto LiveBackendContainer
---
## What is wrong

Three test containers hold the same four factory methods that vend `MLXFoundationModelsSessionBackend` over a scripted `LanguageModel`:

- `ScriptedToolCallingContainer` in `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift`
- `CeilingProbeContainer` in `Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift`
- `LiveBackendContainer<Model>` in `Tests/FoundationModelsRouterTests/Helpers/LiveBackendContainer.swift` (added by task ^naqfcqj)

`LiveBackendContainer` is generic over the model. The two older containers are copies of it.

## What must change

- Make `CeilingProbeContainer` a use of `LiveBackendContainer<CeilingProbeLanguageModel>` and delete the copy.
- Make `ScriptedToolCallingContainer` use `LiveBackendContainer` for the four factory methods. It also records each vended backend in `VendedBackendLog`, so either add an optional vend hook to `LiveBackendContainer` or keep a thin wrapper that records and then calls it.
- Keep every call site compiling (`SessionProjectionSeedingTests`, `RestoreFidelityTests`, `ScriptedSessionFixture`, `CeilingProbeSessionFixture`).

## Acceptance

- `swift test` at the package root passes with zero failures and zero new warnings.
- Only one type in the test target builds `MLXFoundationModelsSessionBackend` from a `LanguageModelSession`.
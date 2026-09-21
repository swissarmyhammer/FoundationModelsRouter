---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m32ms4z9j3p2k4srkzh5r28j
  text: |-
    Research done.
    - `CeilingProbeContainer` has two users: `TurnTokenCeilingTests.liveBackendFallsBackToFloor` and `CeilingProbeSessionFixture.make`. Both only call `init(model:)` and `makeSession`. Plan: use `LiveBackendContainer(model:)` at the two sites and delete the type.
    - `ScriptedToolCallingContainer` users: `SessionProjectionSeedingTests`, `RestoreFidelityTests`, `ScriptedSessionFixture`. They use `init(model:)` and `vendedBackends`. The type also exposes `languageModel`. Plan: keep a thin wrapper that holds a `LiveBackendContainer<ScriptedToolCallingModel>`, forwards each factory to it, and records the result in `VendedBackendLog`. The card names this option. `LiveBackendContainer` stays unchanged.
    - The validator rules file for Swift is very large (754K characters). I read the duplication, reuse and swift sections. The swift duplication rule does not flag forwarding one-liners.
  timestamp: 2026-09-21T18:48:45.289139+00:00
- actor: claude-code
  id: 01m32mvfvt2x62aktbzzrz25mj
  text: |-
    Implementation done.
    - Deleted `CeilingProbeContainer`. `CeilingProbeSessionFixture.make` and `TurnTokenCeilingTests.liveBackendFallsBackToFloor` now use `LiveBackendContainer(model:)`.
    - `ScriptedToolCallingContainer` is now a thin wrapper. It holds a private `LiveBackendContainer<ScriptedToolCallingModel>`. Each `tools:` factory calls it and records the result in `VendedBackendLog`. The wrapper's `model` property had no reader outside the wrapper, so `languageModel` now reads `live.model` and the property is gone. `init(model:)`, `vendedBackends` and `languageModel` do not change, so all call sites compile with no edit.
    - `LiveBackendContainer` did not change. I did not add a vend hook. The thin wrapper is the other option that the card names.
    - Check: a search for `MLXFoundationModelsSessionBackend(` in Tests/ finds only `LiveBackendContainer.swift`.
    - TDD note: this is a refactor of test helpers only. There is no new behavior. The existing suites (RestoreFidelityTests, SessionProjectionSeedingTests, ScriptedSessionFixture users, TurnTokenCeilingTests, CeilingProbeSessionFixture users) are the guard. They all pass.
    - `swift test` shows one line "warning: missing creator for mutated node" for the mlx-swift_Cmlx.bundle. This is a SwiftPM build-graph warning about a dependency bundle and not a compiler warning from the changed files.
  timestamp: 2026-09-21T18:50:01.978913+00:00
- actor: claude-code
  id: 01m32mvjjhsqad9tjzdebja2yn
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift, Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift. `swift test`: exit 0. Swift Testing ran 1345 tests in 144 suites, 1 test in 1 suite, and 83 tests in 10 suites. All passed, 0 failures, 2 known issues that were there before. The build-system warning line is for the mlx-swift bundle and not for these files.
    - next: /review
  timestamp: 2026-09-21T18:50:04.753527+00:00
- actor: claude-code
  id: 01m32njvgypt6v9fg5bg6bt4sv
  text: |-
    ### test — green
    - evidence: `swift test` (full suite, 3 targets) — 1345 tests / 144 suites passed (2 known issues, pre-existing, unrelated to this change), 1 test / 1 suite passed, 83 tests / 10 suites passed. 0 failures, 0 skips. `swift build --build-tests` clean rebuild of the 3 touched files — 0 compiler warnings (only a pre-existing, unrelated SwiftPM planning warning about the third-party mlx-swift_Cmlx bundle).
    - swiftformat: ran with `--pattern-let inline --short-optionals always --single-line-for-each convert --guard-like-if-statements convert` restricted to the exact new-file line ranges this change touched (371-373, 403 in CeilingProbeLanguageModel.swift; 236-239, 241-250, 264, 289, 311 in ScriptedToolCallingModel.swift; 119 in TurnTokenCeilingTests.swift), not the whole file. One finding: the `wrapPropertyBodies` rule (a SwiftFormat default rule) flagged the touched `languageModel` property in ScriptedToolCallingModel.swift. Fixed by wrapping it onto multiple lines. No other touched line needed a change.
    - next: ready for review.
  timestamp: 2026-09-21T19:02:47.582189+00:00
- actor: claude-code
  id: 01m32nry45g3dfby237g51btq4
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 83e2670). 0 findings, 0 confirmed, 0 refuted. The engine reviewed 3 files. It did not review 4 files in .kanban/ because .reviewignore excludes them.
    - next: None. The task is in the done column.
  timestamp: 2026-09-21T19:06:06.853246+00:00
- actor: claude-code
  id: 01m32ns57xd93kwyefp6md8765
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1345 passed, 0 failures
    - commit: 83e2670
    - review: clean — task moved to done
  timestamp: 2026-09-21T19:06:14.141182+00:00
position_column: done
position_ordinal: ffffda80
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
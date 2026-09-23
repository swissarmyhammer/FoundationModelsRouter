---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37hdb0wd3r6w700e50tqzbr
  text: |-
    Design choices (made without a question, as the order says):

    1. `ProfileDefinition.defaultContext` is deleted. `init(context:)` defaults to `nil`, so the model's window is the default. `SlotResolution.init(contextTokens:)` and both `RoutedSessionActor` inits now require `contextTokens`.
    2. The two failure paths with no window (the standard slot names no candidate, or each native max context lookup fails) now throw a new error, `NoWindowFailure` (in `Resolution/SlotResolution.swift`). It names the profile and the standard-slot reports, and it sizes no slot, because there is no context to size at. I did not make `SlotResolution.contextTokens` optional: every success path reads it as `Int` (public `RoutedModel.contextTokens`, the router load loop), and an optional there would push a force-unwrap into each reader. `lastTriedContext` is `Int?`; `nil` gives `NoWindowFailure`. The failure tail moved into `windowFailure(...)` to keep `resolveAtLargestWindow` short.
    3. `Router.runJointFit` catches `NoWindowFailure` too. `recordFailure` now takes the slot outcomes, the failed reason and the description, so both errors share one writer. The standard slot shows "no candidate window could be read".
    4. The one test number is `ScriptedSessionContext.tokens` (8192) in `Tests/FoundationModelsRouterTestSupport/ScriptedSessionContext.swift`, not in `Tests/FoundationModelsRouterTests/Helpers/`: the unit suite and `IntegrationTests` both link the TestSupport module, and SwiftPM cannot share source between test targets. The stub `config.json` payloads that tests resolve without a context now state `max_position_embeddings` as that constant, so a derived window equals the stated one.
    5. Deleted tests: `TurnTokenCeilingTests.floorIsNotDefaultContext` (as the card says) and `RealModelHarnessTests.statingTheProfileDefaultMatchesOmittingIt` (it compared with the deleted `SlotResolution` default and cannot compile). `CoreTypesTests` now expects `context == nil`. New `JointFitTests`: a profile with no `context:` argument resolves at the model's window; no standard candidate gives `NoWindowFailure`; unreadable native windows give `NoWindowFailure` with each candidate's verdict.
    6. `responseTokenFloor` stays (card ^wn4zecb). Its doc no longer names `defaultContext`; it says the number is a response budget, not a window, and the log names it.
    7. Hand-built `RoutedSessionActor` sites in tests pass `standard.contextTokens`, the handle's own resolved window.
  timestamp: 2026-09-23T16:26:04.700039+00:00
- actor: claude-code
  id: 01m37hddazzk540rktnc2ve2v6
  text: |-
    ### implement — changed
    - evidence: `rg defaultContext Sources` finds nothing. `swift test`: "Test run with 1326 tests in 149 suites passed ... with 2 known issues", "Test run with 19 tests in 3 suites passed", "Test run with 1 test in 1 suite passed". `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - files: Sources Core/ProfileDefinition.swift, Resolution/JointFit.swift, Resolution/SlotResolution.swift, Resolution/LiveModelLoader.swift, Router.swift, Session/RoutedSessionActor.swift; Tests TestSupport/ScriptedSessionContext.swift (new) and the unit and integration sites.
    - next: commit, then review
  timestamp: 2026-09-23T16:26:07.071301+00:00
depends_on:
- 01M34PGWP0GS427JNWAAMKPZPW
position_column: doing
position_ordinal: '80'
title: Make the model's window the default context of a profile
---
## Decision (from the owner, 2026-09-22)

A profile that names no `context:` uses the model's own window. `ProfileDefinition.defaultContext` (8,192, `Core/ProfileDefinition.swift:26`) is an invented default and must go. An explicit `context:` stays as the override, for example to make a test compact early.

## Sites in `Sources`

- `Core/ProfileDefinition.swift:68`: `init(... context: Int? = ProfileDefinition.defaultContext)`. Make the default `nil`. `nil` means "derive from the model", which `JointFit` already does when `profile.context` is `nil` (`JointFit.swift:144`).
- `Resolution/SlotResolution.swift:112`: `init(... contextTokens: Int = ProfileDefinition.defaultContext)`. Make the parameter required. Every caller passes the resolved context.
- `Session/RoutedSessionActor.swift:195` and `:546`: `contextTokens: Int = ProfileDefinition.defaultContext`. Make the parameter required.
- `Resolution/JointFit.swift:514`: the path with no standard candidate calls `attemptTrio` at `defaultContext` to build a failure report. There is no model to derive from. Build the failure report without a context number: make the report's context optional, or use the failure path that names "no standard candidate" and skips the trio attempt.
- `Resolution/JointFit.swift:526`: `lastTriedContext = ProfileDefinition.defaultContext` is the fallback when no candidate's window could be read. Make it optional and report "no context" in that case.
- `Resolution/LiveModelLoader.swift:194`: a doc comment names the constant. Rewrite it.

## Sites in tests

About 20 sites in `Tests/` and `IntegrationTests/` state `ProfileDefinition.defaultContext` on purpose, so a scripted session has a small known window (for example `SessionEventStreamTests.swift:562` expects `contextFill == 15.0 / 8192.0`; `RouterTestFixtures.profile(context:)`; `CeilingProbeLanguageModel.make(context:)`; the real-model harness calls). A test may state a number. Put one constant in a test helper (for example `ScriptedSessionContext.tokens = 8192` in `Tests/FoundationModelsRouterTests/Helpers/`) and point every test site at it. The number then lives in tests only. The footprint and sidecar fixtures that depend on 8,192 keep working through that constant.

`TurnTokenCeilingTests.floorIsNotDefaultContext` (`:128`) compares the floor with the constant. Delete that test with the constant.

## Acceptance

- `rg 'defaultContext'` in `Sources/` finds nothing.
- A profile made with no `context:` argument has `context == nil`, and resolution derives its window from the model.
- All tests pass, with the test constant in one helper.

## Order

Land after "Replace the context ladder with the largest window that fits". Both edit `JointFit.swift`. #compaction #limits
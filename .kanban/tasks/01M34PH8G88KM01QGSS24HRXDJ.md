---
assignees:
- claude-code
depends_on:
- 01M34PGWP0GS427JNWAAMKPZPW
position_column: todo
position_ordinal: '8680'
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
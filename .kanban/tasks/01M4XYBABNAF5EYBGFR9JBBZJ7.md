---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Use SessionFixtureLifecycle in NoOpToolCallSessionFixture
---
Found by the review of ^5kbfsyv (finding BackgroundingSessionFixture.swift:12 and :54). The finding said: do not edit NoOpToolCallModel.swift in that change, and report the edit as a separate task.

`Tests/FoundationModelsRouterTests/Helpers/SessionFixtureLifecycle.swift` now holds the shared steps of a session fixture: `start(over:configuration:prefix:)` (temporary directory, resolve of the standard profile, make of the session) and `end(_:opening:)` (open the gates, close the session, remove the directory, keep the router alive). `BackgroundingSessionFixture` uses both steps.

`NoOpToolCallSessionFixture` in `Tests/FoundationModelsRouterTests/Helpers/NoOpToolCallModel.swift` still has its own copy of these steps:
- `make(startsJob:codes:tempDirPrefix:sessionStep:)` makes the temporary directory, and `vendSession(over:tools:directory:)` resolves the profile and makes the session.
- `end()` opens the gate, closes the session and removes the directory.

- [ ] Make `NoOpToolCallSessionFixture.vendSession` and `make` call `SessionFixtureLifecycle.start(over:configuration:prefix:)` (keep the restored-session step as it is).
- [ ] Make `NoOpToolCallSessionFixture.end()` call `SessionFixtureLifecycle.end(_:opening:)` with its gate.
- [ ] Run `NoOpToolCallStopTests` one time. #elicitation-phase-1
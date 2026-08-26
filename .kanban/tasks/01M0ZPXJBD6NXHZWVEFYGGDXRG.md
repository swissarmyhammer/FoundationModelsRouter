---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Integration scenarios still describe Execute''s deleted "block window", and one snippet still passes `wait: false`'
---
## What
`Execute` has no block window and no `wait` argument. `Sources/FoundationModelsMultitool/Capabilities/Shell/Execute.swift` says so in its own header: "There is no argument that selects a block window, because there is no block window." `ExecuteArguments` declares `command`, `timeout`, `workingDirectory`, and `environment`, and nothing else. `Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift` repeats it: "The `wait` argument selected a block window. There is no block window".

The integration target still describes that deleted mechanism, and one place still uses it in live code. Card ^5tsrz43 found these while it removed the `runCode` wait clock. They are a different mechanism, so they get their own card.

## The sites
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, in the prompt doc: "A call that waits instead still goes to the background — `Execute.mount` answers a 30-second block window and this command outlives it". `Execute.mount` answers `ToolMount(mode: .background, timeout: nil)`. There is no window. Keep the true point: the scenario does not depend on how the model phrased the start.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, at `shellRunPlaneDeadlineSeconds`: "Longer than `Execute`'s own 30-second block window, because a call that did not ask to skip the wait goes to the background only when that window elapses." Give the deadline a live reason.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, at `startSweptRun`: "because `Execute.mount` declares a background mount and `wait: false` answers a block window of zero". The first half is true. The second half is dead.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, in the snippet `startSweptRun` runs: it passes `wait: false` to `tools.shell.execute`. `ExecuteArguments` declares no such argument. THIS IS CODE, not a comment. Find out what the sandbox does with the extra key, then remove it or report what it breaks.
- [ ] `IntegrationTests/.../ShellBackgroundTests.swift`: "30-second block window. A run whose model omits that argument does pay it".
- [ ] `IntegrationTests/.../Support/IntegrationPoll.swift`: "reaches the run plane after the block window of its own call elapses".

## How
Read each sentence. Keep the true half and cut only the dead half. Write each new sentence in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `rg -i 'block window' Sources Tests IntegrationTests docs` returns only sentences that say the block window is GONE.
- [ ] No snippet passes an argument `ExecuteArguments` does not declare.

## Tests
- [ ] `swift build --build-tests` clean, `swift test` green (baseline 1023 tests in 73 suites).
- [ ] `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean.
- [ ] The `wait: false` change touches a live scenario, so say in the card comments whether the scenario was run. #cleanup #docs
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zqbvfnqbwf44gneww9z8ds
  text: |-
    More evidence, from the verifier that read the ^5tsrz43 diff: `ToolMount.synchronous` is `ToolMount(mode: .runToCompletion, timeout: defaultTimeoutSeconds)` in Router `Hosting/ToolMount.swift`. So the sentence "which mounts every tool under `ToolMount.synchronous` - the background path on, stock clocks" is wrong twice: `.runToCompletion` is the opposite of the background path, and `runCode` does not stand under that mount at all, because its own declaration wins.

    `BackgroundTests.swift` now carries the corrected sentence and still points the reader at this file, so the corrected claim cross-references the stale one until this card lands.
  timestamp: 2026-08-26T19:04:48.373802+00:00
position_column: done
position_ordinal: ffff8480
title: ScenarioRunner still says a RoutedSession mounts runCode under ToolMount.synchronous with "stock clocks"
---
## What
Card ^5tsrz43 corrected the same claim in `IntegrationTests/.../BackgroundTests.swift`, and that file points the reader at `ScenarioRunner.swift` for the detail. `ScenarioRunner.swift` is not a file ^5tsrz43 names, so its sites go here, by the scope rule ^zj146zb set.

## The live facts a rewrite must agree with
- `MultiTool.mount` answers `ToolMount(mode: .background, timeout: nil)`.
- Router `ToolMounting.makeWrapped` says "The tool's own declaration wins over the site's configuration". So the site mount `ToolOutputCapping.makeSessionMounted` passes cannot decide what `runCode` does.
- `MultiTool.timeout(from:)` answers `configuration.executionTimeLimit`, the per-call work bound. There is no wait clock.

## The sites
- [x] `IntegrationTests/.../Support/ScenarioRunner.swift`, in the `runBackgroundIntegrationScenario` doc: "a real `RoutedSession`, which mounts every tool under `ToolMount.synchronous` — the background path on, stock clocks". Naming a mount the tool overrides misleads, and "stock clocks" describes a clock that is gone. The claim the sentence needs is that both runners build the same session and that `runCode` goes to the background on both.
- [x] `IntegrationTests/.../Support/ScenarioRunner.swift`, in the same doc: "so on that path a slow snippet simply blocked and a pending envelope could never appear." There is no slow/fast split. The true point is that a bare `LanguageModelSession` carries no background mount, so no snippet on that path could hand back an envelope.

## How
Read each sentence. Keep the true half and cut only the dead half. Write each new sentence in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] No comment says a `RoutedSession` mount decides whether `runCode` goes to the background.
- [x] No sentence that carried a true fact lost it.

## Tests
- [x] Comment-only change: `swift test` green (baseline 1023 tests in 73 suites) and `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean. #cleanup #docs
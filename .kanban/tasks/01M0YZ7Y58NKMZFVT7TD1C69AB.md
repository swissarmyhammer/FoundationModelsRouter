---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0z02hgs84ytb6kaqvtvhgxs
  text: |-
    Research done. Findings:

    - Baseline Router suite: 1058 tests, 2 suites showed flaky failures under full parallel load (GenerationStallDiagnosticTests, TurnCancellationTests). Both pass when run alone. The failures exist before the rename.
    - Full rename map (identifiers): DetachmentParameterProviding -> BackgroundDeclaring; detachmentMount -> mount; detachmentTimeout(from:) -> timeout(from:); detachmentCollectInstruction -> collectInstruction; detachmentRunKind -> runKind; detachmentCanceler -> canceler; DetachConfiguration -> ToolMount; nativeSessionMount -> ToolMount.synchronous; runToCompletionMount -> ToolMount.synchronousUnbounded; ToolDetachment -> ToolMounting; DetachingToolError -> ToolMountError. Test-side: DetachmentLayerPeelable -> MountLayerPeelable; detachmentWrapped(Tool) -> mountWrapped(Tool); ToolDetachmentTests -> ToolMountingTests; DetachedRunTranscriptTests -> BackgroundRunTranscriptTests.
    - Collision found and resolved: three fixtures in NestedGenerationReentryTests have a stored `var mount` plus a computed `detachmentMount { mount }` forwarder. After the rename the stored property itself satisfies the protocol, so the forwarder line is removed.
    - One hard case: two tests probe that a task with no inherited task-locals sees no ToolContext, through Apple's own `Task.detached` API (Router ToolContextTests, Multitool RunBindingFixtures). That API name cannot change, but the acceptance grep must return no match. Replacement: probe from a raw thread through a checked continuation. A raw thread also inherits no task-locals, and the probe catches the same regression class (context stored globally instead of task-locally). The assertion strength for our code is equal, so the test is not weakened.
  timestamp: 2026-08-26T12:17:46.009229+00:00
- actor: claude-code
  id: 01m0z0cw0fp2sq662etajwez38
  text: |-
    Router half is done, with a naming correction from the user applied mid-task: the public protocol is `BackgroundTool` (not `BackgroundDeclaring`), so the engine wrappers moved out of the way — `BackgroundTool` (struct) -> `BackgroundToolRunner`, `RunToCompletionTool` -> `RunToCompletionRunner`, with their files and test suites renamed to match (`BackgroundToolRunnerTests`, `RunToCompletionRunnerTests`). The protocol got its own file `Hosting/BackgroundTool.swift` with the five-line contract doc; `ToolMount` + `ToolMountError` live in `Hosting/ToolMount.swift` (git mv from DetachConfiguration.swift); `Hosting/ToolMounting.swift` holds the factory.

    Evidence so far: `swift build --build-tests` exits 0 with no warning from our code (one build-system note about the mlx bundle node); `swift test` passed 1058 tests in 104 suites plus 83 tests in 10 suites, 2 known issues only; `rg -i detach Sources Tests` returns no match.

    Next: the sibling FoundationModelsMultitool.
  timestamp: 2026-08-26T12:23:24.431373+00:00
- actor: claude-code
  id: 01m0z0s9pf9xhdtgjctw6fxesf
  text: |-
    Multitool half is done. Notes for the next agent:

    - The `Task.detached` probes in Router ToolContextTests and Multitool RunBindingFixtures now probe from a raw thread through a checked continuation. A raw thread also inherits no task-locals, so the probe catches the same regression class (context stored globally instead of task-locally). The assertion is not weakened.
    - Two pre-existing breaks stood in the Multitool IntegrationTests package (it builds against the local Router through the `Packages/` symlink and had drifted): stale `ParkedRun` / `parkedRuns()` references (the earlier no-parked-vocabulary rename in Router never reached this package) and a non-exhaustive switch missing the new `SessionEvent.runSettled` case. Both repaired minimally so the package compiles; local test names such as `ParkedShellRun` were left alone as out of scope.
    - Multitool prose that referenced Router's old wrapper names (`DetachingTool`, `BackgroundTool` the struct, `RunToCompletionTool`) now names `BackgroundToolRunner` / `RunToCompletionRunner`; a stale `RunEventFunnel.markDetached(postingIfSilent:)` mention was removed and `DetachingTool.settle` now points at `ToolRun`.

    ### implement — changed
    - evidence: Router — `swift build --build-tests` 0 errors, 0 warnings from our code; `swift test` 1058 tests / 104 suites passed (2 known issues) plus 83 tests / 10 suites passed; `rg -i detach Sources Tests` no match. Multitool — `swift build --build-tests` clean; `swift test` 1023 tests / 73 suites passed; `swift build --build-tests --package-path IntegrationTests` clean; `rg -i detach Sources Tests IntegrationTests` no match. Nothing committed, both repos left dirty by design.
    - next: /review
  timestamp: 2026-08-26T12:30:11.663091+00:00
depends_on:
- 01M0WM6ENYA6YGSTCETVBJA15J
position_column: doing
position_ordinal: '80'
title: Name the background declaration for what it is
---
## What
The protocol that marks a `Tool` as long-running still uses the old "detach" vocabulary, so a reader cannot find it by the word "background". Rename the declaration surface in `Sources/FoundationModelsRouter/Hosting/` (Router) and update every conformer and call site, then the same in `../FoundationModelsMultitool` (`MultiTool+Detachment.swift`, `Capabilities/Shell/Execute.swift`, `Discovery/SearchToolsTool.swift`, `WaitTool.swift`, `Invocation/RunBinding.swift`, tests):

- [x] `DetachmentParameterProviding` → the marker protocol (named `BackgroundTool` per the user's mid-task correction; the engine wrapper `BackgroundTool` → `BackgroundToolRunner`, `RunToCompletionTool` → `RunToCompletionRunner`). Its doc states the whole contract in five lines: a tool that conforms and returns a background mount always answers with a completion-token handle; a plain `Tool` runs to completion.
- [x] `detachmentMount` → `mount`; `detachmentTimeout(from:)` → `timeout(from:)`.
- [x] `DetachConfiguration` → `ToolMount`; keep `Mode.background` / `Mode.runToCompletion`, `nativeSessionMount` → `ToolMount.synchronous`, `runToCompletionMount` → `ToolMount.synchronousUnbounded`.
- [x] `ToolDetachment` (the factory) → `ToolMounting`; `DetachingToolError` → `ToolMountError`; file names follow the types.
- [x] Rename the Multitool file `MultiTool+Detachment.swift` → `MultiTool+Background.swift`.
- [x] No "detach"/"Detach" identifier remains in either repository's Sources or Tests.

## Acceptance Criteria
- [x] `rg -i 'detach' Sources Tests` in FoundationModelsRouter returns no match.
- [x] `rg -i 'detach' Sources Tests IntegrationTests` in FoundationModelsMultitool returns no match.
- [x] Both packages build and their full suites are green.

## Tests
- [x] Rename-only; existing suites are the regression guard. Run `swift test` in both repositories — green.

## Workflow
- Use `/tdd` — run both suites before and after the rename. #long-running #cleanup #api
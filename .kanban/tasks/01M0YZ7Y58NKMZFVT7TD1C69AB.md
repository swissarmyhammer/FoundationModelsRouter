---
assignees:
- claude-code
depends_on:
- 01M0WM6ENYA6YGSTCETVBJA15J
position_column: todo
position_ordinal: 8a80
title: Name the background declaration for what it is
---
## What
The protocol that marks a `Tool` as long-running still uses the old "detach" vocabulary, so a reader cannot find it by the word "background". Rename the declaration surface in `Sources/FoundationModelsRouter/Hosting/` (Router) and update every conformer and call site, then the same in `../FoundationModelsMultitool` (`MultiTool+Detachment.swift`, `Capabilities/Shell/Execute.swift`, `Discovery/SearchToolsTool.swift`, `WaitTool.swift`, `Invocation/RunBinding.swift`, tests):

- [ ] `DetachmentParameterProviding` → `BackgroundDeclaring`. Its doc states the whole contract in five lines: a tool that conforms and returns a background mount always answers with a completion-token handle; a plain `Tool` runs to completion.
- [ ] `detachmentMount` → `mount`; `detachmentTimeout(from:)` → `timeout(from:)`.
- [ ] `DetachConfiguration` → `ToolMount`; keep `Mode.background` / `Mode.runToCompletion`, `nativeSessionMount` → `ToolMount.synchronous`, `runToCompletionMount` → `ToolMount.synchronousUnbounded`.
- [ ] `ToolDetachment` (the factory) → `ToolMounting`; `DetachingToolError` → `ToolMountError`; file names follow the types.
- [ ] Rename the Multitool file `MultiTool+Detachment.swift` → `MultiTool+Background.swift`.
- [ ] No "detach"/"Detach" identifier remains in either repository's Sources or Tests.

## Acceptance Criteria
- [ ] `rg -i 'detach' Sources Tests` in FoundationModelsRouter returns no match.
- [ ] `rg -i 'detach' Sources Tests IntegrationTests` in FoundationModelsMultitool returns no match.
- [ ] Both packages build and their full suites are green.

## Tests
- [ ] Rename-only; existing suites are the regression guard. Run `swift test` in both repositories — green.

## Workflow
- Use `/tdd` — run both suites before and after the rename. #long-running #cleanup #api
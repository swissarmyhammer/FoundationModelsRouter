---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6khkzmefze62c01802fwdgd
  text: |-
    ### implement — changed
    - evidence: 4 files. git mv Tests/FoundationModelsRouterTestSupport/HookLayeredLLMContainer.swift to Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift (self-import removed, doc warning kept). SessionCheckedTool.swift doc fixed. ScriptedToolHookLayerTests.swift: TestSupport import and doc fixed. New Tests/FoundationModelsRouterTests/HookLayeredContainerInMainProductTests.swift (no TestSupport import; 2 tests: PreToolUse and PostToolUse; foreground cancel ends a root that waits inline).
    - RED: new test file failed with "cannot find 'HookLayeredLLMContainer' in scope". GREEN: 2 of 2 pass. Full `swift test`: 2442 tests, 0 failures, no warnings.
    - `swift build --product FoundationModelsRouter` is green. No file in Sources imports Testing.
    - Public names: HookLayeredLLMContainer (public struct, init(wrapping:)); HookLayeredSessionBackend stays internal; SessionToolLayers stays package.
    - Open: `swift build --build-tests --package-path IntegrationTests` fails BEFORE and independent of this change. IntegrationTests/Package.resolved pins FoundationModelsExtras c922cca; the root pins 0b45545. Extras at c922cca has no SessionTranscriptReader, so RoutedLLM.swift fails. No file in IntegrationTests uses HookLayeredLLMContainer. I did not change the pin.
    - next: /review
  timestamp: 2026-11-04T15:07:41.070636+00:00
position_column: doing
position_ordinal: '80'
title: Move HookLayeredLLMContainer into the main Router product so a normal binary can use it
---
The ACP agent stub binary `acp-agent-stub` runs a scripted model. It needs the session tool layers of a live RoutedModel, so a `session/cancel` of the root ends the root while a tool call waits for a child. Today `HookLayeredLLMContainer` is only in the FoundationModelsRouterTestSupport product, which imports Apple `Testing`. A binary that links it fails at launch in dyld (Testing.framework not loaded). `SessionToolLayers` is `package` access, so the host cannot build the wrapper.

Plan first. No code until the coordinator agrees. No push without the user's words in this session (the user allowed pushes earlier for reviewed work; ask again if unsure).

## Facts
- `Tests/FoundationModelsRouterTestSupport/HookLayeredLLMContainer.swift` has the public struct `HookLayeredLLMContainer: LoadedLLMContainer` and the internal `HookLayeredSessionBackend`.
- The file imports only FoundationModels and FoundationModelsRouter. It needs no Testing framework. The Testing import comes from the target, not from this file.
- It calls `SessionToolLayers.checked(tools)` (package access, Sources/FoundationModelsRouter/Session/SessionCheckedTool.swift:118). The live loader uses the same call.

## Smallest shape (recommended)
Move the two types into the main Router target, under Sources/FoundationModelsRouter/Session/. Keep the names and the public API: `public struct HookLayeredLLMContainer` with `init(wrapping:)`. `HookLayeredSessionBackend` stays internal. `SessionToolLayers` stays `package`, because the wrapper is now in the same module. The TestSupport product keeps working for its users: check that it re-exports Router (`@_exported import`), or that its users already import Router; if not, add a one-line re-export so `import FoundationModelsRouterTestSupport` still sees the type.

## Cost
Small: one file move, doc update, no new target and no new product (see memory: no new targets). One test: a scripted container in the wrapper gives PreToolUse, PostToolUse and the cancel of a waiting root, from a test target that does not import TestSupport. Also check that the full suite and the IntegrationTests package still build.

## Risks
- The wrapper doc must keep the warning: do not wrap a live container (the layers would apply twice).
- Public API grows by one type in the main product. #subagents
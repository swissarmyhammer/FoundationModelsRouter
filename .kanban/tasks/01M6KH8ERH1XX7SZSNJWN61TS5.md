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
- actor: claude-code
  id: 01m6khwx8qfcf7ye5bb62r58b0
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD. 1 finding (confirmed 1, refuted 2).
    - Review Findings (2026-11-04 09:10):
    - [ ] `Tests/FoundationModelsRouterTests/HookLayeredContainerInMainProductTests.swift:33` `swift/naming-clarity` — The name `inlineOp` uses the abbreviation `op`. The rule asks for full words. The abbreviation makes the reader work harder to learn what the value is. Rename to `inlineOperation`, and update the use at line 110 (`ShutdownRunFixtures.arguments(op: Self.inlineOperation, ...)`). The external `op:` label belongs to existing code, so keep it.
    - note: five code-hygiene rules declined an item because they looked for Tests/FoundationModelsRouterTestSupport/HookLayeredLLMContainer.swift, which the commit moved. Nothing was unread in the new file by those rules.
    - next: implementer fixes the finding, then /review again.
  timestamp: 2026-11-04T15:12:33.559729+00:00
- actor: claude-code
  id: 01m6kj7be92y7znhg9kg99pew6
  text: |-
    ### implement — changed
    - evidence: 2 files. Tests/FoundationModelsRouterTests/HookLayeredContainerInMainProductTests.swift, Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift.
    - [x] FIXED `HookLayeredContainerInMainProductTests.swift:33` swift/naming-clarity: `inlineOp` is now `inlineOperation`, with the use at the call site; the external `op:` label is kept. No other abbreviation of that cause is in the file.
    - Review file on HookLayeredLLMContainer.swift gave 2 findings (reuse/reuse). [x] FIXED both: `makeSession(instructions:tools:)` and `makeSession(transcript:tools:)` now delegate to the samplingMode overloads with `samplingMode: nil`, so the tool-layer call `SessionToolLayers.checked` is in one overload for each form. The live loader and this container already share the one `SessionToolLayers.checked` function, so the layering code is single. Docs of both overloads state the delegation. Public API is the same.
    - full `swift test`: 2442 tests in 288 suites, 38 tests, 19 tests; 0 failures, no warnings.
    - next: /review
  timestamp: 2026-11-04T15:18:15.753158+00:00
- actor: claude-code
  id: 01m6kjdbtypf6mtxr8nhqzm1ks
  text: |-
    ### review — findings
    - scope: review sha HEAD~1..HEAD (59203291): 0 findings. review file Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift: 2 findings (confirmed 2, refuted 1).
    - [ ] `Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift:107` `duplication/duplication` — The tools-and-sampling-mode `makeSession(instructions:...)` and the tools-and-sampling-mode `makeSession(transcript:...)` bodies are the same wrap-and-forward block. They differ only by the first argument label and value. Both copies run `SessionToolLayers.checked(tools)` and pass `samplingMode` through. If one copy changes, the other can drift. Extract one private helper that takes the already-built wrapped backend, or a closure over `wrapped.makeSession`. Call it from both sites. Keep the `SessionToolLayers.checked(tools)` call in that one helper so the rule lives in one place.
    - [ ] `Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift:242` `completeness/invariant-propagation` — The new replacingTranscript(_:tools:) passes tools straight to the wrapped backend. It does not call SessionToolLayers.checked(tools). The two makeSession overloads that take tools (lines 109 and 141) do call it. So a session whose transcript is replaced with new tools gets tools without the tool hook layer. Its tool calls send no PreToolUse, PreToolResult or PostToolUse events. The doc comment at lines 17-19 says each tool of each session gets the layers. Wrap the tools at line 242 the same way as lines 109 and 141: `wrapped.replacingTranscript(transcript, tools: SessionToolLayers.checked(tools))`. Add one test that replaces the transcript with tools through this container and checks that the tool events are sent once per call.
    - next: fix both findings, then run /review again. Card body not changed.
  timestamp: 2026-11-04T15:21:32.766969+00:00
- actor: claude-code
  id: 01m6kjsctv5y4s27x6fv06jvht
  text: |-
    ### implement — changed
    - evidence: 2 files. Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift, Tests/FoundationModelsRouterTests/HookLayeredContainerInMainProductTests.swift.
    - [x] FIXED `HookLayeredLLMContainer.swift` duplication/duplication: the tools+samplingMode `makeSession(instructions:...)` and `makeSession(transcript:...)` bodies now call one internal helper, `HookLayeredSessionBackend.layering(_:over:)`. `SessionToolLayers.checked(tools)` is in that one place only.
    - [x] FIXED `HookLayeredLLMContainer.swift` completeness/invariant-propagation: `replacingTranscript(_:tools:)` now goes through the same helper, so its tools get the layers. `makeFork()` and `replacingTranscript(_:)` (no tools) keep the tools of the wrapped backend and do not call the helper, so no tool is wrapped twice. Same cause checked in the whole file: all three paths that give a backend new tools use the helper; no other path does.
    - TDD: new test "a tool of a replaced transcript gets PreToolUse and PreToolResult once for each call" (a backend replaces its transcript with a raw tool through HookLayeredSessionBackend, inside a session). RED before the fix: use 1, post 0, result 0 (no hook events at all — the first RED run counted use 0). GREEN after the fix.
    - Discovery: PostToolUse is NOT sent for a raw tool, even with the layer. The end of the call comes from the ToolResultWitness of the session mount layer (ToolCallEndProbe), and a raw tool has no mount. So the new test asserts exactly one PreToolUse and one PreToolResult; PostToolUse for a composed tool stays in the first test of the suite. The test helper `withSession` got an overload that takes a container and tools.
    - full `swift test`: 2443 tests in 288 suites, 38 tests, 19 tests; 0 failures, no warnings. (The full suite ran two times, because the first output was cut by a filter; the code did not change between the runs.)
    - next: /review
  timestamp: 2026-11-04T15:28:07.003965+00:00
- actor: claude-code
  id: 01m6kk0yjg7azt51kdvhet93gb
  text: |-
    ### review — findings
    - scope: review sha HEAD~1..HEAD (df89dd91): 0 findings (1 refuted, 7 attempted; .kanban files ignored). review file Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift: 1 finding.

    ## Review Findings (2026-11-04 09:30)

    - [ ] `Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift:27` `duplication/duplication` — HookLayeredLLMContainer is a near-copy of MLXFoundationModelsContainer. The copy is in a file this change did not edit, so the same container logic now exists in two places and can drift apart. Extract one shared container, parameterized by whether the tool hook layer is applied, and have both this wrapper and the live loader call it. The change must not edit LiveModelLoader.swift as part of this change. Report the LiveModelLoader side as a separate task.

    - next: fix the finding, then run /review again.
  timestamp: 2026-11-04T15:32:14.544674+00:00
- actor: claude-code
  id: 01m6kk1ym8j486mpqrs2eknnkg
  text: |-
    ### finish — stuck (true conflict, human decision needed)
    - finding: Sources/FoundationModelsRouter/Session/HookLayeredLLMContainer.swift:27 duplication — "near-copy of MLXFoundationModelsContainer"; asks to extract one shared container used by both, and says do NOT edit LiveModelLoader.swift.
    - conflict: the fix needs a change in LiveModelLoader.swift (the live container is in that file), and the finding forbids that change. Also the two types differ: MLXFoundationModelsContainer makes real SDK sessions; HookLayeredLLMContainer only decorates the backends of a wrapped container. The overlap is the ten makeSession overloads that the LoadedLLMContainer protocol requires.
    - state: code is done and green (2443 tests). Local commits 193580e6, 59203291, df89dd91. Review of the commit range is clean. Not pushed.
    - next: a person decides to drop the finding, or to open a separate task for a shared protocol-extension default. Recommended: drop it (protocol surface, not copied logic).
  timestamp: 2026-11-04T15:32:47.368216+00:00
- actor: claude-code
  id: 01m6kn48jjf86pf7888gpvhj2t
  text: |-
    ### finish — done by user decision
    - The user dropped the finding at HookLayeredLLMContainer.swift:27 (shared container with MLXFoundationModelsContainer) for now: "yes, drop the finding for now". Reason: the fix needs a change in LiveModelLoader.swift, which the finding forbids.
    - All other findings are fixed. The range review is clean. Full suite: 2443 tests, 0 failures.
  timestamp: 2026-11-04T16:09:00.242948+00:00
position_column: done
position_ordinal: ffffffffed80
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
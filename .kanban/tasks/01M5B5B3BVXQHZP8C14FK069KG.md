---
comments:
- actor: claude-code
  id: 01m5b5ph4ztn9rnf1jd835vk1q
  text: |-
    Research done.
    - Router TestSupport has no scripted container today. The scripted container that calls its tools directly is in the ACP package (`ScriptedLLMContainer`, `ScriptedSessionBackend`). The Router unit tests use `LiveBackendContainer`, which vends `MLXFoundationModelsSessionBackend`; that backend already puts the layer on (`checkedTools` -> `Tool.sessionChecked`).
    - Design: a public decorator container in TestSupport, `HookLayeredLLMContainer(wrapping:)`, over any `LoadedLLMContainer`. It gives each session (and each fork, through a backend decorator) the tools with the layer of the live backend. The layer goes through one new `package` entry point in Router (`SessionToolLayers.checked(_:)`), which `MLXFoundationModelsSessionBackend` also calls. `Tool.sessionChecked` stays internal.
    - The backend decorator is necessary: a session forks through `backend.makeFork(tools:seededFrom:)` with the raw tools, and the live backend layers those tools too.
    - The session binds the tool hooks around every backend call (`ModelCallToolChecks.bound`), for each backend type. Thus a direct-calling backend gets the events when its tools have the layer.
    - The router internal protocols that the session casts a backend to (`GenerationPassReporting`, `SessionPromptCacheScoping`) are internal, so a host backend cannot conform; the backend decorator hides nothing of a host backend.
    - Router test fixture: `MountCallingLLMContainer` (a direct-calling scripted container in the test helpers).
  timestamp: 2026-10-19T22:49:44.351341+00:00
- actor: claude-code
  id: 01m5b614k7rea2svk4evcxw5re
  text: |-
    Implementation landed (not committed).
    - Router: new `package enum SessionToolLayers` with `checked(_:)` in `Sources/FoundationModelsRouter/Session/SessionCheckedTool.swift`. It is the one code path that puts the session layers on tools. `MLXFoundationModelsSessionBackend` calls it now; its private `checkedTools` is gone. `Tool.sessionChecked` stays internal.
    - TestSupport: new `public struct HookLayeredLLMContainer(wrapping:)` in `Tests/FoundationModelsRouterTestSupport/HookLayeredLLMContainer.swift`. It forwards each `LoadedLLMContainer` requirement (the sampling-mode variants and `submitting(to:)` too) and layers the tools through `SessionToolLayers.checked`. An internal `HookLayeredSessionBackend` layers the tools of `makeFork(tools:)` and `makeFork(tools:seededFrom:)`, and keeps each fork and replaced backend in the decorator.
    - Test fixture: `MountCallingBackend` now honors the tools of `makeFork(tools:seededFrom:)` (a fork makes the scripted calls again), so the fork test can see the fork tool events. No existing test forks that backend.
    - Tests: `Tests/FoundationModelsRouterTests/ScriptedToolHookLayerTests.swift`, 5 tests, plain imports only. RED: 4 failed with a pass-through container (no events, block ran the body); the plain-container test passed. GREEN: 5 of 5 pass.
    - Full `swift test`: 1916 tests in 237 suites passed (9 known issues, all `withKnownIssue` tests that existed), plus 26 public-surface and 19 eval tests. The only warning is the build-system `missing creator for mutated node` line for the Cmlx bundle, which was there before this change.
    - Follow-up for the ACP session: `HookCompositionTests.swift` can delete its private `HookLayeredLLMContainer` and its `@testable import FoundationModelsRouter`, and use `HookLayeredLLMContainer(wrapping: ScriptedLLMContainer(script:))` from `FoundationModelsRouterTestSupport`.
    - Caution in the doc comment: do not wrap a live container; its backend already layers the tools, so each event would come two times.
  timestamp: 2026-10-19T22:55:31.943759+00:00
- actor: claude-code
  id: 01m5b6174jd7qw2553xtr94qey
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Session/SessionCheckedTool.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTestSupport/HookLayeredLLMContainer.swift (new), Tests/FoundationModelsRouterTests/ScriptedToolHookLayerTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/MountCallingBackendFixtures.swift. `swift test --filter FoundationModelsRouterTests.ScriptedToolHookLayerTests`: 5 of 5 pass; full `swift test`: 1916 tests pass.
    - next: /review
  timestamp: 2026-10-19T22:55:34.546614+00:00
- actor: claude-code
  id: 01m5b64qspe0a8k7xm11vh4y9j
  text: |-
    ### test — green
    - evidence: touched the 5 changed Swift files. `swift test` (root): build complete, 1916 tests in 237 suites passed, 0 failed, 0 skipped. The 9 known issues come from old withKnownIssue tests (RealModelHarness, wait-failure tests), not from this change. Suite "HookLayeredLLMContainer" passed.
    - evidence: `cd IntegrationTests && swift build --build-tests`: Build complete. TestSupport compiled in both packages. IntegrationTests did not need package symbols.
    - warnings: only the known mlx "missing creator for mutated node". No Swift compiler warning.
    - next: review
  timestamp: 2026-10-19T22:57:29.910272+00:00
- actor: claude-code
  id: 01m5b6ax9h1s8vbavg93x5s1qx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (efa0402b). 0 findings, 0 confirmed, 1 refuted. 5 files reviewed. 2 .kanban files are excluded by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-19T23:00:52.145297+00:00
- actor: claude-code
  id: 01m5b6b9esnc010z7jf8s8y30p
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test, 1916 passed, 0 failed; IntegrationTests build complete
    - commit: efa0402b
    - review: clean — 0 findings
  timestamp: 2026-10-19T23:01:04.601698+00:00
position_column: done
position_ordinal: ffffffff9980
title: 'FoundationModelsRouterTestSupport: a public scripted container with the tool hook layer'
---
## Context
The user approved this on 2026-10-19. Found while doing the ACP card ^0bxnzpa (wire hooks and snapshots into the composition).

Router puts the tool hook layer (`Tool.sessionChecked`, internal) on the tools of a session only in `LiveModelLoader`. A scripted container (`ScriptedModel` and the containers of `FoundationModelsRouterTestSupport`) calls its tools directly. Thus in a scripted test of a host (the ACP agent), no `PreToolUse`, `PreToolResult` or `PostToolUse` fires, and no snapshot is taken. The ACP tests now reach `sessionChecked` through `@testable import FoundationModelsRouter` and a private `HookLayeredLLMContainer` in `FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift`.

## What
Give hosts a public, supported way to test the tool hooks with a scripted model.
- In `FoundationModelsRouterTestSupport` (the shared test library that Router publishes), add a public scripted container, or a public option of the existing scripted container, that puts the hook layer on its tools in the same way as `LiveModelLoader` does: the no-op and repetition checks outermost, then the hook layer, then the failure delivery.
- Use the same internal code path as `LiveModelLoader`, so that the test layer and the live layer cannot drift apart. Do not copy the layer logic.
- Keep `Tool.sessionChecked` internal.
- Write doc comments. Say that a host test uses this container to see the tool events with a scripted model.

## Acceptance Criteria
- [x] A test in Router, through only the public API of `FoundationModelsRouterTestSupport` (no `@testable import`), makes a scripted session with a tool call and a recording visitor, and gets `PreToolUse`, `PreToolResult` and `PostToolUse` in order.
- [x] A block on `PreToolUse` through this container does not run the tool body, the same as the live loader.
- [x] A tool that throws gives `PostToolUse` with `succeeded: false`.
- [x] The existing scripted containers do not change for a test that does not use the new container or option.

## Tests
- [x] `Tests/FoundationModelsRouterTests/ScriptedToolHookLayerTests.swift` (Swift Testing): each criterion above, in a test that imports only the public modules.
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.
- When the card is done, push to origin/main and send the commit to the session `foundationmodelsacpagent-a2`.

#hooks
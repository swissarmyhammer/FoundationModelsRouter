---
comments:
- actor: claude-code
  id: 01m5awzdgeccace079p2fdq1sp
  text: |-
    Picked up. Research results:
    - FoundationModelsHooks origin/main 803cc67 gives `HookDispatcher(dataDirectory:logger:)` (`register`, `isEmpty`, `post`, `pre`, `drain()`), `HookSession(sessionID:sessionKey:parentSessionID:workingDirectory:dataDirectory:)`, `SessionOrigin` (.new .resumed .forked .replacement .subagent), `SessionStart(origin:)`, `SessionEnd()`. The dispatcher counts open sessions per key: a SessionStart opens a key, a SessionEnd closes it, and a post for a key with no open session is dropped with a warning. Thus each SessionStart must get exactly one SessionEnd.
    - All three session shapes go through `makeRoutedSessionActor` (RoutedSessionActor.swift): `RoutedModel.makeSession(grammar:...)` (RoutedLLM.swift), `performFork` (RoutedSessionActorForking.swift) and `restoreSessionTree.rebuild` (SessionTreeRestoration.swift). `restoreSession` calls `restoreSessionTree` and then releases the recorded forks with no close.
    - A child session (`parentCall`) knows only `ToolContext.sessionID` of its parent, not the parent actor. A sub-agent restore knows only `SessionSidecar.agentSpawn.parentSessionId`. Thus the Router needs a lookup from an open session id to its `HookSession` to find the key of the parent.
    - `close()` can run two times (`closeAndAwaitTheEnd` runs again after a close from own work), so SessionEnd needs a once-only guard.
    Plan: a `RouterHooks` object (dispatcher plus open-session lookup) that the Router gives to each `RoutedModel`; one pure lineage function; a per-session emitter that posts SessionStart in `makeRoutedSessionActor` and SessionEnd once in close(). The emitter also posts SessionEnd when a session that got a SessionStart is released with no close (for example the forks that `restoreSession` releases), so that the dispatcher does not keep a queue for that key.
  timestamp: 2026-10-19T20:17:18.350878+00:00
- actor: claude-code
  id: 01m5axhfcdzeazy4pnhj5jwkwh
  text: |-
    Implementation landed (not committed).
    - Package.swift: `FoundationModelsHooks` (git@github.com:swissarmyhammer/FoundationModelsHooks.git, branch main) on the library target and the unit test target. Package.resolved pins 803cc67f. Package.resolved is in .gitignore in this repo, so the pin is local only. The local Package.resolved also pinned FoundationModelsExtras at the old f9b5496 (no `WorkRegistry`), so HEAD did not compile; `swift package --manifest-cache local update FoundationModelsExtras` moved it to 23baf04 (origin/main).
    - New `Session/SessionHooks.swift`: `HookParent`, `HookLineage.make(...)` (the one lineage function), `RouterHooks` (dispatcher plus the hook session of each open session, so a sub-agent finds the key of its parent from `ToolContext.sessionID`), `SessionHooks` (once-only SessionStart and SessionEnd under one lock).
    - `Router.init(hooks: HookDispatcher? = nil)` -> `RoutedModel.hooks` on each slot. `makeRoutedSessionActor` takes `hooks:` with no default and starts them after the construction, for the vended, forked and restored shapes. `closeAndAwaitTheEnd` ends them last.
    - `SessionConfiguration.hookSessionKey` / `hookOrigin` (not in `persistable`).
    - Decisions: a host key or origin wins over the derived one. A sub-agent is a session with `parentCall` or with a recorded `agentSpawn` (the restore can read only `agentSpawn`). When the dispatcher has no visitor at the start, the session sends no SessionStart and then no SessionEnd, so the open-session count of the dispatcher stays correct. `SessionHooks` also sends SessionEnd when a started session is released with no close (for example the forks that `restoreSession` rebuilds and releases); without this the dispatcher keeps a queue for that key for ever.
    - Fork key rule compares `standardizedFileURL.resolvingSymlinksInPath().path`.
  timestamp: 2026-10-19T20:27:10.093972+00:00
- actor: claude-code
  id: 01m5axjamdb61t0pard4heqq9r
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` has no compiler warning (only the known mlx `missing creator` line). `swift test --skip-build --filter FoundationModelsRouterTests.HookLineageTests`: 11 tests in 1 suite passed. Full `swift test --skip-build`: 1866 tests in 232 suites passed (9 known issues, all the existing wait-helper self-tests), 26 tests in 14 suites passed, 19 tests in 3 suites passed. 11 files: Package.swift, Sources/FoundationModelsRouter/{Router.swift, LanguageModelProfile.swift, RoutedLLM.swift, Session/SessionHooks.swift (new), Session/SessionConfiguration.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorForking.swift, Recording/SessionTreeRestoration.swift}, Tests/FoundationModelsRouterTests/{HookLineageTests.swift (new), Helpers/RouterTestFixtures.swift}.
    - next: /review. The IntegrationTests package was not built here; its callers of `RoutedSessionActor(...)` and `RoutedModel(...)` take the new `hooks` parameter by its default.
  timestamp: 2026-10-19T20:27:37.997439+00:00
- actor: claude-code
  id: 01m5axsqzqpc8s8s6nr0ysraff
  text: |-
    ### test — green
    - evidence: touched the 11 changed Swift files, then `swift build --build-tests` (root) — no warning but the known mlx "missing creator" line. `swift test` (root) — 1866 tests in 232 suites passed with 9 known issues (the withKnownIssue tests of the wait helpers and RealModelHarness, not in the changed files); 26 tests and 19 tests of the other two runs passed; 0 failed, 0 skipped. `cd IntegrationTests && swift build --build-tests` — first run failed (cannot find WorkRegistry, WorkKind, BackgroundWork) because the git-ignored IntegrationTests/Package.resolved pinned FoundationModelsExtras at f9b5496, older than the root pin 23baf04. After `swift package --manifest-cache local update FoundationModelsExtras` (sourcekit-lsp of the repo stopped first) the build completed with no warning but the known mlx line. No tracked file was changed by this step.
    - next: review, then commit.
  timestamp: 2026-10-19T20:31:41.047995+00:00
- actor: claude-code
  id: 01m5ay1ggxran192e55xm40r1a
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 7d062740); 1 finding (1 confirmed, 2 refuted) — Tests/FoundationModelsRouterTests/HookLineageTests.swift:28
    - next: implement the open item in the "Review Findings (2026-10-19 15:32)" section, then review again.
  timestamp: 2026-10-19T20:35:55.549781+00:00
- actor: claude-code
  id: 01m5ay1ypvy42ffbmczbx52gdt
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files
    - test: green — swift test, 1866 passed, 0 failed; IntegrationTests build complete
    - commit: 7d062740
    - review: findings — Tests/FoundationModelsRouterTests/HookLineageTests.swift:28
  timestamp: 2026-10-19T20:36:10.075653+00:00
- actor: claude-code
  id: 01m5ay5y5y33ncy4q10ww18ejs
  text: 'Finding fixed: `HookLineageTests.swift:28` duplication/duplication. A shared `BasicLLMContainer` is now in `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift` at file scope. It has a named constant `responseText = "stub response"`. The private copy in `HookLineageTests.swift` is deleted, and the suite uses the shared type. The other suites keep their private nested copies. A nested type hides the file-scope type, so the build has no ambiguity. Task ^gq6pj50 (no tag) holds the other copies: PlanRestorationTests, SessionTreeRestorationLostRunTests, ElicitationRoutingTests (equal copies), and BackgroundRunTranscriptTests, SessionConfigurationTests, SessionRestorationTests, PendingEventInjectionTests, SessionMailQueueTests (copies with a different behavior). The only warning in the build is the known `missing creator for mutated node … mlx-swift_Cmlx.bundle` warning. It was in the earlier builds too.'
  timestamp: 2026-10-19T20:38:20.606120+00:00
- actor: claude-code
  id: 01m5ay60j4hbnv0ynztr2knjxs
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, Tests/FoundationModelsRouterTests/HookLineageTests.swift. `swift build --build-tests` exit 0; it recompiled the test product, and the only warning is the known mlx bundle warning. `swift test --filter 'FoundationModelsRouterTests.HookLineageTests'`: "Test run with 11 tests in 1 suite passed". Finding flipped to [x]. New task ^gq6pj50 holds the other copies.
    - next: /test, then /review
  timestamp: 2026-10-19T20:38:23.044239+00:00
- actor: claude-code
  id: 01m5ay88dsrff5jvwhvcggrjy6
  text: |-
    ### test — green
    - evidence: touched all Tests/FoundationModelsRouterTests/*.swift so the compiler built them fresh. Ran `swift test` one time. Build complete (22.75 sec), exit 0. Swift Testing: 1866 tests in 232 suites passed, 0 failures. Two more runs passed (26 tests and 19 tests). XCTest: 0 tests, 0 failures.
    - warnings: only the known mlx "missing creator for mutated node" line. No compiler warning in the test files.
    - skipped: 0. The 9 "known issues" come from tests that use withKnownIssue on purpose (RealModelHarness, PromptWaitTests, ManualRunClockWaitTests, TaskEndEventWaitTests). They do not use BasicLLMContainer.
    - next: review and commit.
  timestamp: 2026-10-19T20:39:36.633192+00:00
position_column: doing
position_ordinal: '80'
title: Router holds a HookDispatcher, gives it to each session, and emits SessionStart and SessionEnd
---
## Context
This card is a Router change for the hook system that was designed in a FoundationModelsACPAgent session (2026-10-19). The user approved this change on 2026-10-19.

Precondition (other board): the FoundationModelsHooks cards 01M5ARTC56ZSHRXFYA7P8X3NXB (events, `HookSession`) and 01M5ARTJH0X25PJDQCTNJVHXF4 (`HookDispatcher`, with `drain()`) are done, and `swissarmyhammer/FoundationModelsHooks` is on GitHub. Until then, this card is blocked.

## What
Router holds one `HookDispatcher`, gives it to each `RoutedSession` on each slot (main, flash, a sub-agent, a fork, a model-switch replacement, a restored session), and emits `SessionStart` and `SessionEnd`. The prompt, compaction and tool events are other cards; they use the plumbing of this card. Each Router host gets hooks, not only the ACP agent. Use symbol names, not line numbers.

- `Package.swift`: add `FoundationModelsHooks` as a remote family dependency on `main`, with the same convention as the other family packages.
- `Router.init` (`Router.swift`): add `hooks: HookDispatcher? = nil`. Give it to each `RoutedLLM`, to each session that `RoutedLLM.makeSession(configuration:)` makes, to each child that `fork(workingDirectory:)` → `performFork` makes (`RoutedSessionActorForking.swift`; a fork does not go through `makeSession`), and to each session that `RoutedLLM.restoreSession` and `restoreSessionTree` make (`Recording/SessionRestoration.swift`, `Recording/SessionTreeRestoration.swift`). When `hooks` is `nil` or `isEmpty`, emit nothing and do no work.
- `SessionConfiguration`: add `hookSessionKey: String?` and `hookOrigin: SessionOrigin?`. A host sets them for a model-switch replacement (`.replacement`, and the key of the replaced session).
- Lineage rules, in one function with tests. Router owns each `HookSession`, and reads `dispatcher.dataDirectory` when it builds one.
  - New session: the key is `hookSessionKey`, else the session `id`. The origin is `hookOrigin`, else `.new`.
  - Child session (`parentCall`, a sub-agent): `.subagent`, `parentSessionID` = the `id` of the parent session, and the key of the parent.
  - Fork: `.forked` and `parentSessionID` = the `id` of the parent. The child gets the key of the parent only when its working directory is equal to the working directory of the parent. Else its key is its own `id`, so a snapshot store never mixes two work trees under one key.
  - Restored session (`restoreSession`, and each session of `restoreSessionTree`): `.resumed`. A restored session keeps its recorded `id`, so its key is the same as before the restore. Restored forks and children follow the fork and child rules, with `.resumed` as their origin.
- `SessionStart` (post) when a session is made, forked or restored. `SessionEnd` (post) in `close()`, one time only, also when `close()` runs more than one time.

## Acceptance Criteria
- [x] With no dispatcher, the Router tests pass unchanged, and no hook code runs.
- [x] A recording visitor gets `SessionStart` and then `SessionEnd` for one session, one time each, also after two `close()` calls.
- [x] A session made with `hookSessionKey: "k"` and `hookOrigin: .replacement` gets the key `k` and `.replacement`.
- [x] A fork with the same working directory gets `.forked`, the key of the parent and `parentSessionID`. A fork with a different working directory gets its own `id` as its key.
- [x] A child session (`parentCall`) gets `.subagent`, the key of the parent, and `parentSessionID` = the parent `id`.
- [x] `restoreSession` gives `SessionStart(.resumed)` with the recorded `id` as the key. `restoreSessionTree` gives one `SessionStart(.resumed)` for each restored session.

## Tests
- [x] `Tests/FoundationModelsRouterTests/HookLineageTests.swift` (Swift Testing): each criterion above, with a scripted model from `FoundationModelsRouterTestSupport`, and `dispatcher.drain()` before each assertion on post events.
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks

## Review Findings (2026-10-19 15:32)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 14 not reviewed.

> 14 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 14 file(s)

- [x] `Tests/FoundationModelsRouterTests/HookLineageTests.swift:28` `duplication/duplication` — The new private struct BasicLLMContainer is a copy of a stub that already exists in other test files. The copy can drift out of sync with the others. Move one shared BasicLLMContainer into Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift. Delete the copy in HookLineageTests.swift and use the shared type. Do not edit the other files in this change. Report the other copies as a separate task.

---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rx9gkkxyem9gzev9982e5k
  text: |-
    Research done.
    - Today `RouterSessionDirectory.fork(_:)` calls `RoutedSessionActor.makeFork(at:)`, which maps the cut (`forkSeed(at:)`) and builds the fork at once (`RoutedModel.makeFork(of:seed:)` in RoutedLLMForking.swift, fork id from `ULID.generate()` there).
    - The actor writes its first `index.md` (and so its recording folder) in `makeRoutedSessionActor`. So a fork that a launcher built and then threw has a recording node. The directory must close that fork and remove the folder `<source recording folder>/<fork id>`.
    - Plan: split the actor call in two: `prepareFork(at:) -> ForkSeed` (the cut, on the source actor) and `makeFork(id:seed:tools:)` (the build). New public `SessionLaunchForkRequest` (source id, fork id, `forkedAtHistoryOrdinal`, folder, client) with `makeFork()` (tools of the source) and `makeFork(tools:)` (the host surface). New protocol requirement `forkSession(_:)` with a default in a protocol extension that calls `request.makeFork()`. The directory: prepare, launch (or build directly with no launcher), check that the session is the one the request built, register, hold, mail.
    - `SessionForkRequest` and `SessionDirectoryError` are Extras types; I do not change Extras. A new Router error `SessionLaunchForkError` covers a second build and a launcher that returns another session.
  timestamp: 2026-11-19T03:23:34.899138+00:00
- actor: claude-code
  id: 01m7rxrx7smpmeqgqwqb1h5py2
  text: |-
    ### implement — changed
    - evidence: launcher operation `func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession` on `SessionLauncher`, with a default in a protocol extension that calls `request.makeFork()` (tools of the source). `public struct SessionLaunchForkRequest: Sendable` has `sourceID: ULID`, `forkID: ULID`, `forkedAtHistoryOrdinal: Int`, `workingDirectory: URL`, `requestedByClient: String?`, `func makeFork(tools: [any Tool]) async throws -> any RoutedSession` (host surface) and `func makeFork() async throws -> any RoutedSession` (tools of the source). New `public enum SessionLaunchForkError { case forkAlreadyMade(ULID), notTheRequestedFork(ULID) }`.
    - Directory order: `prepareFork(at:)` maps the cut, the directory chooses the fork id, the launcher (or `makeFork()` with no launcher) builds, the directory checks that the session is the one the request built, registers, holds, mails. On a throw: close the built fork, remove `<source folder>/<fork id>`, register nothing.
    - Files: Sources/FoundationModelsRouter/Directory/SessionLaunchForkRequest.swift (new), SessionLauncher.swift, RouterSessionDirectory.swift, RoutedLLMForking.swift, Session/RoutedSessionActorForking.swift, Session/SettledTranscript.swift (doc link); Tests: RouterSessionDirectoryForkLauncherTests.swift (new, 13 tests), Helpers/ForkLauncherFixtures.swift (new), Helpers/ForkFixtures.swift (`makeSource` takes `tools:`), PublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift (+1 test, public conformance).
    - RED: first a compile failure (no type), then with the type but no directory wiring 11 of 13 failed; the 2 that passed are the "launcher with no fork operation" guards of the old behavior. GREEN: 13/13. Fork suites `FoundationModelsRouterTests.RouterSessionDirectoryFork`: 55 tests in 5 suites passed. Public surface suite: 3 passed.
    - Full `swift test` one time: 3074 tests in 350 suites passed, 50 in 26 and 19 in 3 passed, exit 0, 0 issues. Output: scratchpad/full-suite.txt. A first full run was stopped before its end because I changed code (build reset on a throw, a doc line) while it ran; it is not counted.
    - next: review. Not committed, not pushed.
  timestamp: 2026-11-19T03:31:59.353997+00:00
- actor: claude-code
  id: 01m7ry24s8tm5f6s8f3kbk3we7
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c41097b8). Engine: 2 findings, 2 confirmed, 0 refuted — Tests/FoundationModelsRouterPublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift:47, Tests/FoundationModelsRouterTests/Helpers/ForkLauncherFixtures.swift:169. Orchestrator checks: 1 finding — Sources/FoundationModelsRouter/Directory/SessionLaunchForkRequest.swift:169 (the request can build a fork after the fork call ends).
    - checks that pass: the first prompt starts only after the launcher returns; a launcher that throws leaves no registration, no live fork and no recording node; a second build is refused (forkAlreadyMade); another session is refused (notTheRequestedFork); the pump files did not change; prepareFork reads the settled transcript, not the live transcript; the ACPAgent AgentSessionLauncher declares only launchRootSession and restoreSession, so the default forkSession applies.
    - next: implement the 3 open items in the 2026-11-18 21:32 section.
  timestamp: 2026-11-19T03:37:01.992446+00:00
- actor: claude-code
  id: 01m7ry2v2fx9c7k14aderw6t8a
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionLaunchForkRequest.swift (new), SessionLauncher.swift, RouterSessionDirectory.swift, RoutedLLMForking.swift, RoutedSessionActorForking.swift, SettledTranscript.swift; RouterSessionDirectoryForkLauncherTests (new, 13), ForkLauncherFixtures (new), public surface test
    - test: green — one full swift test run, 3074 tests in 350 suites (+50, +19), 0 failures
    - commit: c41097b8
    - review: findings — SessionLauncherPublicSurfaceTests.swift:47, ForkLauncherFixtures.swift:169 (copied launcher stubs), SessionLaunchForkRequest.swift:169 (the request stays usable after the fork call ends: a late or in-flight build makes an unregistered fork)
  timestamp: 2026-11-19T03:37:24.815895+00:00
- actor: claude-code
  id: 01m7ryke4hef21jqpfcm0bgs9b
  text: |-
    ### implement — changed
    - evidence: the 3 items of the 2026-11-18 21:32 section are done.
    - Items 1 and 2: new shared test helper `public protocol StartRefusingLauncher: SessionLauncher` in Tests/FoundationModelsRouterTestSupport/StartRefusingLauncher.swift. Its extension refuses each start (`SessionDirectoryError.unknownAgent(request.agentID ?? "default", nearNames: [])`) and each restore (`unknownSession(id)`). Both test targets already link TestSupport. `AgentlessLauncher` is now `struct AgentlessLauncher: StartRefusingLauncher {}`; `ForkingHostLauncher` and `ForkLaunchingLauncher` declare only `forkSession`.
    - Item 3: new error case `SessionLaunchForkError.requestClosed(ULID)`. `ForkBuild` has a `.closed` state. Its `.open` state holds the builder closure, which holds the source and the seed, so the close releases them. `close()` returns the fork that the build made (or nil) and sets `.closed`; `discard(_:)` closes a fork and removes its recording folder. `launchFork(_:)` calls `close()` on each path: success, throw before build, throw after build, another session. A build in flight at the close discards its fork and throws `requestClosed`. A build that throws after the close stays closed.
    - Test seam: `ForkBuild.init(forkID:recordingDirectory:builder:)` takes the build as a closure, so a test can hold the build at a gate (AwaitedEvent) with no sleep.
    - New tests (8): RouterSessionDirectoryForkLauncherTests +5 (a request kept after each path of the fork call: throw before build -> requestClosed, and no recording node; throw after build, another session, success -> requestClosed). New suite ForkBuildTests (3): a gated build that ends after the close throws requestClosed, its fork is closed, its recording folder is gone.
    - RED: one run, 8 of 8 new tests failed for the expected reason (no error and a live fork, `forkAlreadyMade` in place of `requestClosed`, folder present, fork not closed). Output: scratchpad/red.txt. GREEN: 21/21 and 3/3 in the changed suites.
    - Full `swift test` one time: 3082 tests in 351 suites passed, 50 in 26 and 19 in 3 passed, exit 0, 0 issues, no compiler warning. Output: scratchpad/full-suite-vhy7017-fix.txt.
    - next: review. Not committed.
  timestamp: 2026-11-19T03:46:28.625294+00:00
- actor: claude-code
  id: 01m7rysjvp79yzyds19wn1yp5x
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4ed26812). 8 files reviewed. 0 findings, 0 confirmed, 0 refuted. All 3 items of the 2026-11-18 21:32 section are checked.
    - check: StartRefusingLauncher replaces the two stub copies. launchFork(_:) closes the build on each path. close() and keep(_:) change the state under the same Mutex, so one of the two is always first: when close is first, make(tools:) discards the fork and throws requestClosed; when keep is first, close() returns the fork and launchFork keeps or discards it. A builder that throws after the close does not reopen the build. The close sets .closed, which releases the builder and thus the source and the tools.
    - check: the 8 new tests fail without the fix (a kept request stays .open or gives forkAlreadyMade; a late build keeps a live fork and its folder).
    - next: none. The task moves to done.
  timestamp: 2026-11-19T03:49:50.070888+00:00
- actor: claude-code
  id: 01m7ryt4wbkca7jtasmj2cwqp4
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — SessionLaunchForkRequest.swift (closed state, requestClosed), RouterSessionDirectory.swift, SessionLauncher.swift; StartRefusingLauncher (new), ForkBuildTests (new), 3 test files
    - test: green — one full swift test run, 3082 tests in 351 suites (+50, +19), 0 failures
    - commit: 4ed26812
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-19T03:50:08.523964+00:00
depends_on:
- 01M7RSS1HNR7E0G704X1VESQJJ
position_column: done
position_ordinal: ffffffffffb780
title: A fork goes through the host launcher, so the host gives its surface before the first prompt runs (D205)
---
## Goal

A fork that the `sessions` tool makes (`fork session`) runs on the tools of the source, and its first prompt starts at once. When a client later resumes the fork, the host stops the live fork and restores it on its own surface (the MCP servers and directories of the client or of the source). That stop can cancel the first prompt, and the first prompt ran on the wrong surface. Request from foundationmodelsacpagent-9e (D205).

## Decision

The Router already asks the host to build a session through `SessionLauncher` (`Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:39`) for `startAgent` and for a restore. A fork uses the same way:
- Add a launcher operation for a fork, for example `forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession`, with the source id, the cut position, and the fork id that the directory chose. Give it a default implementation that keeps the current behavior (the Router builds the fork with the tools of the source), so a launcher that does not implement it compiles.
- `RouterSessionDirectory.fork(_:)` calls the launcher operation when the directory has a launcher, so the host builds the fork with its surface. Then the directory registers the fork and mails the first prompt. Thus no prompt runs before the host gave the surface, and the host holds the fork from its start (no stop and restore).
- Keep the record, the recording node, the name, the hooks and the cut rule of ^3hxcxee.
- Write the rule in the doc of `fork(_:)` and of the launcher operation.

## Tests

- [x] With a launcher that implements the fork operation: the launcher gets one call with the source, the cut position and the fork id; the fork uses the session that the launcher gave; the first prompt runs on that session.
- [x] With a launcher that does not implement it: the fork works as before.
- [x] The first prompt does not start before the launcher returns.
- [x] A launcher that throws: the fork is refused, nothing is registered, no recording node stays.

## After

Push when green. Send the sha and the name of the launcher operation to foundationmodelsacpagent-9e. #d205

## Review Findings (2026-11-18 21:32)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterPublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift:47` `reuse/reuse` — The new ForkingHostLauncher declares launchRootSession and restoreSession with bodies that are the same as the existing AgentlessLauncher stubs (both throw the same error). The new type repeats that stub behavior instead of reusing it, so a later change to the stub must be made in two places. Only the forkSession operation is new behavior here. Give AgentlessLauncher the forkSession operation as a parameter (for example, a closure with a default that throws), or let ForkingHostLauncher wrap or extend AgentlessLauncher, so only the fork operation is written in the new type.
- [x] `Tests/FoundationModelsRouterTests/Helpers/ForkLauncherFixtures.swift:169` `reuse/reuse` — ForkLaunchingLauncher repeats the launchRootSession and restoreSession stub bodies (each throws Refusal) that the public-surface test launchers already implement. These two new stubs add a second copy of the same no-op behavior. Reuse one stub source for the no-op launcher operations. For example, move the shared no-op operations into one test helper that the fork launcher and the public-surface launcher both use, and keep only forkSession in ForkLaunchingLauncher.
- [x] `Sources/FoundationModelsRouter/Directory/SessionLaunchForkRequest.swift:169` `orchestrator-check/request-after-fork` — `ForkBuild` has no closed state, so the request stays usable after `RouterSessionDirectory.fork(_:)` ends. When the fork call ends with no fork built (the launcher throws before it builds, or it gives another session), the state stays `.open`. A launcher that kept the request (it is `Sendable` and public) can then call `makeFork()` or `makeFork(tools:)` later: this makes a second, live fork with a recording node in the folder of the source, with the tools of the source, that the directory does not register, hold or close. Also, a build that the launcher starts in a task of its own and that ends after the launcher threw is not discarded, because `discard()` (line 156) saw no fork. And a kept request keeps the source and its tools alive. Close the build when the fork call ends: for example, a `.closed` state that `launchFork(_:)` (`RouterSessionDirectory.swift:1512`) sets on each path (success and refusal), that `make(tools:)` refuses with a `SessionLaunchForkError`, and that discards a fork that a build in flight makes after the close. Drop the strong reference to the source at the close. Add tests: a request kept after a refused fork cannot build; a build that ends after the launcher threw leaves no live fork and no recording node.
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
depends_on:
- 01M7RSS1HNR7E0G704X1VESQJJ
position_column: doing
position_ordinal: '80'
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
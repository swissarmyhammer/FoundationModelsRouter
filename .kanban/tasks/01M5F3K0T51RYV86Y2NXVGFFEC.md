---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gbnzjhhdr7qhe8hwf7t48b
  text: 'Research: Extras 589f27e declares no SessionLauncher; Router owns the protocol (spec session.md 5.4). SessionDirectory.start(_:) is the only port requirement touched. The directory holds sessions weakly, so the launcher (host) must keep the session it returns; the test fake keeps its vended sessions. updateFacts lives on RoutedSessionActor (internal), not on the RoutedSession protocol, so start repairs missing request facts through a cast; every in-module RoutedSession is a RoutedSessionActor. requestedByClient threads SessionConfiguration -> RoutedLLM.makeSession -> registerVendedSession -> register. shutdown must take the continuations out of the lock before finish(): onTermination re-enters the state Mutex. Router.useRunClock is the prevailing actor-isolated `use...` setter shape, so useLauncher is actor-isolated too.'
  timestamp: 2026-10-21T23:10:29.969291+00:00
- actor: claude-code
  id: 01m5gc3nzzpvbhkrdwgjhzz9tr
  text: |-
    Implementation landed. start(_:) launches through the launcher, then admit(): a session already registered by its own router gets any missing request fact via RoutedSessionActor.updateFacts plus a factsChanged (updatedAt bumped); a session not in this directory (another router) gets the facts first and is then registered as a root, so its one started carries them and requestedByClient. A non-RoutedSessionActor session lacking facts hits assertionFailure + an error log under the new RouterTelemetry.LogCategory.sessionDirectory (no in-module type reaches it). shutdown() nils the launcher and finishes the streams outside the Mutex (SessionDirectoryEventFanout.removeAll), since onTermination re-takes the lock. The event-read helper of RouterSessionDirectoryEventTests moved to Tests/.../Helpers/SessionDirectoryEventReads.swift so the new suite shares it instead of copying it. Tests: swift test --filter "RouterSessionDirectoryLauncher|SessionLauncherPublicSurface|RouterSessionDirectoryEvent" 23 passed; full swift test: 2036 tests in 253 suites passed (9 known issues, all pre-existing withKnownIssue), plus 35 and 19 in the other targets.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/SessionLauncher.swift (new), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionDirectoryEventFanout.swift, Sources/FoundationModelsRouter/Session/SessionConfiguration.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/FakeSessionLauncher.swift (new), Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryEventTests.swift, Tests/FoundationModelsRouterPublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift (new)
    - next: /review
  timestamp: 2026-10-21T23:17:58.911914+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: doing
position_ordinal: '80'
title: 'ROUTER-8: SessionLauncher port, directory.useLauncher(_:), start(_:), and shutdown()'
---
## Goal
Add the `SessionLauncher` protocol that the host fills, so the directory can start a new root session and restore a recorded one without knowing the agent catalog or the tools of a session.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-8-session-launcher-port
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.4
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 13.3 and 14 (ROUTER-8; the ACPAgent side is ACPA-9, not planned here)

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionLauncher.swift`:
  ```swift
  public protocol SessionLauncher: Sendable {
      func launchRootSession(_ request: SessionStartRequest) async throws -> any RoutedSession
      func restoreSession(_ id: ULID) async throws -> any RoutedSession
  }
  ```
  Doc comment: the launcher resolves the folder (none: the folder of `startedBy`, AG-5) and the agent (none: the folder's `AGENT.md`, else the default agent, D71); an unknown agent throws `SessionDirectoryError.unknownAgent(_:nearNames:)`. Router stores only the resolved agent id (ROUTER-1).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`:
  - `public func useLauncher(_ launcher: any SessionLauncher)` and `public func shutdown()`, which releases the launcher (it breaks the run-time loop: the directory holds the launcher, the launcher makes surfaces that hold the directory) and finishes the open `events()` streams.
  - `start(_:)`: no launcher throws `.noLauncher`; else call `launchRootSession` with the request as it came (a nil agent and a nil folder stay nil). The returned session registers itself when `makeSession` vends it (registration card), and that registration sends the one `started` event. So the request's facts must be in the session before it registers: the launcher contract (doc comment) says the launcher copies `tags`, `title`, `startedBy`, `origin` and `requestedByClient` from the request into the `SessionConfiguration` it vends with. Add `requestedByClient: String?` to `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/SessionConfiguration.swift` (not persisted, like `hookOrigin`), and pass it to `register` so `started` carries it. `start` never sends a second `started`. If the returned session's facts lack a request fact (a launcher that broke the contract), `start` writes it with `updateFacts` and sends `factsChanged`; a session from another router is registered by `start` itself. Then deliver `request.firstMessage` as the first mail: `MailBody.agentMessage(from: startedBy, content:)` with sender `.session(startedBy)` when `startedBy` is set, else `.userMessage`. The first message starts a turn.
  - `restoreSession` is used by ROUTER-5 (a message to a recorded session); this card only adds the requirement.
- Fake launcher for tests: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/Helpers/FakeSessionLauncher.swift` (records each request, vends scripted-model sessions from a test router).

## Subtasks
- [x] Failing test first: with no launcher, `start(_:)` throws `noLauncher`.
- [x] Add the protocol, `useLauncher`, and `start`; a test that the fake launcher gets the request unchanged (nil agent stays nil).
- [x] The returned session is in the directory; exactly one `started` comes, and that event already holds the request's tags, title, `startedBy`, origin and `requestedByClient`; the first message starts a turn (the scripted model answers).
- [x] `shutdown()` releases the launcher (a weak reference to the fake becomes nil) and ends the open event streams.
- [x] Public surface test that conforms a type to `SessionLauncher` and calls `useLauncher` without `@testable`.

## Acceptance Criteria
- [x] `start` with no launcher throws `SessionDirectoryError.noLauncher`.
- [x] The launcher receives the request exactly as given.
- [x] The started session is live in the directory with the request's tags, title, `startedBy` and origin, and exactly one `started` event is sent.
- [x] The first message produces an answer in the new session.
- [x] After `shutdown()`, the directory holds no reference to the launcher.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift`
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterPublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift`
- [x] `swift test --filter "RouterSessionDirectoryLauncher|SessionLauncherPublicSurface"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api #hosting
---
assignees:
- claude-code
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: todo
position_ordinal: '8980'
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
- [ ] Failing test first: with no launcher, `start(_:)` throws `noLauncher`.
- [ ] Add the protocol, `useLauncher`, and `start`; a test that the fake launcher gets the request unchanged (nil agent stays nil).
- [ ] The returned session is in the directory; exactly one `started` comes, and that event already holds the request's tags, title, `startedBy`, origin and `requestedByClient`; the first message starts a turn (the scripted model answers).
- [ ] `shutdown()` releases the launcher (a weak reference to the fake becomes nil) and ends the open event streams.
- [ ] Public surface test that conforms a type to `SessionLauncher` and calls `useLauncher` without `@testable`.

## Acceptance Criteria
- [ ] `start` with no launcher throws `SessionDirectoryError.noLauncher`.
- [ ] The launcher receives the request exactly as given.
- [ ] The started session is live in the directory with the request's tags, title, `startedBy` and origin, and exactly one `started` event is sent.
- [ ] The first message produces an answer in the new session.
- [ ] After `shutdown()`, the directory holds no reference to the launcher.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterPublicSurfaceTests/SessionLauncherPublicSurfaceTests.swift`
- [ ] `swift test --filter "RouterSessionDirectoryLauncher|SessionLauncherPublicSurface"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api #hosting
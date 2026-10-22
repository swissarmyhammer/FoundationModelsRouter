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
- actor: claude-code
  id: 01m5gcm9y41mecdy83n05qp91q
  text: |-
    ### review — stuck
    - evidence: review sha HEAD~1..HEAD (bacbe2fe), counts 8 findings / 8 confirmed / 0 refuted, all swift/fluent-usage — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:239, :307, :322, :379; Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:48, :57; Sources/FoundationModelsRouter/RoutedLLM.swift:325; Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift:9. Conflict: RouterSessionDirectory.swift:239 (useLauncher(_:)), SessionLauncher.swift:48 (launchRootSession(_:)) and SessionLauncher.swift:57 (restoreSession(_:)) are signatures fixed word for word by FoundationModelsRouter/session.md 5.4 and FoundationModelsMultitool/session.md ROUTER-8, which ACPAgent (ACPA-9) implements; the rule demands labels the documented contract forbids. Recorded under "## Blocker (2026-10-21 18:19)" in the description. No finding fell on a later card (^axhfdx1, ^17nh345, ^4vjph7b, ^bn9fc99).
    - next: a person decides the three contract signatures (update the spec documents to the labeled forms, or correct the swift/fluent-usage rule), then /implement re-runs on all eight findings and /review re-runs.
  timestamp: 2026-10-21T23:27:03.620546+00:00
- actor: claude-code
  id: 01m5gcvvx3ce07993chj8d3q49
  text: |-
    Labeled the five swift/fluent-usage findings that the spec does not name ('Omit the first argument label only for value-preserving conversions.'): admit(session:startedFor:), isRegistered(session:), complete(facts:with:) in RouterSessionDirectory.swift; registerVendedSession(session:subagentParentID:requestedByClient:) in RoutedLLM.swift; the test helper AsyncStream.Iterator.next(count:) in SessionDirectoryEventReads.swift. Updated every call site and the DocC symbol links (``admit(session:startedFor:)``, ``complete(facts:with:)``), plus the next(count:) callers in RouterSessionDirectoryEventTests and RouterSessionDirectoryLauncherTests. I swept the commit's other new `_` first parameters: the rest are SessionLauncher conformances in FakeSessionLauncher and the public-surface test, which must match the contract signatures, so they stay as they are. Per the human instruction I left the three contract findings (useLauncher(_:), launchRootSession(_:), restoreSession(_:)) unchanged and unchecked; they still wait on the Blocker. Note: the files tool's replace_all flag replaced only the first match, so each identical call site needed its own edit.

    ### implement — changed
    - evidence: swift build --build-tests clean (the only warning is SwiftPM's 'missing creator for mutated node' for the mlx-swift_Cmlx bundle, which comes from the build system, not from code); swift test --skip-build --filter "RouterSessionDirectory|SessionLauncherPublicSurface" 48 tests in 5 suites + 2 tests in 1 suite passed, 0 failed. Files: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryEventTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift
    - next: a person decides the three contract signatures in the Blocker; then /review
  timestamp: 2026-10-21T23:31:11.395480+00:00
- actor: claude-code
  id: 01m5gcyb25d57mbggz3td3vfmh
  text: |-
    ### finish iteration 2 — stuck
    - implement: changed — 5 non-contract swift/fluent-usage findings fixed (RouterSessionDirectory.swift, RoutedLLM.swift, SessionDirectoryEventReads.swift and callers)
    - test: green — swift test, 2036/35/19 passed, 9 known issues
    - commit: 599f90fb
    - open: 3 swift/fluent-usage findings conflict with the documented SessionLauncher contract (session.md 5.4, Multitool session.md ROUTER-8): useLauncher(_:) RouterSessionDirectory.swift:239, launchRootSession(_ request:) SessionLauncher.swift:48, restoreSession(_ id:) SessionLauncher.swift:57 — needs a human to change the spec or correct the rule
  timestamp: 2026-10-21T23:32:32.453026+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: review
position_ordinal: '8880'
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

## Review Findings (2026-10-21 18:19)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [ ] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:239` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Providing a launcher is not a value-preserving conversion. Change signature to `public func useLauncher(launcher: any SessionLauncher)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:307` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Admitting a session is not a value-preserving conversion. Change signature to `private func admit(session: any RoutedSession, startedFor request: SessionStartRequest)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:322` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Checking if a session is registered is not a value-preserving conversion. Change signature to `private nonisolated func isRegistered(session: any RoutedSession)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:379` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Completing facts is not a value-preserving conversion. Change signature to `private static func complete(facts: inout SessionFacts, with request: SessionStartRequest)` to label the parameter.
- [ ] `Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:48` `swift/fluent-usage` — First parameter is unlabeled, but should be labeled: 'Omit the first argument label only for value-preserving conversions.' This method creates a session from a request, which is not a value-preserving conversion. Change signature to `func launchRootSession(request: SessionStartRequest) async throws -> any RoutedSession` to label the fundamental parameter.
- [ ] `Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:57` `swift/fluent-usage` — First parameter is unlabeled, but should be labeled: 'Omit the first argument label only for value-preserving conversions.' This method restores a session from an ID, which is not a value-preserving conversion. Change signature to `func restoreSession(id: ULID) async throws -> any RoutedSession` to label the fundamental parameter.
- [x] `Sources/FoundationModelsRouter/RoutedLLM.swift:325` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Registering a vended session is not a value-preserving conversion. Change signature to `private func registerVendedSession(session: any RoutedSession, subagentParentID: ULID?, requestedByClient: String?)` to label the first parameter.
- [x] `Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift:9` `swift/fluent-usage` — First parameter is unlabeled but should be labeled: 'Omit the first argument label only for value-preserving conversions.' Reading the next N events is not a value-preserving conversion. Change signature to `mutating func next(count: Int) async` to label the parameter.

## Blocker (2026-10-21 18:19) — rule fights a documented contract

Three of the findings above, all from `swift/fluent-usage` ("Omit the first argument label only for value-preserving conversions."), ask to relabel public API whose exact signatures are fixed by the written cross-package spec:

- `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:239` wants `useLauncher(launcher:)`. The spec says `directory.useLauncher(_:)`: /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.4, /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md (dependency-inversion bullet and ROUTER-8 Spec), and this card's title and What section.
- `Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:48` wants `launchRootSession(request:)`. The spec declares `func launchRootSession(_ request: SessionStartRequest) async throws -> any RoutedSession` in the same two session.md files.
- `Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:57` wants `restoreSession(id:)`. The spec declares `func restoreSession(_ id: ULID) async throws -> any RoutedSession` in the same two session.md files.

ACPAgent implements `SessionLauncher` against that spec (ACPA-9), so the rule and the documented contract cannot both be obeyed. A person must decide: change the spec documents (Router session.md 5.4, Multitool session.md ROUTER-8, this card) to the labeled forms, or correct the rule. The other five findings (RouterSessionDirectory.swift:307, :322, :379, RoutedLLM.swift:325, SessionDirectoryEventReads.swift:9) are private/internal or test-helper signatures the spec does not name; they are not part of this conflict.
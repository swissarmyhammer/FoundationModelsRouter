---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f4a1yk7s80x7ppb6zxrxkj
  text: |-
    ### decision — from foundationmodelsmultitool-bc (2026-10-21)
    - Name clash: EXTRAS-3 renames its origin enum to SessionDirectoryOrigin, so it doesn't clash with Hooks' SessionOrigin. Extras is checking every EXTRAS-3 type name (SessionState, SessionKind, ...) against Hooks and Router. Use the names EXTRAS-3 actually ships. The GraphQL SDL enum stays SessionOrigin.
  timestamp: 2026-10-21T11:42:24.723996+00:00
- actor: claude-code
  id: 01m5f8gga7fthhkz5vk28wyxwx
  text: |-
    Notes:
    - Does not use the parked SessionIndex: the query answers live sessions only; `includesRecorded` is not read yet.
    - Names as EXTRAS-3 ships them (bd34b20): `SessionDirectoryOrigin`, `SessionKind`, `SessionState`, `SessionSummary`, `SessionQuery` (limit default 20, includesRecorded default false). No Router type clashes with them.
    - `register(_:kind:parentID:)` and `unregister(_:)` are `nonisolated`, synchronous and internal (the vend-site card calls them from inside the module). The registry is `Mutex<[ULID: Entry]>` with `weak var session: (any RoutedSession)?`; dead entries are pruned on each query.
    - Field mapping as the card states it: nil agentID -> "default", nil origin -> `.client`, createdAt = ULID timestamp, updatedAt starts at createdAt (stored per entry for later cards), state `.idle`, isLive true. The card marks the nil mappings as awaiting spec-owner confirmation; that confirmation is still open.
    - Provisional bodies: start throws `.noLauncher`; addTags/removeTags/setTitle throw `.unknownSession(id)` (the card names the replacing card but not a provisional body; this matches archive); send gives one refused receipt "messages are not available yet"; inbox gives []; archive throws `.unknownSession`; events() is a finished stream. No test relies on them.
    - Manifest change: the public-surface test target now also depends on the `FoundationModelsExtras` product, because a consumer has to name the Extras `SessionDirectory` port and `SessionQuery`, and Router does not re-export them (re-exporting is a public API choice not on the card). The manifest comment is updated.
    - README lists no source folders, so it is unchanged; no ARCHITECTURE.md exists.
  timestamp: 2026-10-21T12:55:50.343312+00:00
- actor: claude-code
  id: 01m5f8gjrj3rwc3e660b7tvz5z
  text: |-
    ### implement — changed
    - evidence: Sources: Directory/RouterSessionDirectory.swift (new), Router.swift (`public nonisolated let sessionDirectory`). Package.swift (public-surface target links the Extras product). Tests: RouterSessionDirectoryQueryTests.swift (15 tests), PublicSurfaceTests/SessionDirectoryPublicSurfaceTests.swift (1 test). RED: build failed "value of type 'Router' has no member 'sessionDirectory'". GREEN: `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" note); full `swift test`: 1974 tests / 246 suites passed with 9 known issues; 29 / 17; 19 / 3.
    - next: review
  timestamp: 2026-10-21T12:55:52.850747+00:00
depends_on:
- 01M5F3DZXJ25NHD9NPCVCRNMCM
position_column: review
position_ordinal: '8380'
title: 'ROUTER-3: RouterSessionDirectory actor, router.sessionDirectory, and the live query'
---
## Goal
Add `RouterSessionDirectory`, the Router actor that conforms to the Extras `SessionDirectory` port, hold one in each `Router`, and answer `sessions(matching:)` and `summary(of:)` for the live sessions.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-extras.md#extras-3-session-directory-port
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md sections 3 and 5.2
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 6, 13.3, 14

## External dependency (do not start before it)
This card conforms to `SessionDirectory`. EXTRAS-3 is owned by session foundationmodelsextras-a8 in the FoundationModelsExtras repo and is not planned here. It must land on Extras `main`, and the Extras pin in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Package.resolved` must be updated to that revision (`swift package update FoundationModelsExtras`). If the ROUTER-1 card already moved the pin, confirm it still names the newest EXTRAS-3 revision.

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: `public actor RouterSessionDirectory: SessionDirectory`.
  - A live registry keyed by session id that holds each session weakly (a `Mutex`-guarded map of weak boxes, as `LanguageModelProfile.swift` does with `WeakProfile`), with its kind and parent id. The `register` and `unregister` entry points are `nonisolated` and synchronous, so the synchronous vend sites (`RoutedLLM.makeSession`) can call them in the next card.
  - `summary(of:)` and `sessions(matching:)` build a `SessionSummary` from the session's `nonisolated` properties (`id`, `parentId`, `workingDirectory`) and its `facts` (ROUTER-1). Filters: `workingDirectory`, `agentID`, `tag`, `kind`, `state`, `parentID`, `startedBy`; newest first (ULID order); then `limit`. Folders compare after `resolvingSymlinksInPath()` and with no trailing `/`.
  - The summary is built with no `await`: `session.facts` is `nonisolated` (ROUTER-1 vend card), so the synchronous `register` (and the `started` event of the events card) can build it.
  - Field mapping for the required `SessionSummary` fields: `agentID` nil (a session from before ROUTER-1) gives `"default"`; `origin` nil gives `.client`; `createdAt` is the time part of the session ULID; `updatedAt` starts at `createdAt` and moves to now on each facts or state change the directory makes; `isLive` is true. The nil mappings are a plan choice that the spec owner should confirm (see the plan questions).
  - Until ROUTER-9, a live session's state is `idle`.
  - The rest of the protocol gets provisional bodies that later cards replace: `start` throws `.noLauncher` (ROUTER-8); `send` gives one `refused` receipt with the reason "messages are not available yet" (ROUTER-4); `inbox` gives `[]` (ROUTER-4); `archive` throws `.unknownSession` (ROUTER-11); `addTags`/`removeTags`/`setTitle` (ROUTER-3 tags card); `events()` gives a finished stream (ROUTER-3 events card). No test relies on a provisional body.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Router.swift`: `public nonisolated let sessionDirectory: RouterSessionDirectory`, made in `init`.
- The directory is new structure in Router (a new `Directory/` folder). There is no `ARCHITECTURE.md` in this repo; update `README.md` only if it lists the source folders.

## Subtasks
- [ ] Failing test first: register two hand-built sessions (scripted model) and assert `sessions(matching: SessionQuery())` gives both, newest first.
- [ ] Add the actor, the weak live registry, and `router.sessionDirectory`.
- [ ] Each filter of `SessionQuery` (one test per field), the `limit`, and the folder comparison through a symbolic link and a trailing `/`.
- [ ] A released session (last strong reference dropped) leaves the live list: the directory does not keep it alive. Plus a test for the field mapping: nil agent gives `"default"`, nil origin gives `.client`, `createdAt` equals the ULID time.
- [ ] Public surface test: `router.sessionDirectory` used as `any SessionDirectory` without `@testable`.

## Acceptance Criteria
- [ ] `Router.sessionDirectory` exists and conforms to `SessionDirectory`.
- [ ] Each `SessionQuery` filter selects only matching sessions; results are newest first and cut to `limit`.
- [ ] `summary(of:)` gives `nil` for an unknown id.
- [ ] A session with no remaining strong reference is gone from the query (weak hold proven by a test).

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryQueryTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterPublicSurfaceTests/SessionDirectoryPublicSurfaceTests.swift`
- [ ] `swift test --filter RouterSessionDirectoryQuery` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api #blocked-external
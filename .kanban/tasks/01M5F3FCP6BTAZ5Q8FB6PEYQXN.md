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
depends_on:
- 01M5F3DZXJ25NHD9NPCVCRNMCM
position_column: todo
position_ordinal: '8480'
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
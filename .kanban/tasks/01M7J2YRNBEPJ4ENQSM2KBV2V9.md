---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j2zxh0zb71vap5jjwkvx8d
  text: |-
    ### design — decided by the orchestrator
    - Store the usage store in a `Mutex<(any SessionUsageStore)?>` (or in the `Registry`), so nonisolated paths read it. `public func use(usageStore: any SessionUsageStore)`; `shutdown()` does not need to release it (no cycle), but it can.
    - One helper `withUsage(_ summary: SessionUsage...) -> SessionSummary` that sets `pinnedAt` and `lastUsedAt` from the store. Apply it in `sessions(matching:)`, `summary(of:)`, `recordFactsChange(of:)` (factsChanged), `.started` in `register`, `changeRecord` emits, and the results of addTags/removeTags/setTitle.
    - `setPinned`/`markUsed`: find the session (live, else recorded; else throw `SessionDirectoryError.unknownSession`). Recording root: for a live `RoutedSessionActor` with `persistsIndex`, `session.recordingDirectory.deletingLastPathComponent()`; for a recorded session, the root whose folder holds it; a memory-only session gets nil root. Write the store, then emit `.factsChanged(summary)` only when the value changed (markUsed always changes the time). With no store: return the summary unchanged, send no event (same as Extras default).
    - Recording roots: a private `allRecordingRoots()` = host roots, then each distinct store root not already there. Use it in `recordedSummaries()` and `recordedFolder(of:)`.
    - `sessions(matching:)`: add `query.pinned.map { $0 == summary.isPinned }` to `matches`; apply `query.order` after the filter: `.newestFirst` id desc (current), `.pinOrder` pinnedAt ascending then non-pinned id desc, `.lastUsedFirst` lastUsedAt desc then unused id desc. Stable.
    - Update `Package.resolved` for FoundationModelsExtras to main (9d2804c or later; bc32820 is main now). See memory: stop the repo's sourcekit-lsp and use `--manifest-cache local` before `swift package update FoundationModelsExtras`.
    - Do NOT run swift format. ASD-STE100 comments.
  timestamp: 2026-11-16T11:48:30.880648+00:00
- actor: claude-code
  id: 01m7j7rzmbnyk2x69gxqmvh0z6
  text: |-
    Research done.
    - The .build checkout of Extras is at 65543a6. 9d2804c is an ancestor of it. Package.resolved is gitignored, so no change to Package.resolved is necessary.
    - Each live summary comes from `summary(of:in:)` under the registry lock (register `.started`, liveSummaries, liveSummary, recordFactsChange, takeArchived). Each recorded summary comes from `RecordedSessions.summary(of:)` (recordedSummaries, changeRecordedRecord). Plan: keep the store in `Registry`, give the live builder a `usage` parameter, and apply the usage to each recorded summary. Then each path (also archive and requireLiveSummary) carries pinnedAt and lastUsedAt.
    - `use(usageStore:)` reads the store one time before it keeps it, so the first file read of the JSON store does not occur under the registry lock.
    - `recordingRoots()` has 5 callers (recordedSummaries, recordedFolder, recordedChildren, firstPrompt, runStatuses). All of them change to `allRecordingRoots()`, so a session that the store root finds also answers the other calls.
    - Recording root of a live session: only a root session gives its root (the parent folder of its recording directory). A subagent or a fork folder can be inside the parent folder; that folder is not a recording root, and a recorded summary is only for a root session.
  timestamp: 2026-11-16T13:12:06.539880+00:00
- actor: claude-code
  id: 01m7j825y19zn6bz4hkszy6a4w
  text: |-
    ### implement — changed
    - evidence: 2 files. Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift (changed), Tests/FoundationModelsRouterTests/RouterSessionDirectoryUsageTests.swift (new, 18 tests). RED: 13 of the 18 tests failed before the code (the other 5 tests protect the no-store default, the unknown id, and the unpin). GREEN: `swift test --filter RouterSessionDirectoryUsageTests` gives 18 tests passed. Full `swift test` one time: 2766 tests in 324 suites passed, plus 42 and 19 tests in the other targets passed, exit 0. There are no compiler warnings. The one build warning is `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, from the build system for the mlx bundle, not from this change.
    - design: the store is in `Registry` under the one lock. The live summary builder has a `usage` parameter. Each recorded summary gets the usage through `recordedSummary(of:)` / `withUsage(_:_:)`. All 5 callers of the host roots now use `allRecordingRoots()` (the host roots, then the store roots that the host does not give, in path order). A live subagent or fork writes no recording root (nil keeps the root that the store holds).
    - next: review.
  timestamp: 2026-11-16T13:17:07.905695+00:00
- actor: claude-code
  id: 01m7j89hrsgdnn76e76hxdns6v
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a4e8411a); 1 finding (1 confirmed, 1 refuted) — Tests/FoundationModelsRouterTests/RouterSessionDirectoryUsageTests.swift:116 reuse/reuse
    - next: implement the finding. Move the session-closing helper `close(_:)` into the shared test helpers (Tests/FoundationModelsRouterTests/Helpers/). Call it from this suite and the four other directory suites. Parameterize a difference; do not add a fifth copy.
  timestamp: 2026-11-16T13:21:09.401934+00:00
- actor: claude-code
  id: 01m7j8c28n6vband1cwh9cf97y
  text: |-
    ### implement — changed
    - finding: `RouterSessionDirectoryUsageTests.swift:116` `reuse/reuse`. The shared helper is already in Tests/FoundationModelsRouterTests/Helpers/: `SessionFixtureLifecycle.close(_ sessions:opening:releasing:permits:)`. Its defaults are no gate and no semaphore, so `SessionFixtureLifecycle.close(sessions)` does the same as each private copy. Other suites (HumanWaitGateTests, CrossRouterResidencyTests, NestedGenerationReentryTests) already call it. I did not add a new helper, because a new helper would be one more copy.
    - removed the private `static func close(_:)` from 4 suites: RouterSessionDirectoryUsageTests, RouterSessionDirectoryRestoreTests, RouterSessionDirectoryEventTests, RouterSessionDirectoryRegistrationTests. Each `Self.close(...)` call now is `SessionFixtureLifecycle.close(...)`. Not changed: RouterSessionDirectoryArchiveTests `Fixture.close(_ session:)` (it also opens a latch, closes the launcher sessions and removes the folders) and the `fixture.close(_:)` of the Delivery and Message suites (other teardown). They are not copies.
    - evidence: `swift test --filter RouterSessionDirectory` gives 173 tests in 14 suites passed, exit 0. The 4 changed suites are named and pass. There are no compiler warnings (the one build warning is the mlx bundle `missing creator for mutated node`, the same as before).
    - next: review.
  timestamp: 2026-11-16T13:22:31.829521+00:00
- actor: claude-code
  id: 01m7j8dpq41vxz29ze9h5nrc7r
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (8358c700); 0 findings (0 confirmed, 0 refuted); all prior findings are checked
    - next: none. The task is in done.
  timestamp: 2026-11-16T13:23:25.540227+00:00
depends_on:
- 01M7J2YM7ZPJM6T6T2BMXZY1K7
position_column: done
position_ordinal: ffffffffff9e80
title: 'RouterSessionDirectory: use(usageStore:), setPinned, markUsed, pinned filter and order (ROUTER-3, D186)'
---
## What
- `RouterSessionDirectory.use(usageStore:)`, the same pattern as `use(launcher:)`.
- The real `setPinned(_:of:)` and `markUsed(_:)` write the store with the recording root of the session, and send `factsChanged`. With no store, they change nothing, as the Extras defaults.
- Each summary (`sessions(matching:)`, `summary(of:)`, the `started` and `factsChanged` events) gets `pinnedAt` and `lastUsedAt` from the store.
- `sessions(matching:)` filters by `query.pinned` and applies `query.order` (`newestFirst`, `pinOrder`, `lastUsedFirst`).
- The recording roots of the store join the recording roots of the host, so a recorded session that is not open after a restart is found.

## Acceptance criteria
- [x] `setPinned` and `markUsed` on a live and on a recorded session write the store and send one `factsChanged` with the new times.
- [x] `pinned: true` and `pinned: false` filter; `lastUsedFirst` and `pinOrder` order.
- [x] A new router with no recording roots of the host, but the same store, finds a recorded session with `includesRecorded`.
- [x] Router builds with Extras main 9d2804c or later.

## Tests
- `Tests/FoundationModelsRouterTests/RouterSessionDirectoryUsageTests.swift` #router-3

## Review Findings (2026-11-16 07:17)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryUsageTests.swift:116` `reuse/reuse` — The new static helper `close(_:)` repeats a session-closing helper that other directory test suites already define. It adds one more private copy instead of using a shared test helper. Move the helper into the shared test helpers (for example beside SessionDirectoryRouterPair in Tests/FoundationModelsRouterTests/Helpers/) and call it from this suite and the four others. If the helpers differ in what they close, parameterize the difference instead of adding a fifth copy.
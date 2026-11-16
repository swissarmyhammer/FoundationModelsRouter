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
depends_on:
- 01M7J2YM7ZPJM6T6T2BMXZY1K7
position_column: todo
position_ordinal: '8180'
title: 'RouterSessionDirectory: use(usageStore:), setPinned, markUsed, pinned filter and order (ROUTER-3, D186)'
---
## What
- `RouterSessionDirectory.use(usageStore:)`, the same pattern as `use(launcher:)`.
- The real `setPinned(_:of:)` and `markUsed(_:)` write the store with the recording root of the session, and send `factsChanged`. With no store, they change nothing, as the Extras defaults.
- Each summary (`sessions(matching:)`, `summary(of:)`, the `started` and `factsChanged` events) gets `pinnedAt` and `lastUsedAt` from the store.
- `sessions(matching:)` filters by `query.pinned` and applies `query.order` (`newestFirst`, `pinOrder`, `lastUsedFirst`).
- The recording roots of the store join the recording roots of the host, so a recorded session that is not open after a restart is found.

## Acceptance criteria
- [ ] `setPinned` and `markUsed` on a live and on a recorded session write the store and send one `factsChanged` with the new times.
- [ ] `pinned: true` and `pinned: false` filter; `lastUsedFirst` and `pinOrder` order.
- [ ] A new router with no recording roots of the host, but the same store, finds a recorded session with `includesRecorded`.
- [ ] Router builds with Extras main 9d2804c or later.

## Tests
- `Tests/FoundationModelsRouterTests/RouterSessionDirectoryUsageTests.swift` #router-3
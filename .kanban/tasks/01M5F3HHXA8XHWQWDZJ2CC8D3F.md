---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f65wkcmgwg1sbq3v966dvs
  text: |-
    ### decision — user (2026-10-21)
    - Recording roots: the host passes them in with directory.useRecordingRoots(_:), the same way it sets the launcher. Router reads no ACPAgent setting.
    - sessions.jsonl: RouterSessionDirectory appends a root session's line when that session registers. ACPAgent's own writer goes away in ACPA-14.
  timestamp: 2026-10-21T12:15:05.324104+00:00
- actor: claude-code
  id: 01m5ghm3wmpqc4kdmp4d3mepw6
  text: |-
    ### research — implement (picked up)
    - The user's decision comment answers both blocker questions, so this pass folds them into the card: `useRecordingRoots(_ roots: @escaping @Sendable () async throws -> [URL])` on RouterSessionDirectory, and the directory itself appends a root's `sessions.jsonl` line when that root registers (no ACPAgent-style manual append in the test).
    - Where to append: a vended root's recording directory is `<recordingRoot>/<id>/` or `<recordingsBase>/<routerId>/<id>/` (RoutedLLM.recordingDirectory(forSessionId:recordingRoot:)), so the index root is `recordingDirectory.deletingLastPathComponent()` — the same rule ACPAgent PromptExecution.makeFirstActivity uses.
    - Which sessions append: only a `RoutedSessionActor` whose `sidecarOrigin` is `.new` and `recordsFacts` (durable, level not `.off`), registered new as `.root`. Restored roots (`.restored`), forks, subagents and memory-only sessions append nothing, so the existing in-memory directory suites write no file.
    - The record: `cwd` = session.workingDirectory.path, `title` = facts.title ?? "", `updatedAt` = now, `additionalDirectories` = [] (the directory does not know them; ACPA-14 owns the ACP side).
    - `sessions.jsonl` is append-only and ACP resume appends a second line per session, so the reader keeps the last record of each session id.
    - Extras InMemorySessionDirectory: `summary(of:)` answers recorded sessions regardless of `includesRecorded`; the query filter is `includesRecorded || isLive`.
    - Logged warnings are testable with `TelemetryCapture.run(forbidding:)` (see SessionFactsRestoreTests).
  timestamp: 2026-10-22T00:54:20.308635+00:00
- actor: claude-code
  id: 01m5gjbvt6k9pew8jp6hg0e1rs
  text: |-
    ### implementation landed
    - New `Sources/FoundationModelsRouter/Directory/RecordedSessions.swift`: reads each root's `sessions.jsonl`, keeps the last record per session id, skips (warning) a record whose id is not a ULID or whose directory is gone, and builds a non-live `SessionSummary` from `session.json` + `facts.json` (kind root/subagent by `agentSpawn`, archived by `archivedAt`, title facts-then-record with empty = none, `updatedAt` = later of record and facts.json mtime). Also `appendIndexRecord(of:)`: the decision-2 writer, guarded to `RoutedSessionActor` with a `.new` sidecar origin that records facts.
    - `RouterSessionDirectory`: `useRecordingRoots(_:)`; `register` appends a root's line on its first registration only; `sessions(matching:)` merges live + recorded when `includesRecorded` (live wins); `summary(of:)` falls back to the recorded summary, as Extras' InMemorySessionDirectory does.
    - TDD: the RED runs failed on the expected assertions (memory-only and restored roots appending; summary fallback; last-record-wins; subagent kind; empty-title and ACPAgent-line title fallback; archived; facts mtime; missing directory). The ULID-skip guard was written slightly ahead of its test (to avoid a placeholder id), so its test passed on the first run.
    - Two existing tests asserted that a recording root holds only session folders; with decision 2 the root now also holds `sessions.jsonl` and `.gitattributes`. Updated `PerSessionRecordingRootTests` (no-leakage test now also checks each root's index lists only its own session) and `SessionSidecarTests` (recording-tree test) to match.
    - Added `Tests/FoundationModelsRouterPublicSurfaceTests/RecordingRootsPublicSurfaceTests.swift` (plain-import guard for `useRecordingRoots`, following the SessionLauncher surface test).
    - Not done here, on purpose: `additionalDirectories` is written as `[]` (the directory does not know them); ACPA-14 owns removing ACPAgent's writer and the root-set update on resume.
  timestamp: 2026-10-22T01:07:18.470043+00:00
- actor: claude-code
  id: 01m5gjc1ybkm2e3r3bmaw9jbzt
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean; `swift test --filter RouterSessionDirectoryRecorded` 17/17 pass; full `swift test` 2080 tests in 257 suites pass (9 known issues already in the suite), plus 35 + 19 in the other targets; `--filter RecordingRootsPublicSurface` 1/1 pass. Files: Sources/FoundationModelsRouter/Directory/RecordedSessions.swift (new), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecordedTests.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/RecordingRootsPublicSurfaceTests.swift (new), Tests/FoundationModelsRouterTests/PerSessionRecordingRootTests.swift, Tests/FoundationModelsRouterTests/SessionSidecarTests.swift
    - next: /review
  timestamp: 2026-10-22T01:07:24.747892+00:00
depends_on:
- 01M5F3EMARATMXFR829ZMNM17K
- 01M5F42DYA5TD84E9CYK176PRD
- 01M5F3FCP6BTAZ5Q8FB6PEYQXN
position_column: doing
position_ordinal: '80'
title: 'ROUTER-3: includesRecorded gives the root sessions on disk through SessionIndex, the sidecar and facts.json'
---
## Goal
With `SessionQuery.includesRecorded`, the directory also gives the root sessions that are on disk and not live, so a new process finds the sessions of an earlier process.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory ("on request, recorded sessions (on disk)"; "The directory also owns the record of past sessions")
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.2 (test: "With `includesRecorded`, a new process finds the sessions on disk through `SessionIndex`")
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 13.3 ("Recorded sessions")

## Decisions (user, 2026-10-21)
1. Recording roots: the host passes them in with `public func useRecordingRoots(_ roots: @escaping @Sendable () async throws -> [URL])` on `RouterSessionDirectory`, the same way it sets the launcher. Router reads no ACPAgent setting, and there is no port type (the spec rules out a `RecordedSessionCatalog` port).
2. `sessions.jsonl`: `RouterSessionDirectory` appends a root session's line when that session registers. ACPAgent's own writer goes away in ACPA-14.

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RecordedSessions.swift`: for each root, `SessionIndex(root:).read()`; for each record, the session directory's `session.json` (`SessionSidecar`: `workingDirectory`, `agentSpawn`) and `facts.json` (`SessionFacts`), giving a `SessionSummary` with `isLive == false`.
  - Scope: roots only. `sessions.jsonl` lists only root ACP sessions, whose folders sit directly under the root; forks and subagents are nested folders, which this card does not walk. A query with `kind: .fork` or `.subagent` gets no recorded result. (Walking the nested folders with `TranscriptTree` is a follow-up if the spec owner wants it.)
  - Kind `root` (`subagent` only if a root sidecar has `agentSpawn`). State `archived` when `facts.archivedAt` is set, else `idle`.
  - Title: `facts.title`, else `record.title` when it is not empty. `updatedAt`: the later of `record.updatedAt` and the `facts.json` modification date. `createdAt`: the ULID time. Nil agent and origin map as in the actor card (`"default"`, `.client`).
  - A record whose directory is gone is skipped, with a log warning.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: `useRecordingRoots(_:)`; `sessions(matching:)` merges live and recorded (a live entry wins over the recorded one with the same id), then filters, sorts and limits as before; `summary(of:)` falls back to the recorded summary.
- `RouterSessionDirectory.register(_:kind:parentID:requestedByClient:)`: a new durable root session (a `.new` sidecar origin that records facts) appends its `SessionIndexRecord` to `sessions.jsonl` in the folder that holds its recording directory (decision 2). A failed append is logged and does not fail the registration.

## Subtasks
- [x] Failing test first: router A vends and records two root sessions under one root, and its directory appends their `SessionIndexRecord`s at registration (decision 2); router B (a new instance, root from `useRecordingRoots`) with `includesRecorded: true` finds both with `isLive == false`; without it, finds none.
- [x] A registered new durable root appends one `sessions.jsonl` line; a fork, a subagent, a restored root and a memory-only root append none.
- [x] Add `RecordedSessions` with the kind, state, title and date rules above.
- [x] Add `useRecordingRoots(_:)` and the merge in `sessions(matching:)` and `summary(of:)`.
- [x] A recorded session with `archivedAt` has state `archived`; a missing session directory is skipped with a warning; a `sessions.jsonl` in the old ACPAgent format gives a summary with empty facts and the record's title.
- [x] Title precedence test: `facts.title` wins over `record.title`; an empty `facts.title` falls back.

## Acceptance Criteria
- [x] A second router instance finds the root sessions of the first through `SessionIndex` when `includesRecorded` is true, and only live sessions when it is false.
- [x] A session that is live and recorded shows once, as live.
- [x] Working folder, facts, title and `updatedAt` of a recorded summary follow the rules above.
- [x] A recorded archived session has state `archived`.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecordedTests.swift`
- [x] `swift test --filter RouterSessionDirectoryRecorded` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording
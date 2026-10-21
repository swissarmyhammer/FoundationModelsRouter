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
depends_on:
- 01M5F3EMARATMXFR829ZMNM17K
- 01M5F42DYA5TD84E9CYK176PRD
- 01M5F3FCP6BTAZ5Q8FB6PEYQXN
position_column: todo
position_ordinal: '8780'
title: 'ROUTER-3: includesRecorded gives the root sessions on disk through SessionIndex, the sidecar and facts.json'
---
## Goal
With `SessionQuery.includesRecorded`, the directory also gives the root sessions that are on disk and not live, so a new process finds the sessions of an earlier process.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory ("on request, recorded sessions (on disk)"; "The directory also owns the record of past sessions")
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.2 (test: "With `includesRecorded`, a new process finds the sessions on disk through `SessionIndex`")
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 13.3 ("Recorded sessions")

## Blocked on a spec decision (tag needs-decision)
1. Where the recording roots come from. The root of a project depends on the ACPAgent `transcripts.location` setting (`TranscriptLocation.recordingRoot(workingDirectory:name:userDirectory:)` and `Agent/RegisteredRecordingRoots.swift` in FoundationModelsACPAgent), which Router does not know. Proposed: the host gives the roots as plain data, `public func useRecordingRoots(_ roots: @escaping @Sendable () async throws -> [URL])` on `RouterSessionDirectory`, with no port type (the spec rules out a `RecordedSessionCatalog` port).
2. Who appends to `sessions.jsonl` after the move: the host (ACPAgent, as today, through the Router type) or the directory at each root registration.
Remove the tag and this section when both are answered.

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RecordedSessions.swift`: for each root, `SessionIndex(root:).read()`; for each record, the session directory's `session.json` (`SessionSidecar`: `workingDirectory`, `agentSpawn`) and `facts.json` (`SessionFacts`), giving a `SessionSummary` with `isLive == false`.
  - Scope: roots only. `sessions.jsonl` lists only root ACP sessions, whose folders sit directly under the root; forks and subagents are nested folders, which this card does not walk. A query with `kind: .fork` or `.subagent` gets no recorded result. (Walking the nested folders with `TranscriptTree` is a follow-up if the spec owner wants it.)
  - Kind `root` (`subagent` only if a root sidecar has `agentSpawn`). State `archived` when `facts.archivedAt` is set, else `idle`.
  - Title: `facts.title`, else `record.title` when it is not empty. `updatedAt`: the later of `record.updatedAt` and the `facts.json` modification date. `createdAt`: the ULID time. Nil agent and origin map as in the actor card (`"default"`, `.client`).
  - A record whose directory is gone is skipped, with a log warning.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: `useRecordingRoots(_:)`; `sessions(matching:)` merges live and recorded (a live entry wins over the recorded one with the same id), then filters, sorts and limits as before; `summary(of:)` falls back to the recorded summary.

## Subtasks
- [ ] Failing test first: router A vends and records two root sessions under one root, and the test appends their `SessionIndexRecord`s as the host does today; router B (a new instance, root from `useRecordingRoots`) with `includesRecorded: true` finds both with `isLive == false`; without it, finds none.
- [ ] Add `RecordedSessions` with the kind, state, title and date rules above.
- [ ] Add `useRecordingRoots(_:)` and the merge in `sessions(matching:)` and `summary(of:)`.
- [ ] A recorded session with `archivedAt` has state `archived`; a missing session directory is skipped with a warning; a `sessions.jsonl` in the old ACPAgent format gives a summary with empty facts and the record's title.
- [ ] Title precedence test: `facts.title` wins over `record.title`; an empty `facts.title` falls back.

## Acceptance Criteria
- [ ] A second router instance finds the root sessions of the first through `SessionIndex` when `includesRecorded` is true, and only live sessions when it is false.
- [ ] A session that is live and recorded shows once, as live.
- [ ] Working folder, facts, title and `updatedAt` of a recorded summary follow the rules above.
- [ ] A recorded archived session has state `archived`.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecordedTests.swift`
- [ ] `swift test --filter RouterSessionDirectoryRecorded` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording

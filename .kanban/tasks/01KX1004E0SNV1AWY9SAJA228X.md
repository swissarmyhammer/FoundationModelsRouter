---
assignees:
- claude-code
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
position_column: todo
position_ordinal: '8480'
title: 'Session index: sessions.jsonl fork manifest with fork baselines'
---
## What

Make the fork hierarchy first-class, queryable data instead of something implicit in directory nesting. One appended JSONL record per session, written at the two creation points that know the facts.

**New file** Sources/FoundationModelsRouter/Recording/SessionIndex.swift:
- `struct SessionIndexRecord: Codable, Sendable, Equatable` — `{sessionId: ULID, parentId: ULID?, path: String (recording directory relative to the router root), forkedAtEntryCount: Int (0 for roots; the parent's transcriptEntries().count at fork time for forks), slot: ModelSlot?, model: ModelRef?, instructions: String?, grammar: String? (the session's guided-generation grammar source, nil for unconstrained), createdAt: Date}`. `instructions`/`grammar` are recorded so tree restoration can rehydrate a restored `RoutedSessionActor`'s actor state (grammar changes the behavior of every future `respond`; it exists nowhere on disk today except implicitly on turn events).
- `actor SessionIndexWriter` — appends one JSON line per record to `recordings/&lt;routerId&gt;/sessions.jsonl`, best-effort with the same log-and-drop failure policy as `JSONLRecorder` (Sources/FoundationModelsRouter/Recording/Sinks.swift); plus a static `read(under:) throws -> [SessionIndexRecord]` decoder. `read(under:)` **dedupes by `sessionId` — first record wins**: the record appended at creation time is authoritative, and a session id is never legitimately re-appended (restore explicitly must not append; see the restore task), so any duplicate line is a bug elsewhere — but reads stay correct regardless of it.

**Wire-up:**
- Root sessions: at the vending site that constructs `RoutedSessionActor` (follow `RoutedModel.makeSession(instructions:workingDirectory:)` / `makeGuidedSession`), append a record with `parentId: nil`, `forkedAtEntryCount: 0`.
- Forks: in `RoutedSessionActor.fork(workingDirectory:)` (Sources/FoundationModelsRouter/Session/RoutedSession.swift) — `childId`, `parentId`, `childRecordingDirectory`, `instructions`, `grammar` are already in hand there, and the fork already holds the serial gate while reading the backend, so capture `backend.transcriptEntries().count` inside that same gated window as `forkedAtEntryCount`.
- Thread the writer down the same path the recorder already travels (Router -> handle -> session); recording level `off` writes no index (consistent with "no transcript file at off").

## Acceptance Criteria
- [ ] Every root session and every fork appends exactly one index record at creation
- [ ] Fork records carry the parent's entry count captured under the serial gate, plus inherited instructions/grammar
- [ ] `read(under:)` dedupes by `sessionId`, first record wins
- [ ] Index writes are best-effort: a forced write failure is logged and swallowed, never surfaced into fork/generation
- [ ] No sessions.jsonl is created at `RecordingLevel.off`
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit (new Tests/FoundationModelsRouterTests/SessionIndexTests.swift, using `StubSessionBackend`): root + two forks + grandfork produce 4 records with correct parentId chain and paths
- [ ] Unit: for an *uninstructed* stub session (no `.instructions` entry), a fork taken after 1 stub turn records `forkedAtEntryCount == 2` (prompt + response entries) — the test must state the uninstructed assumption so it does not collide with instructed-session entry counts
- [ ] Unit: a guided session's index record carries its grammar source; forks inherit it
- [ ] Unit: concurrent forks each append exactly one record (no lost/duplicated lines)
- [ ] Unit: a sessions.jsonl fixture containing two records with the same `sessionId` decodes via `read(under:)` to a single record — the first
- [ ] Unit: `RecordingLevel.off` leaves no sessions.jsonl on disk

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
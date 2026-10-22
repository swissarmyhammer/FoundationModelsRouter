---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5jcg5j61554eqnbgsjvjx2m
  text: |-
    Research (implement pickup):
    - Extras pin 447344d: `FrontmatterDocument<Metadata>.save(to:)` / `rendered()` (where Metadata: Encodable, throws FrontmatterDocumentSaveError; temp file + fsync + rename; folder must exist). Read side: `FrontmatterDocument.split(text:)` + `YAMLValue.parse(_:).decoded(as:)` — no Yams import needed in Router. `ISO8601JSON` is package-scoped in Extras, so Router codes frontmatter dates through the public `DateTime` (ms ISO 8601 text), as JSONLines does.
    - Writers today: actor init writes session.json (SessionSidecarOrigin.writeSidecarIfNew) and facts.json (writeFactsIfNew, RoutedSessionActor.swift:1037 = ^vcrnmcm finding); `updateFacts` rewrites facts.json and throws. Readers: TranscriptTree (discovers by session.json; recounts compactionCount from the transcript), MergedTranscript (schema check), SessionTreeRestoration (node.sidecar + SessionFacts.restored), RecordedSessions (interim listing), RouterSessionDirectory.ledgerDirectory (recordsFacts).
    - `SessionSidecar.AgentSpawn` is public API (SessionConfiguration.agentSpawn, TranscriptEvent.agentSpawn, RoutedLLM.makeSession) and is used by FoundationModelsAgents, FoundationModelsACPAgent and AgentViewKit tests/sources; it moves with the deleted type, so those packages need their own follow-up when they bump the Router pin.
    - Existing directory title API is `setTitle(_:of:)` (the Extras `SessionDirectory` protocol requirement), not `setTitle(_:for:)`; the card calls it "the existing" one, so the name stays `setTitle(_:of:)` (renaming means editing the Extras protocol, which this run must not do). Its body stays provisional per the dispatch: ^axhfdx1 implements it on the shared record-update path this card adds.
    - Fixtures with a session.json: Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording and Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording; both move to index.md.
  timestamp: 2026-10-22T18:03:16.934922+00:00
- actor: claude-code
  id: 01m5jdx8f78wdg0281d9q5epyb
  text: 'Progress (implement): production landed — SessionRecord (public Codable frontmatter: facts flat, listing data, restore data; dates via MillisecondDate = DateTime ms text; folders as paths under `cwd`/`additionalDirectories`), SessionIndexFile (read/save via Extras FrontmatterDocument, body kept byte for byte by re-reading it at save time; save into a missing folder throws), SessionIndexWriter (recordingLevel + root profile only) + SessionRecordSource (.new(facts)/.restored(record)). Actor holds `recordState: Mutex<SessionRecord>`; `updateRecord(_:)` is the one internal "change the record and save index.md" path (best effort: failed save logged, held value still changes) — `updateFacts` (now non-throwing) and directory `changeRecord(of:_:)` (live → updateRecord + factsChanged; recorded → read/change/save + factsChanged) sit on it for ^axhfdx1/^4vjph7b. First write is in makeRoutedSessionActor (`writeFirstIndex()`), init writes nothing. TranscriptTree discovers sessions by index.md (errors renamed indexMissing/indexUnreadable); compactionCount is now a record field, no recount. RecordedSessions lists index.md records; RouterSessionDirectory gained static `recordedSessions(in:) -> [SessionRecord]` and `setAdditionalDirectories(to:for:)`. RecordingSchemaVersion.implicit deleted; JSONLines moved to the test target. Decisions: `setTitle(_:of:)` keeps its existing name and its provisional body (dispatch: don''t implement ^axhfdx1''s features); restore writes nothing at construction — a restored session''s later changes rewrite its index.md. Next: tests migrated, RED observed for firstActivityAt/updatedAt and compactionCount before wiring the two hooks.'
  timestamp: 2026-10-22T18:27:54.471806+00:00
- actor: claude-code
  id: 01m5jgmrv59nr9yx2kh2wn87mh
  text: |-
    TDD record: SessionIndexFileTests red at compile (no SessionRecord/SessionIndexFile) before production; firstActivityAt/updatedAt tests (SessionIndexRecordingTests) observed red ("Expectation failed: held.firstActivityAt") and the live compaction test observed red (compactionCount → 0) before the two hooks were wired (beginSubmission → recordSubmissionStart(); compactTranscript after appending the checkpoint → recordCompactionCheckpoint()); then green. Fabricated-checkpoint restore test lost its compactionCount assertion (nothing live wrote that transcript; the count is a live write now). Notes for follow-ups: (1) FoundationModelsAgents / FoundationModelsACPAgent / AgentViewKit reference `SessionSidecar.AgentSpawn`, session.json and SessionFacts file I/O; they must move to `SessionRecord.AgentSpawn` / `RouterSessionDirectory.recordedSessions(in:)` when they bump the Router pin. (2) `recordedSessions(in:)` is a static func (usable with no router, e.g. ACPAgent snapshots); a client listing drops records with `firstActivityAt == nil`. (3) Live `setAdditionalDirectories` on a failed save logs and still returns/sends factsChanged (best effort, session goes on); the recorded not-live path throws the save error. (4) RecordCompactionFixture tool now redaction-scans `.md` + `.jsonl`.

    ### implement — changed
    - evidence: `swift build --build-tests` clean (no errors/warnings from Sources/Tests/Tools); `swift test`: 2104 tests in 259 suites passed (9 known issues, pre-existing), 35 + 19 passed. New: Recording/SessionRecord.swift, SessionIndexFile.swift, SessionIndexWriter.swift (was SessionSidecar.swift), MillisecondDate.swift, Session/RoutedSessionActorIndex.swift (was RoutedSessionActorFacts.swift); JSONLines moved to Tests/Helpers. Changed: SessionFacts, RoutedSessionActor(+Forking, +SubmissionEvents, +Compaction), RoutedLLM, Router, RouterTelemetry, TranscriptTree, MergedTranscript, SessionTreeRestoration, SessionRestoration, RecordingSchemaVersion, RecordedSessions, RouterSessionDirectory, SessionMessageLedger, doc-only sweeps; fixtures → index.md; tests migrated (SessionSidecarTests→SessionIndexTests, SessionFactsRecordingTests→SessionIndexRecordingTests, SessionFactsTests deleted, new SessionIndexFileTests, RecordedSessionsPublicSurfaceTests); session.md, generation-queue.md, UPSTREAM_ASKS.md, docc updated.
    - next: /review
  timestamp: 2026-10-22T19:15:42.053301+00:00
depends_on:
- 01M5HS4GB26B9S1XGRGV6WCCQT
position_column: doing
position_ordinal: '80'
title: 'ROUTER: index.md (frontmatter + open body) replaces session.json, facts.json and sessions.jsonl; sessions are listed by folder'
---
## What
User decisions (2026-10-22):
- Each recorded session folder holds one `index.md` instead of `session.json` plus `facts.json`.
- `sessions.jsonl` is eliminated. Sessions are listed by listing the recording root's folders and reading each `index.md`.

**Frontmatter holds:**
- **Facts:** agentID, agentName, origin, startedBy, tags, title, archivedAt.
- **Listing data**, formerly in sessions.jsonl: sessionId (the folder name), cwd (workingDirectory), updatedAt, additionalDirectories, the fork parent and its baseline (forkedAtEntryCount, forkedAtHistoryOrdinal), and `firstActivityAt`.
- **Restore data**, formerly the sidecar: model and profile, instructions, grammar, agentSpawn, routerId, configuration, recordingLevel, compactionCount.

**Body:** open-ended. Router never reads it and keeps it unchanged on every rewrite.

**Writes** go through the Extras FrontmatterDocument save (temp file, then swap). A failed save is logged and the session keeps working. The first write happens in `makeRoutedSessionActor`, not in the actor's init, which settles the ^vcrnmcm finding at RoutedSessionActor.swift:1037.

**Listing rule:** a session with zero prompts is not listed for ACP. Router sets `firstActivityAt` when the first submission starts. It is nil until then, and `updatedAt` moves on every submission. Listing helpers can filter on `firstActivityAt != nil`.

**API for hosts:**
- Title: the existing `directory.setTitle(_:for:)`.
- `RouterSessionDirectory.setAdditionalDirectories(to:for:)`, which rewrites index.md and sends factsChanged.
- `RouterSessionDirectory.recordedSessions(in:)`: lists a recording root's session folders and returns `[SessionRecord]` decoded from each index.md, with every frontmatter field above. ACPAgent's session/list, session/delete, session/resume and snapshots use this.
- `directory.sessions(matching:)` with `includesRecorded` reads the same records.

**No backward compatibility** (ARCHITECTURE.md): no reader for session.json, facts.json or sessions.jsonl, and no fallback.

This supersedes the file format of ^2my7et8, ^vcrnmcm and ^36a1y9n, and the sessions.jsonl part of ^2cc8d3f.

## Subtasks
- [x] One Codable frontmatter type replaces SessionSidecar's file and SessionFacts' file
- [x] TranscriptTree identifies a session folder by index.md
- [x] Vend, fork, restore, updateFacts, setTitle and setAdditionalDirectories write index.md; the first submission sets firstActivityAt; each submission moves updatedAt (setTitle: the shared `changeRecord(of:_:)` path is in place; its public body stays provisional for ^axhfdx1, per the dispatch)
- [x] `SessionRecord` and `recordedSessions(in:)`; RecordedSessions lists by folder
- [x] Delete the session.json and facts.json code and tests; update the docs and session.md
- [x] Failing tests first; `swift test` passes, zero warnings

Depends on the EXTRAS FrontmatterDocument save card.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j8fw5dg0w4b84s9v01sff1
  text: |-
    Research (implement pickup):
    - Extras JSONLFile (pin f64228a): `JSONLFile(url:)`, `append(_:) throws(JSONLFileError)` (O_APPEND|O_CREAT, one write, heals a torn tail with a leading "\n", fsync per line, folder must exist), `records(as:)` (skips an undecodable whole line with a warning, drops a torn tail with a warning, [] for a missing file), `latestRecords(as:)` + `JSONLKeyedRecord` fold. The `Calls` seam is internal to Extras, so Router cannot observe the fsync; Router's test seam is a line-append closure on JSONLRecorder whose production value is JSONLFile.append.
    - JSONLFile codes dates as ISO 8601 whole seconds (ISO8601JSON). transcript.jsonl (was JSONEncoder default, Double) and messages.jsonl (was default, full precision) lose sub-second precision of `ts` / `sentAt`. Consequence of the JSONLFile decision; tests that pinned sub-second sentAt change to whole seconds.
    - Listing source after SessionIndex goes: only `RecordedSessions.summaries()` (feeds sessions(matching:) includesRecorded, summary(of:), and send's restore resolution). inbox/message for a recorded session already read the folder directly (`recordedFolder(of:)`), and restore goes through the launcher by id. So RecordedSessions lists each root's ULID-named folders and reads session.json (optional) + facts.json.
    - ProjectRegistry also calls JSONLines.appendLine/replaceFile. The card deletes both and says JSONLFile is used everywhere, so ProjectRegistry moves onto JSONLFile with last-line-wins (`latestRecords`) until the ProjectStore card (^en1m? 01M5HT62MFG8TTD820716KEN1M) replaces it.
    - TranscriptTreeError.transcriptLineCorrupt and MergedTranscriptError (only case) go away with the throw-on-middle-line rule.
  timestamp: 2026-10-22T16:53:13.005775+00:00
- actor: claude-code
  id: 01m5j97yj4en1xm75vewa8nyv5
  text: |-
    Interim recorded listing (for ^2cqepsd to swap): `RecordedSessions` (Sources/FoundationModelsRouter/Directory/RecordedSessions.swift) now lists each recording root's entries — each entry that is a folder named by a ULID is a recorded root session (first root wins on a duplicate id; nested fork/subagent folders are not entries). `summary(of:in:)` reads that folder's `session.json` (optional; working folder falls back to the folder itself) and `facts.json` (optional), and `lastActivity(in:)` takes updatedAt from the newest mtime of session.json / facts.json / transcript.jsonl, else the ULID time. ^2cqepsd must swap exactly `summary(of:in:)` + `lastActivity(in:)` (and `activityFileNames`) for an index.md frontmatter decode (updatedAt from frontmatter, firstActivityAt filter); `sessionFolders(under:)` and the first-root-wins merge stay. No sessions.jsonl writer remains (RouterSessionDirectory.register no longer appends). inbox/message of a recorded session and restore never used the index (they read the folder / restore by id). session.md still describes SessionIndex in the ROUTER-3 plan text; ^2cqepsd owns the session.md update.
    Other decisions made while implementing: (1) ProjectRegistry also called JSONLines.appendLine/replaceFile, so it moved onto JSONLFile: a revisit appends a newer line (firstSeen carried), reads fold newest-line-wins (ProjectRegistryRecord: JSONLKeyedRecord); ProjectStore (01M5HT62MFG8TTD820716KEN1M) replaces it later. (2) JSONLFile dates are ISO 8601 whole seconds, so transcript ts and ledger sentAt lose sub-second precision on disk; RouterSessionDirectory now stamps sentAt at whole seconds (SessionMessageLedger.recordedInstant(of:)) so a restored inbox equals the delivered messages. (3) JSONLRecorder no longer caches handles: each event is one JSONLFile.append (open O_APPEND, heal torn tail, one write, fsync, close); test seam is `init(directory:now:appendLine:rootOwnership:)`. (4) Deleted: TranscriptLineDecoding, SessionIndex(+Record/ReadResult/Warning/Error), SessionMessageLedgerError, TranscriptTreeError.transcriptLineCorrupt, MergedTranscriptError, openHandleForAppending, appendJSONLine, TranscriptAppendHandle, JSONLAppendError, jsonlNewlineByte, JSONLines.replaceFile/appendLine/encodedLine, RouterTelemetry categories sessionIndex/projectRegistry/transcriptLineDecoding and LogMetadataKey.byteOffset.
  timestamp: 2026-10-22T17:06:21.892007+00:00
- actor: claude-code
  id: 01m5j9wwkwqhhqtvpx4sb1n0jv
  text: |-
    TDD record: RED observed before production code for — corrupt middle transcript line skipped with a warning (TranscriptTree + MergedTranscript, both threw transcriptLineCorrupt), append after a torn tail starts its own line (old append glued onto the torn bytes, event lost), ledger corrupt earlier line skipped (threw corruptLine), ProjectRegistry revisit appends a newer line (old rewrote to one line), durable root writes no sessions.jsonl and a recorded root lists from its folder (old listed only via sessions.jsonl). The per-event line-append spy test (`everyEventIsOneFlushedLineAppend`) uses the new `JSONLRecorder.init(directory:now:appendLine:rootOwnership:)` seam, so its red was a compile failure, not an observed run; the fsync itself is JSONLFile's contract (its Calls seam is internal to Extras) and the test proves every event, not only a submission close, is its own JSONLFile append. `anAppendOnlyGrowsTheTranscript` passes on old code too (FileHandle seekToEnd also only grew the file); the torn-tail test is the one that discriminates.
    Test fallout fixed (fixture format only, intent kept): 10 test files plus the PreRequestRenameRecording fixture transcript.jsonl wrote/read transcript lines with default JSONEncoder/JSONDecoder (Double ts); they now use JSONLFile / JSONLines coders and ISO 8601 ts. RouterSessionDirectoryMessageTests.theRecordReadsBackAfterTheTargetIsRestored exposed the sentAt precision loss; fixed in production by stamping sentAt at whole seconds.
  timestamp: 2026-10-22T17:17:48.028441+00:00
- actor: claude-code
  id: 01m5j9x1rh0ebq7vd3hstscrmg
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (no warnings from Sources/Tests); `swift test`: 2109 tests in 259 suites passed (9 known issues, pre-existing withKnownIssue), 33 + 19 passed. Sources: JSONLAppend, JSONLines, MergedTranscript, ProjectRegistry, Sinks, TranscriptTree, TranscriptFileDiscovery, RecordedSessions, RouterSessionDirectory, SessionMessageLedger, RouterTelemetry modified; SessionIndex.swift, TranscriptLineDecoding.swift deleted. Tests: 21 modified, SessionIndexTests, JSONLAppendTests, SessionMessageLedgerErrorPublicSurfaceTests deleted; PreRequestRenameRecording fixture transcript rewritten.
    - next: /review
  timestamp: 2026-10-22T17:17:53.297869+00:00
depends_on:
- 01M5HS4C6FBNTAX30161HP0BS5
position_column: doing
position_ordinal: '80'
title: 'ROUTER: transcript.jsonl goes through Extras JSONLFile; delete sessions.jsonl (SessionIndex) and the JSONL rewrite code'
---
## What
User decisions (2026-10-22):
- JSONL is append-only. Files open in append mode, each write is one full line, and every line is fsynced. One Extras type, `JSONLFile`, is used everywhere.
- `sessions.jsonl` is eliminated. Sessions are listed by listing the recording root's session folders and reading each `index.md` (see the index.md card).
- `projects.jsonl` becomes a folder with one file per project (see the ProjectStore card).

So the JSONL files Router writes are `transcript.jsonl` and, since ^17nh345, each session's `messages.jsonl`.
- `transcript.jsonl` (JSONLRecorder, appendJSONLine, openHandleForAppending) writes and reads through `JSONLFile`, with an fsync per line instead of only when a response finishes.
- `messages.jsonl` (`SessionMessageLedger`, ^17nh345) writes and reads through `JSONLFile` too; read marks stay appended records. Drop the shared `TranscriptLineDecoding` torn-tail code in favour of `JSONLFile`'s reader.
- Delete `SessionIndex`, `SessionIndexRecord`, `sessions.jsonl`, and the directory's sessions.jsonl writer from ed7b7c27. Recorded listing reads index.md instead.
- Delete `JSONLines.replaceFile`, `JSONLines.appendLine` and the seek-to-end FileHandle appends.
- No backward compatibility.
- Extras JSONLFile landed at e08f50d (user decision on the torn tail): the writer adds a missing "\n" before it appends; the reader skips a line that won't decode, with a warning, and never throws for one. Router follows the same rule: `SessionMessageLedgerError.corruptLine` and the transcript reader's "a corrupt middle line throws" go away, with their tests changed to expect a skip and a warning. Bump Router's pin with `swift package update FoundationModelsExtras` first.

## Subtasks
- [x] Move transcript.jsonl onto JSONLFile with an fsync per line
- [x] Delete SessionIndex and sessions.jsonl, and their tests; update RecordedSessions and the public-surface tests
- [x] Delete the JSONLines rewrite and append helpers
- [x] Failing tests first: a transcript append only grows the file, and each line is fsynced
- [x] `swift test` passes, zero warnings

Depends on the EXTRAS JSONLFile card.
---
assignees:
- claude-code
depends_on:
- 01M5HS4GB26B9S1XGRGV6WCCQT
position_column: todo
position_ordinal: '9780'
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
- [ ] One Codable frontmatter type replaces SessionSidecar's file and SessionFacts' file
- [ ] TranscriptTree identifies a session folder by index.md
- [ ] Vend, fork, restore, updateFacts, setTitle and setAdditionalDirectories write index.md; the first submission sets firstActivityAt; each submission moves updatedAt
- [ ] `SessionRecord` and `recordedSessions(in:)`; RecordedSessions lists by folder
- [ ] Delete the session.json and facts.json code and tests; update the docs and session.md
- [ ] Failing tests first; `swift test` passes, zero warnings

Depends on the EXTRAS FrontmatterDocument save card.
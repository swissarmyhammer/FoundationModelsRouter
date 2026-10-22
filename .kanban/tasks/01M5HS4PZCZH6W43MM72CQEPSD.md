---
assignees:
- claude-code
depends_on:
- 01M5HS4GB26B9S1XGRGV6WCCQT
position_column: todo
position_ordinal: '9780'
title: 'ROUTER: index.md (frontmatter + open body) replaces session.json and facts.json in each session folder'
---
## What
User decision (2026-10-22): each recorded session folder holds one `index.md` instead of `session.json` plus `facts.json`.
- **Frontmatter:** the facts (agentID, agentName, origin, startedBy, tags, title, archivedAt) and the restore data now in the sidecar (model and profile, instructions, grammar, workingDirectory, fork cut points, agentSpawn, routerId, configuration, recordingLevel, compactionCount).
- **Body:** open-ended. Router never reads it and keeps it unchanged on every rewrite.
- **Writes:** through the Extras FrontmatterDocument save (temp file, then swap). A failed save is logged and the session keeps working. The write happens in `makeRoutedSessionActor`, not in the actor's init (settles the ^vcrnmcm finding at RoutedSessionActor.swift:1037).
- **No backward compatibility** (ARCHITECTURE.md): no reader for session.json or facts.json, and no fallback. Old recordings stop restoring.

Supersedes the file format of ^2my7et8, ^vcrnmcm and ^36a1y9n. The behaviour stays: vend writes, restore reads, a fork writes its own, tags/title/archive rewrite it.

## Subtasks
- [ ] One Codable frontmatter type replaces SessionSidecar's file and SessionFacts' file
- [ ] TranscriptTree identifies a session folder by index.md
- [ ] Vend, fork, restore, updateFacts and the directory's recorded summaries use index.md
- [ ] Delete the session.json and facts.json code and tests; update the docs and session.md
- [ ] Tell ACPAgent: its TranscriptStore reads session.json
- [ ] Failing tests first; `swift test` passes, zero warnings

Depends on the EXTRAS FrontmatterDocument save card. #recording #session
---
depends_on:
- 01KXPEQZ7786N99AAWWZ15RWBE
position_column: todo
position_ordinal: '8280'
title: 'Recording layout v3: delete SessionIndex + RouterManifest, update docs'
---
Finish the normalization: with the sidecar write and read paths landed, remove the now-dead central-file machinery and record the new layout as the documented format.

**Remove**: `SessionIndexRecord` / `SessionIndexWriter` / `SessionIndex.read` (Recording/SessionIndex.swift), `RouterManifest` and the Router's manifest write path (Recording/RouterManifest.swift, Router.swift manifest plumbing), and any remaining `sessions.jsonl` / `manifest.json` constants — unless the read-side task decided to keep a legacy v2 read path, in which case keep only the read-side decoding types, clearly marked legacy.

**Docs**: update Router plan.md / README / DocC recording-layout sections to the v3 shape:

```
<recordingsDir>/<routerId>/
    <sessionId>/session.json        # write-once sidecar
    <sessionId>/transcript.jsonl    # append-only
    <sessionId>/<forkId>/...        # lineage = nesting
```

with the invariant stated explicitly: **nothing under recordingsDir is ever rewritten** — every file is write-once or append-only, so recordings are safe to check into git (the AgentHarness default is project-local, checked-in transcripts).

**Acceptance**: `swift build` + full test suite green with the types gone; grep for `sessions.jsonl`/`manifest.json`/`SessionIndexRecord`/`RouterManifest` finds only legacy-read code (if kept) and docs history.
---
comments:
- actor: claude-code
  id: 01kxr4f0h5rac5beyzggng7pde
  text: |-
    Picked up and verified: this card is FULLY SATISFIED by the landed sibling work (^zta2q14 / ^z15rwbe, commits 5cf5277 + 516d30d). No changes were needed; none were made.

    Verification performed (fresh, this session):

    **Removal half — done.**
    - `git log --diff-filter=D` confirms 5cf5277 deleted `Sources/FoundationModelsRouter/Recording/SessionIndex.swift`, `Sources/FoundationModelsRouter/Recording/RouterManifest.swift`, and `Tests/FoundationModelsRouterTests/SessionIndexTests.swift`.
    - Repo-wide grep over `Sources/` + `Tests/` for `sessions.jsonl` / `manifest.json` / `SessionIndexRecord` / `SessionIndexWriter` / `RouterManifest` / `SessionIndex`: **zero hits**. Clean break, no legacy v2 read path retained (matches the approved decision).

    **Docs half — done, and smaller than the card assumed.**
    - `plan.md` already documents the v3 layout (nested `session.json` + `transcript.jsonl`, lineage = nesting) and states the invariant explicitly: "every file on disk is therefore write-once (`session.json`) or append-only (`transcript.jsonl`), which is what lets a recording tree be checked in."
    - **There is no DocC catalog in this repo** (`find . -name '*.docc'` → empty), so there is no DocC recording-layout section to update.
    - **README.md has no recording-layout section and never had one.** It is a deliberately minimal 66-line library README (usage example / Install / Documentation / License). Its only recordings reference is `recordingsDir:` as a `Router(...)` constructor argument in the usage snippet — layout-agnostic and still correct. No `.md` in the repo mentions the v2 terms at all.

    Deliberately did NOT add a recording-layout section to README to "satisfy" the card — the card says update the recording-layout *sections*, and README's has never existed. Adding a disk-format spec would bloat a minimal library README and duplicate plan.md, which is the format's documented home.

    **Acceptance met:** `swift build` → exit 0, "Build complete!". `swift test` → exit 0, **360 tests in 39 suites passed** (+15 in 5 for the gated real-model target, skipped as expected), zero failures.

    Working tree has no source/doc diff — kanban bookkeeping only. really-done's adversarial double-check gate skipped per its contract (no code diff to critique). Leaving in `doing`.
  timestamp: 2026-07-17T13:32:42.405485+00:00
depends_on:
- 01KXPEQZ7786N99AAWWZ15RWBE
position_column: done
position_ordinal: c380
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
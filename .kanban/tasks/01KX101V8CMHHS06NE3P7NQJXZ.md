---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx6jxhj5eh8b7f9x460zayd2
  text: |-
    Implemented via TDD.

    New files:
    - Sources/FoundationModelsRouter/Recording/TranscriptTree.swift — `TranscriptTree` (load(under:), roots, session(_:), children(of:), events(forSession:), effectiveEntryEvents(forSession:)), `SessionNode`, `TranscriptTreeError`.
    - Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift — 13 tests, including a reusable `buildBranchingTree(profile:...)` fixture (root + two forks + one grandfork, configurable turn counts before/after each fork point) built for reuse by the later restore task's mandated integration test.

    Design notes:
    - `load(under:)` reads the index via `SessionIndexWriter.read(under:)` when `sessions.jsonl` decodes to at least one record; falls back to enumerating nested `transcript.jsonl` files (deriving id/parentId from each file's first event) whenever the index is missing OR present-but-empty (covers a dropped/partial index write, not just a missing file).
    - `effectiveEntryEvents(forSession:)` recurses: parent's effective entries (already recursively inherited) truncated to the node's own `forkedAtEntryCount`, then the node's own entries — verified against a grandfork scenario where both ancestors keep generating after their respective fork points.
    - `buildTree` promotes any node whose declared `parentId` doesn't resolve to another loaded node into `roots` (rather than silently dropping it and its subtree) — needed because a session that forks a child before ever generating writes no `transcript.jsonl` of its own, so the child's parent can be genuinely undiscoverable in fallback mode.
    - Added `TranscriptTreeError.parentUnresolvable` — a node with a non-nil but unresolvable `parentId` now throws from `effectiveEntryEvents` rather than silently returning just its own entries (this held even when `forkedAtEntryCount` happened to be known, e.g. an index whose parent's own line was dropped by the best-effort writer).

    Two rounds of adversarial double-check were run (per really-done); both surfaced real bugs before landing, all fixed and covered by new regression tests:
    1. Fallback silently dropped a fork whose own root never generated (fixed: buildTree promotes unresolvable-parent nodes to roots).
    2. `load(under:)` didn't distinguish a present-but-empty `sessions.jsonl` from a real zero-session index (fixed: fallback triggers on empty decoded records too, not just missing file).
    3. (surfaced on the second double-check pass) An orphaned node with a *known* `forkedAtEntryCount` silently returned partial data instead of failing loudly (fixed: added `parentUnresolvable` error, thrown before the `forkedAtEntryCount` check).

    Verification: `swift build --build-tests` exit 0, zero warnings/errors via LSP diagnostics. `swift test` — 285 unit tests pass (up from 282 baseline), gated integration suite correctly skipped (no `FM_ROUTER_INTEGRATION_TESTS`). New suite alone: 13/13 pass.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T17:58:58.885566+00:00
depends_on:
- 01KX0ZZ77H2DJAQJV4PW7DC1ZW
- 01KX100VJZ64Q7M3E5VQB9P7GS
- 01KX1004E0SNV1AWY9SAJA228X
position_column: done
position_ordinal: b680
title: 'TranscriptTree: session-id lookup and hierarchy-aware retrieval'
---
## What

The queryable read-side of the fork hierarchy: fetch any session's transcript directly by its `ULID`, and inspect the tree as data — no caller-side directory walking. **New file** Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:

- `struct TranscriptTree` with `static func load(under routerDirectory: URL) throws -> TranscriptTree` — reads `sessions.jsonl` via `SessionIndexWriter.read(under:)`, which dedupes records by `sessionId` (first record wins — see the session-index task), so even an accidentally duplicated index line can never yield duplicate `SessionNode`s or a corrupted tree. When the index is missing (pre-index recordings), falls back to enumerating nested `transcript.jsonl` files and deriving lineage from directory nesting + each file's event `parentId`, with `forkedAtEntryCount` unknown (documented: effective-transcript computation then throws a typed error for forks).
- `struct SessionNode`: `id`, `parentId`, `forkedAtEntryCount`, `directory: URL`, `children: [SessionNode]` (children ordered by ULID, i.e. creation order).
- APIs: `roots: [SessionNode]`, `session(_ id: ULID) -> SessionNode?`, `children(of id: ULID) -> [SessionNode]`, `events(forSession id: ULID) throws -> [TranscriptEvent]` (decodes only that session's own transcript.jsonl), and `effectiveEntryEvents(forSession id: ULID) throws -> [TranscriptEvent]` — the session's whole effective conversation: recursively, the parent's effective entry-kind events truncated to `forkedAtEntryCount` entries, followed by the session's own entry-kind events. Entry-kind means `instructions/prompt/toolCalls/toolOutput/response/reasoning` only — `session` meta and `embedding` events are router-side and excluded from the entry stream (the truncation count is in SDK transcript entries, matching the fork diff baseline).
- `MergedTranscript` (Sources/FoundationModelsRouter/Recording/MergedTranscript.swift) stays as-is — the flat whole-router view and the tree view coexist.

## Acceptance Criteria
- [ ] Lookup by session ULID works without the caller knowing any directory path
- [ ] `effectiveEntryEvents` for a grandfork equals root-entries-up-to-fork1 + child-entries-up-to-fork2 + grandfork's own entries, even when ancestors kept generating after the forks
- [ ] The tree (roots, children, parent links) is exposed as data and matches the index
- [ ] An index containing a duplicated record for one session still yields exactly one node for it (via the deduped `read(under:)`)
- [ ] Index-less fallback still yields the correct tree shape and per-session events
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] New Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift: build a 3-level branching tree on disk via Router + StubSessionBackend (root with two children, one child with its own child); assert lookup, children ordering, and tree shape
- [ ] Unit: effective entries cut correctly at each `forkedAtEntryCount` when parents continued after forking
- [ ] Unit: a hand-written sessions.jsonl with a duplicated sessionId line loads to a tree with one node for that session, using the first record's fields
- [ ] Unit: fallback path (delete sessions.jsonl, reload) reproduces tree shape; `effectiveEntryEvents` on a fork throws the documented typed error
- [ ] Unit: `session` meta and `embedding` events never appear in `effectiveEntryEvents`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
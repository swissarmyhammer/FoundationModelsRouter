---
assignees:
- claude-code
depends_on:
- 01KX0ZZ77H2DJAQJV4PW7DC1ZW
- 01KX100VJZ64Q7M3E5VQB9P7GS
- 01KX1004E0SNV1AWY9SAJA228X
position_column: todo
position_ordinal: '8780'
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
---
assignees:
- claude-code
depends_on:
- 01KX102FWSNR12B9TK5DW0ZX8K
- 01KX10HEZ76ZJJHTQTZBKHJ6YA
- 01KX1004E0SNV1AWY9SAJA228X
position_column: todo
position_ordinal: '8980'
title: Restore a session tree from disk by root session id
---
## What

The end-to-end restore capability. Restoration is rooted at the **root session id** — callers never restore an individual fork; given a root's `ULID`, a fresh `Router` reconstructs the entire fork tree (root + every descendant) as live, usable sessions, synced with what is on disk. The `makeSession(transcript:)` backend seam is its own prerequisite task and is NOT in scope here.

- **Restore API** on the session-vending surface (follow how `RoutedModel.makeSession` is exposed; e.g. `restoreSessionTree(root: ULID, registry: CustomSegmentRegistry = CustomSegmentRegistry()) async throws -> RestoredSessionTree`): loads `TranscriptTree` from the router's recording root, requires the id to be a root (typed error otherwise), computes each node's `effectiveTranscript(forSession:registry:)` (the `registry` is threaded through so recordings containing custom segments restore when the integrator has registered their `PersistableCustomSegment` types), seeds one backend per node via `LoadedLLMContainer.makeSession(transcript:)`, and constructs `RoutedSessionActor`s preserving each node's original `id`, `parentId`, and `recordingDirectory` so continued turns append to the same on-disk tree. Each restored session's `persistedEntryCount` starts at its reconstructed entry count so continued generation persists only genuinely new entries. `RestoredSessionTree` exposes the root session and child lookup mirroring `TranscriptTree`'s shape.
- **No session-index re-append:** restoration must NOT write any new `sessions.jsonl` records — the index already contains every node's record from when the tree was originally created (root vend + each fork), and restored actors must be constructed through a path that bypasses the index-append performed at normal vend/fork time. A brand-new fork taken *from* a restored session afterwards appends normally, exactly like any other fork. (The index reader's first-record-wins dedupe is a separate defensive layer, not a license to re-append.)
- **Model/slot resolution contract:** each node's `SessionIndexRecord.slot`/`model` selects the container from the restoring Router's resolved profile. Typed errors, not crashes, when: the index record has `nil` slot/model, the recorded slot is absent from the new Router's profile, or the recorded model does not match the resident model for that slot (error names the session id and the mismatch).
- **Instructions/grammar rehydration:** restored actors take `instructions` and `grammar` from their `SessionIndexRecord` (recorded by the session-index task) — a restored guided session must constrain its next turn exactly as the original did; the transcript's own `.instructions` entry carries instructions into *generation*, the index carries them into *actor state*.
- Restored sessions share the model's normal `serialGate`/fork gates; restoring does not consume fork-admission permits (document why: admission bounds in-flight *new* forks; restored sessions are reconstructions of already-admitted ones).

## Acceptance Criteria
- [ ] `restoreSessionTree` accepts only root ids and rebuilds the full descendant tree with original ids, parent links, and recording directories
- [ ] Restoring a session tree from disk appends zero new session-index records — the index already has them from when the tree was originally created
- [ ] A restored session's next turn appends to its existing transcript.jsonl without re-persisting restored history
- [ ] A restored guided session applies its recorded grammar on its next turn
- [ ] Slot/model mismatches and non-root ids produce the documented typed errors
- [ ] Works with stub containers (unit-testable) and the live MLX container (integration)
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit (stub-backed): record root + 2 children (one with its own child), tear down, restore by root id, assert tree shape, per-node entry sequences, and that a new stub turn on a restored fork persists only the new delta
- [ ] Unit: sessions.jsonl is byte-identical (same line count and records) before and after `restoreSessionTree`; a subsequent *new* fork of a restored session appends exactly one record
- [ ] Unit: restoring by a non-root id throws; restoring against a Router whose profile lacks the recorded slot throws the mismatch error
- [ ] Unit: a restored guided session's next turn goes through the guided path with the recorded grammar
- [ ] Gated integration (`FM_ROUTER_INTEGRATION_TESTS`, in Tests/FoundationModelsRouterIntegrationTests/, matching the `.enabled(if:)` pattern of LanguageModelSessionBackendTests.swift), end to end: (1) start a Router, make a root session, drive a real `respond(to:)` turn carrying a memorable fact; (2) fork the root twice and fork one child again — a genuine branching, 3-level tree — driving a real turn on each fork; (3) assert mid-test, before teardown, that each session's transcript.jsonl on disk already contains its turn's entry events (sync-as-they-happen, not only at the end); (4) discard the Router and all session references; (5) construct a **new** Router over the same recordings directory (fresh process simulation); (6) restore passing only the root session's id; (7) assert the restored tree matches — structure, each node's own recorded turns, and an unchanged sessions.jsonl — and drive a **new live turn** on a restored node asking for the earlier fact, asserting the response recalls it (the `LanguageModelSession(transcript:)` seed behaves indistinguishably from a never-torn-down session)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx6sbt2rcd1cyw80pcdrc2np
  text: |-
    Implemented restoreSessionTree(root:registry:) end-to-end.

    New production file: Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift
    - `SessionTreeRestorationError` (notARootSession, noDurableRecordingsRoot, missingSlotOrModel, slotNotInProfile, modelMismatch)
    - `RestoredSessionTree` (root, session(_:), children(of:) — mirrors TranscriptTree's shape)
    - `RoutedModel.restoreSessionTree(root:registry:)` extension (declared where Container == any LoadedLLMContainer, same declaration site as makeSession) — internally resolves the owning LanguageModelProfile via owningProfileBox.current and picks .standard/.flash per node from that node's own SessionIndexRecord.slot (not necessarily the calling handle's own slot), so calling via profile.standard or profile.flash both work identically. Reads TranscriptTree.load(under:) for tree shape/effectiveTranscript and SessionIndexWriter.read(under:) separately for slot/model/instructions/grammar/path, joined by sessionId. Constructs each RoutedSessionActor via the existing makeRoutedSessionActor(...) helper with persistedEntryCount: transcript.count, holdsAdmissionPermit: false (restoring never consumes a fork-admission permit), indexPath: record.path, and the node's own sessionIndexWriter (so a later real fork off a restored session appends normally). Never calls SessionIndexWriter.append — sessions.jsonl is untouched by restoration.

    Tests:
    - Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift — 6 stub-backed unit tests: tree-shape + per-node effective entry counts + no-re-persist-on-new-turn, sessions.jsonl byte-identical + exactly-one-new-record after a later fork, non-root-id typed error, model-mismatch typed error, slot-not-in-profile typed error (fabricated .embedding-slot record), restored guided session uses its recorded grammar on its next turn.
    - Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift — the mandated gated end-to-end test (FM_ROUTER_INTEGRATION_TESTS, .enabled(if:) pattern matching LanguageModelSessionBackendTests.swift): drives a real root turn carrying a memorable fact, forks the root twice and forks one child again (3-level branching tree) with a real turn on each, asserts mid-test that transcript.jsonl already has entries, discards everything (all router/profile/session refs scoped inside a private `driveOriginalTree` helper so they go out of scope), builds a brand-new Router with the *same* id over the same recordingsDir (simulating a fresh process), restores by root id alone, asserts structure/turn-counts/unchanged sessions.jsonl match, and drives a new live turn on the restored *grandfork* (deepest node) asking for the earlier fact — asserting the reply recalls it.

    Verified RED/GREEN on the core invariant: temporarily set persistedEntryCount to a hardcoded 0 in the implementation, confirmed the stub unit test "restoring a 4-node tree..." failed for the expected reason (re-persisted inherited history), then reverted and confirmed green again.

    swift build --build-tests: exit 0, no diagnostics.
    swift test: 300/300 unit tests pass; 13 gated integration tests skip cleanly (no FM_ROUTER_INTEGRATION_TESTS env var / no GPU in this sandbox) including the new gated suite, which at least compiles.

    Review engine flagged 3 findings, all "Id should be ID" acronym-casing (recordsById, forkBId, childIds) — waived per the existing acronym-casing-convention memory, which explicitly covers the codebase's established ...Id style (routerId/sessionId/parentId) as intentional, not just RAM/JSON/LLM.

    One known, documented simplification: grammar rehydration reconstructs SessionIndexRecord.grammar (a bare source string) as `.jsonSchema(source)` always, never `.ebnf`, since the on-disk record doesn't distinguish the two Grammar cases. This matches reality: the live MLX backend (LiveModelLoader.swift) already unconditionally rejects `.ebnf` via GuidedRequestError.ebnfNotSupportedByLanguageModelSession, so an .ebnf-sourced guided session could never have driven a real turn in the first place — .jsonSchema is the only grammar case that is ever actually restorable/usable live.

    Running the double-check adversarial review now before handoff.
  timestamp: 2026-07-10T19:51:37.816809+00:00
- actor: claude-code
  id: 01kx6tn3190k8kynjwwdq5nrr7
  text: |-
    Adversarial double-check (round 1) found one real, legitimate finding: the doc comment claimed restored grammars constrain their next turn "exactly as the original did," but SessionIndexRecord.grammar (an already-landed, already-reviewed sibling task's schema — 01KX1004E0SNV1AWY9SAJA228X) only persists the bare source string, not which Grammar case it came from, so a session originally guided by .ebnf(...) silently restores as .jsonSchema(source).

    Resolution applied (not a heuristic guess, not a schema change to the sibling task): corrected the restoreSessionTree doc comment with an explicit "Known limitation: the .ebnf grammar case" section, added an inline code comment at the coercion site, and added a new unit test (restoredEbnfGrammarReconstructsAsJSONSchema) that creates a real .ebnf-guided session, restores it, and asserts the exact known-limitation behavior (.jsonSchema(source), not .ebnf(source)) so it's documented AND locked in by a test rather than silently unverified. Chose this over a JSON-parseability heuristic (would reintroduce silent guessing the codebase's own conventions reject) or extending SessionIndexRecord's on-disk schema (would mean reopening an already-done, already-reviewed sibling task this one only depends on). Zero live-path impact either way: LiveModelLoader already unconditionally rejects .ebnf via GuidedRequestError.ebnfNotSupportedByLanguageModelSession, so no .ebnf-guided session could ever have driven a real turn to restore in the first place.

    Adversarial double-check round 2 (bounded re-check) verdict: PASS — confirmed the new test is faithful (uses the real makeGuidedSession(.ebnf(...)) path, not a fabricated record), confirmed the doc comment is accurate against the actual code and against LiveModelLoader's real .ebnf rejection, and confirmed the resolution is proportionate given the constraints.

    Final fresh verification: swift build --build-tests exit 0; swift test — 301/301 unit tests pass (0 failures), 13/13 gated integration tests (including the new mandated end-to-end SessionTreeRestorationIntegrationTests suite) skip cleanly with no FM_ROUTER_INTEGRATION_TESTS env var / no GPU in this sandbox, exactly matching this target's existing convention for gated suites. LSP diagnostics on the working diff: 0 errors, 0 warnings.

    Task is done and green. Leaving in `doing` for /review per the implement skill (not moving to review myself).
  timestamp: 2026-07-10T20:14:10.473458+00:00
depends_on:
- 01KX102FWSNR12B9TK5DW0ZX8K
- 01KX10HEZ76ZJJHTQTZBKHJ6YA
- 01KX1004E0SNV1AWY9SAJA228X
position_column: doing
position_ordinal: '80'
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
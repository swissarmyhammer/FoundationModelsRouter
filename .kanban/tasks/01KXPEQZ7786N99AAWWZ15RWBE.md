---
comments:
- actor: claude-code
  id: 01kxptyhh7spy086fmrf02y8xd
  text: |-
    Subsumed by ^zta2q14 and implemented there, at the user's explicit direction (they were asked and chose to merge): the write side could not land green on its own, because removing `SessionIndexWriter` breaks this card's two readers (`TranscriptTree.load`, `restoreSessionTree`) in the same commit.

    Everything in this card's scope is done on ^zta2q14's branch:
    - `TranscriptTree.load(under:)` builds the tree from directory nesting + each session directory's `session.json` — no `sessions.jsonl` read; `SessionNode` carries its `sidecar`.
    - `restoreSessionTree` rehydrates slot/model/instructions/grammar from each node's own sidecar (`SessionTreeRestorationError.missingSlotOrModel` deleted — a sidecar's slot/model are non-optional).
    - Error cases became sidecar-specific and name the exact directory: `sidecarMissing(directory:)`, `sidecarUnreadable(directory:)`, `sessionDirectoryNotIdentified(directory:)`, `forkCutPointMissing(session:directory:)`.
    - **Compatibility decision made:** clean break. No legacy v2 (`sessions.jsonl` + `manifest.json`) read path — no shipped consumers.
    - Acceptance covered by tests: round-trip record→reconstruct→restore, fork cut point honored from the sidecar, and a deliberately deleted sidecar producing a loud, specific error instead of silent truncation.

    One consequence worth knowing: `makeLanguageModel(resuming:)` now nests its handle under the resumed session's directory, since nesting is what states lineage.

    Close this card when ^zta2q14 lands. Leaving the column move to the reviewer/orchestrator rather than marking it done from an uncommitted tree.
  timestamp: 2026-07-17T01:27:11.143307+00:00
depends_on:
- 01KXPEQ94N516K0QFB3ZTA2Q14
position_column: done
position_ordinal: c280
title: 'Recording layout v3: TranscriptTree + restoreSessionTree read sidecars (read side)'
---
Switch the read/reconstruction path to the per-session `session.json` sidecars introduced by the write-side task.

**Change.** `TranscriptTree.load(under:)` builds the session tree from the directory nesting (lineage), session-directory ULID names (identity + creation order), and each directory's `session.json` (slot, model, context, instructions, grammar, forkedAtEntryCount) — no `sessions.jsonl` read. `restoreSessionTree` rehydrates each node's model/slot/instructions/grammar from its own sidecar instead of a SessionIndexRecord. The `forkedAtEntryCountUnknown` / index-line-dropped error cases become "sidecar missing/undecodable" errors naming the exact session directory.

**Compatibility decision to make in the PR**: whether `TranscriptTree` keeps a legacy read path for v2 layouts (`sessions.jsonl` + `manifest.json`) or the family declares a clean break (no shipped consumers yet; the harness plan only requires read-side tolerance somewhere — if Router keeps the legacy read path, the harness needs nothing).

**Acceptance**: round-trip test — record a root + fork tree with the new writer, reconstruct via TranscriptTree, restore via restoreSessionTree, transcripts and actor state identical to pre-change behavior; fork cut point honored from the sidecar; a deliberately deleted sidecar produces a loud, specific error rather than silent truncation.
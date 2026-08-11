---
assignees:
- claude-code
depends_on:
- 01KZR9YPHRGDCZ26R5BH1008KB
- 01KZR9Z6QH9WVXVSX9T6Z1MSG1
- 01KZRAH9TQCGSJYTENYXSGJNEY
position_column: todo
position_ordinal: '9480'
title: 'Restore fidelity tests: rich content, multi-fold, driven forks'
---
## Problem

The always-run test suite proves restorability only for stub text turns and only structurally:

1. **Rich content never traverses the full disk path.** Only text `.prompt`/`.response` entries go recorder -> JSONL -> `effectiveTranscript` (TranscriptReconstructionTests' backend appends text only, Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift:106-165). No tool turn, `.reasoning` entry, `.structure` segment, attachment, or `.custom` segment ever makes the round trip through disk.
2. **Mapper equality gaps.** `.structure`, `.attachment` (URL-backed), and `.custom` segments have no equality-level round trip — tests cherry-pick fields (TranscriptEntryMapperTests.swift:184-205, :457-488, :227-247). No entry with multiple or mixed segments goes through the mapper. No multi-call `.toolCalls` round trip.
3. **Multi-fold restore** is tested only with hand-fabricated checkpoint events (TranscriptReconstructionTests.swift:915-974). No test folds a live session twice and restores it.
4. **Driving a restored fork** is proven semantically in exactly one gated integration assertion (`reply.contains("42")`, Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift:355), skipped by default.

## Proposed solution

Add always-run tests (stub/scripted backends, no GPU):

1. Drive a scripted tool turn (multi-call, with a `.structure` output segment and a `.reasoning` entry) through a real session, restore from disk, and assert entry-array equality against the live backend transcript — the same `Array(reconstructed) == backend.transcriptEntries()` check the text tests already use.
2. Add mapper round-trips with full `Transcript.Entry` equality for: an entry with mixed segments, a multi-call `.toolCalls`, a URL-backed attachment, and a registered `.custom` segment.
3. Fold a live session twice (scripted summarizer), restore, and assert the restored transcript equals the live post-second-fold transcript. This test runs against the fixed checkpoint semantics (tasks ^h1008kb and ^6z1msg1).
4. Drive a restored fork with a scripted model whose script proves continuity (the reply depends on an entry inherited from the parent), so the semantic continuation claim no longer lives only behind the integration gate.

## Acceptance

- All four test groups run in the default (ungated) suite and pass.
- At least one test asserts full entry-array equality for a transcript containing all six entry kinds. #transcript
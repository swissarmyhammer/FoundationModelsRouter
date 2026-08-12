---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kztt15x7hwjk1k4b5dbk6q0w
  text: |-
    Research findings, one decision for each item:

    1. agentSpawn — there is no live state to restore. `RoutedSessionActor.init` uses the `agentSpawn` parameter only for the sidecar write; it does not store it (the init doc says so). `RoutedSession` has no agentSpawn property. The recorded fact stays on disk and stays readable through `TranscriptTree` (`SessionNode.sidecar.agentSpawn` and the configuration envelope). Decision: document the non-loss in the restore doc, add a pinning test. Do not delete the sidecar field (public API, additive only; browsers read it).

    2. Context — restore uses `routedLLM.resolution.contextTokens` and ignores `sidecar.context`. Decision: report a typed per-session mismatch on the restore result (new `RestoredSessionTree.contextMismatches`), not an error. Reason: the live resolution is the true capacity of the loaded backend, so restore with the live value is correct for future turns; a hard error would refuse a restore that works (for example after a RAM or ladder change). The caller must learn that the contextFill denominator changed.

    3. Deleted fork directory — the directory layout is the only structure on disk. A deleted child directory is byte-identical to a child that never existed, so no reader can detect it. A missing PARENT is detectable (a child nests under a non-session directory) and throws `sidecarMissing`. Decision: document the asymmetry in `TranscriptTree.load(under:)` and add a test.

    4. Corrupt CompactionSegment — the `try?` in `compactionSegmentContent(in:)` only affects checkpoint FILTERING. The mapper rebuilds the same segment through `CustomSegmentRegistry.rebuildSegment`, which throws `invalidJSON` -> `entryReconstructionFailed` at full level (`contentRemoved` when stripped). So restore fails loudly; it never silently restores as uncompacted. The card's claim was stale. Decision: keep nil-not-throw, extend the doc comment with the corruption case, pin with a test.

    5. Corrupt OperationEventSegment — same mechanism. `restoreSessionTree` calls `effectiveTranscript` BEFORE `lostRunTerminalEvents`, and `OperationEventSegment` is registered in `CustomSegmentRegistry.routerDefault`, so a corrupt segment throws `entryReconstructionFailed` before the orphan scan can silently drop it. Decision: keep the skip, extend the comment, pin with a test.

    6. Truncated JSONL — already typed and tested: `TranscriptTreeError.transcriptLineCorrupt(session:file:)` for mid-file corruption, torn FINAL line dropped with a warning (`TranscriptLineDecoding`). RecordingDurabilityTests pins both. No new code; cite it in the restore losses doc.

    Restore-path `try?` sweep: only the two sites above plus `URL.standardizedPath`'s canonical-path fallback (already commented). All will carry decision comments.
  timestamp: 2026-08-12T10:59:30.343255+00:00
- actor: claude-code
  id: 01kztva83rnsq3ve0y5e43ebhz
  text: |-
    Implementation is complete. TDD: the context-mismatch test failed first (compile error on the missing `contextMismatches` member), then the code made it pass.

    What changed:

    1. agentSpawn — documented as a non-loss in the new "Decided restore losses and loud failures (task ^xky3j8w)" section of the `restoreSessionTree` doc. New pinning test `recordedAgentSpawnStaysReadableFromTheRestoredTreesSidecar`: restore succeeds and the recorded spawn context stays readable from the loaded tree (sidecar field and configuration envelope).
    2. Context — new public `RestoredSessionTree.ContextMismatch` and `RestoredSessionTree.contextMismatches` (additive). `restoreSessionTree` compares each node's `sidecar.context` with `routedLLM.resolution.contextTokens` and reports each difference in walk order. New test `restoreReportsARecordedContextTheLiveResolutionNoLongerMatches` pins the empty case and the mismatch row.
    3. Deleted fork directory — documented the asymmetry in `TranscriptTree.load(under:)`. New test `deletingAChildDirectoryLoadsCleanWithoutIt` pins: deleted child is invisible, tree loads clean, parent conversation stays whole; the loud missing-parent case stays pinned by the adjacent existing test.
    4. Corrupt CompactionSegment — kept nil-not-throw in `compactionSegmentContent(in:)`; extended its doc comment with the full-level corruption path (mapper throws `entryReconstructionFailed`). Pinned by the parameterized test below.
    5. Corrupt OperationEventSegment — kept the skip in `operationEvents(in:)`; added a decision comment: the mapper throws before the orphan scan runs, so a `.lost` event can never be silently missed. Pinned by the parameterized test below.
       Items 4 and 5 share one parameterized test `corruptCustomSegmentFailsRestoreLoudly` (two arguments: CompactionSegment on `.response`, OperationEventSegment on `.prompt`): a corrupt segment makes `restoreSessionTree` throw `entryReconstructionFailed` that names the session and seq.
    6. Truncated JSONL — no new code. Behavior was already typed (`transcriptLineCorrupt`) and pinned by RecordingDurabilityTests (mid-file corruption and torn final line). Cited in the losses doc.

    Acceptance check:
    - Every `try?` on the restore path now carries a comment that states the decided behavior (`operationEvents`, `compactionSegmentContent`, `URL.standardizedPath`).
    - Each of the six items has a test that pins the decided behavior.

    Files: Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift, Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift, Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift.

    Verification: one full `swift test` run — 879 + 27 + 24 tests, all passed; only the accepted mlx-swift "missing creator" warning and the BoundedWait known issue.
  timestamp: 2026-08-12T11:21:56.088550+00:00
- actor: claude-code
  id: 01kztvagryzkw0bfe4z5fwf6jg
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift, Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift, Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift; `swift test` full run: 879 + 27 + 24 tests passed, 0 failures (accepted mlx "missing creator" warning and BoundedWait known issue only)
    - next: /review
  timestamp: 2026-08-12T11:22:04.958063+00:00
- actor: claude-code
  id: 01kztvy93cpjgvqnhrdhy6r2gc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD; the engine reported 9 findings; each finding asks for a refactor of test helpers that existed before this commit; the standing waiver for pre-existing test refactors removes all 9; 0 findings remain
    - next: none; the task is done
  timestamp: 2026-08-12T11:32:52.460236+00:00
- actor: claude-code
  id: 01kztvz2jh96nrkdjhvbhnxqd0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files: six restore losses decided, documented, and pinned; ContextMismatch reporting added
    - test: green — swift test, 879 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 52013ca
    - review: clean — 0 findings, scope HEAD~1..HEAD (9 engine findings waived per the written rule: all asked for refactors of pre-existing test helpers)
    - result: the task is in done
  timestamp: 2026-08-12T11:33:18.545223+00:00
position_column: done
position_ordinal: ff9780
title: Decide and document the silent restore losses
---
## Problem

A restored session silently differs from the saved one in several ways. Some losses are documented and deliberate (compaction budget, summarization, priming, tools, parked runs, the `.ebnf` grammar case). These are NOT documented, and each needs a decision — restore it, refuse loudly, or document the loss:

1. **`agentSpawn`** — recorded in the sidecar for restoration's benefit (Sources/FoundationModelsRouter/Recording/SessionSidecar.swift:186-201), but `restoreSessionTree` never reads it; a restored session gets `nil`.
2. **Context size** — restore uses the live profile's `resolution.contextTokens` and silently ignores the recorded `sidecar.context` (Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:412). Model identity is checked (`modelMismatch`), context is not, so `contextFill`'s denominator can silently change.
3. **Deleted fork directory** — a missing child directory is invisible; the tree loads clean and the child is just gone. A missing PARENT is loud (Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:280-293). The asymmetry is neither tested nor documented.
4. **Corrupt `CompactionSegment` checkpoint** — `try?` decode returns nil and the session restores as uncompacted, with full pre-fold history (Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:162-173).
5. **Undecodable `OperationEventSegment`** — `try?` decode drops it; an orphaned run never gets its manufactured `.lost` event (SessionTreeRestoration.swift:534).
6. **Truncated or partial JSONL line** — raw `DecodingError` with no file or session context (TranscriptTree.swift:429-431); one bad byte fails the whole tree load with an error that names nothing. No test.

## Proposed solution

For each item, make a decision and implement it:

- 1: restore it from the sidecar, or delete the sidecar field and its "for restoration" claim.
- 2: compare recorded context against the live resolution; surface a typed mismatch (error or warning) instead of silence.
- 3 and 6: wrap in typed errors that name the session and file; add tests for a deleted child and a truncated line.
- 4 and 5: replace `try?` with typed errors, or log loudly with the session id and keep going — decide per item and document why.

Record each decision in the code doc comments (the restoration file already has a documented-losses block at SessionTreeRestoration.swift:221-237 — extend it).

## Acceptance

- No `try?` remains on the restore path without a comment stating the decided behavior.
- Each of the six items has a test pinning the decided behavior. #transcript
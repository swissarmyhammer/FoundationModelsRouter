---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
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
---
assignees:
- claude-code
depends_on:
- 01KZR9YPHRGDCZ26R5BH1008KB
position_column: todo
position_ordinal: '9280'
title: Record fork cuts and diff baselines in append-only history coordinates
---
## Design rule

Compaction is append-only. A fold must not change the history's entry count. Two different numbers are conflated today, and they must separate:

- The **backend baseline**: the positional diff baseline against the current backend transcript. This one legitimately resets when the backend is swapped (fold, priming reseed).
- The **history ordinal**: the session's position in its own append-only recorded history. This one only grows. Fork cuts and restore must use this coordinate.

## Problem

`compact()` sets `persistedEntryCount = folded.count` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:423-424) — the count rewinds to the post-fold live window. A later `fork()` records that rewound number as `forkedAtEntryCount` (Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:115,152). Restore then applies it as a prefix of the parent's **raw, unfolded** recorded events (Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:378-394). Result: a fork made after a parent fold restores the **oldest pre-fold entries** — exactly the span the fold discarded — and the truncated span also cuts off the checkpoint, so no fold filtering runs at all. The restored fork shows a plausible but wrong conversation. The same mismatch occurs for a fork taken off a restored, previously compacted root, because restore also sets `persistedEntryCount = transcript.count` (Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:407).

No test forks after a fold: the test files that call `fork(` and the ones that call `compact(` never combine the two in that order.

## Proposed solution

1. Split the conflated counter: keep a positional `backendBaseline` for the diff against the current backend transcript, and add a monotonic `historyOrdinal` that counts recorded entry events and never rewinds.
2. `fork()` records the cut in history coordinates — the history ordinal, or (more robust) the entry id of the last shared recorded entry.
3. Restore composes a fork's effective transcript as: parent's raw recorded events up to the cut, plus the child's own events, and THEN applies the newest checkpoint inside that combined span. The cut selects history; the checkpoint selects context.
4. Migrate or version the sidecar field so old recordings (where `forkedAtEntryCount` was captured pre-fold and is thus still correct in raw coordinates) keep restoring correctly.

Depends on the checkpoint task ^h1008kb: "rebuild context from the checkpoint" only works when every applied fold writes one.

## Acceptance

- Live test: parent records N turns, folds, forks, both continue. Restore the tree. Assert the fork's effective transcript equals the fork's live transcript entry for entry — the fold's live window plus the fork's own entries, no resurrected pre-fold span.
- Same shape from a restored-then-forked previously-compacted root.
- Existing fork tests (cut pinned at fork time, grandfork counts) stay green. #transcript
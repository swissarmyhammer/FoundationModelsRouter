---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzv1spj4nfmeqdy6dh9wr5wc
  text: |-
    Research complete. Findings:

    - The one choke point for a session's recorded events is `RoutedSessionActor.append(partial:)` (RoutedSessionActorRecording.swift). Turn diffs, the compaction boundary diff, the session meta line, the bodyless close, and journaled run terminals all go through it. A monotonic `historyOrdinal` that counts entry-kind partials at this point counts exactly what `TranscriptTree.effectiveEntryEvents(forSession:)` counts, because that reader filters by the same entry-kind predicate.
    - The cut coordinate for `effectiveEntryEvents` is "count of the parent's effective raw entry-kind events". A fork's initial `historyOrdinal` is the parent's ordinal at fork time, so the cut point IS the child's initial ordinal — one fact again, but now in the correct coordinate space.
    - Restore needs no structural change: `effectiveEntryEvents` composes the parent prefix plus own events, and `reconstructableEvents` already applies the newest checkpoint inside the combined span. Only the recorded cut number is in the wrong space today.
    - Sidecar plan: add optional `forkedAtHistoryOrdinal` (additive within schema v2, documented in the RecordingSchemaVersion v2 entry). Keep writing the legacy `forkedAtEntryCount` so old readers behave as before. Readers use `forkedAtHistoryOrdinal ?? forkedAtEntryCount`; old recordings captured the count pre-fold, so the fallback keeps them restoring as they do today.
    - Restored nodes get `historyOrdinal = effectiveEvents.count` (already computed in `restoreSessionTree`). Root vend gets 0.
    - Test plan: new suite ForkAfterCompactionRestorationTests. (a) live fold-then-fork with a deterministic fold (the derived-budget recipe from RoutedSessionCompactTests) — assert the restored fork's transcript entry ids equal the checkpoint's liveWindowEntryIds plus the fork's own recorded entry ids, and share nothing with foldedEntryIds. (b) restore a compacted root, fork it, restore again — assert the fork's ids equal the restored root's seed ids plus the fork's own ids. Plus: the fork sidecar carries both cut fields, and a stripped `forkedAtHistoryOrdinal` key (old recording) still restores through the legacy field.
  timestamp: 2026-08-12T13:15:13.861+00:00
- actor: claude-code
  id: 01kzv68y7ns3xt4cpsr8hmy4ah
  text: |-
    Implementation complete. What changed:

    - TDD: the new suite ForkAfterCompactionRestorationTests went red first for the correct cause (the fork's effective stream held the pre-fold span and no checkpoint), then green after the fix.
    - Split the counter. `persistedEntryCount` stays the positional backend diff baseline. A new monotonic `historyOrdinal` counts recorded entry-kind events and never rewinds. It advances at the one choke point, `RoutedSessionActor.append(partial:)`, gated by the new shared `TranscriptEvent.Kind.isEntryKind` predicate — the same predicate `TranscriptTree.effectiveEntryEvents` filters by, so the writer and the reader use one coordinate space. `TranscriptTree`'s private copy of the predicate was removed.
    - `fork()` captures `historyOrdinal` beside the backend count in the same turn-lock window. The child's initial ordinal IS the cut, and the sidecar records it as the new optional field `forkedAtHistoryOrdinal`. The legacy `forkedAtEntryCount` is still written with its old value, so a pre-ordinal reader of a new recording behaves as before.
    - Restore: `effectiveEntryEvents` cuts with `forkedAtHistoryOrdinal ?? forkedAtEntryCount`. No structural change was needed — the composition (parent raw prefix + own events, then newest checkpoint in the combined span) already existed; only the cut number was in the wrong space. Restored nodes start `historyOrdinal` at `effectiveEvents.count`; root vends start at 0.
    - Migration: the field is additive within schema v2 and is documented in the RecordingSchemaVersion v2 entry. A test strips the key to prove the legacy fallback restores old recordings unchanged.
    - The resume-handle path (`makeLanguageModel(resuming:)`) passes `forkedAtHistoryOrdinal: nil` and keeps today's behavior; follow-up task ^bw2gts3 records that gap.
    - Test-fixture reuse: `driveTurns` and `recencyWindowOnlyEstimate` moved from RoutedSessionCompactTests private helpers to shared Helpers/CompactionFoldFixtures.swift, plus a new `deterministicFoldBudget(for:)`; RoutedSessionCompactTests now calls the shared ones.
    - One unrelated pre-existing flake surfaced in the full run: TranscriptTreeTests `deletingAChildDirectoryLoadsCleanWithoutIt` asserted children in creation order, but two forks minted in the same millisecond sort by their ULID random bits. Fixed with a set comparison — the same convention `treeShapeMatchesIndex` in that suite already states.
  timestamp: 2026-08-12T14:33:27.541397+00:00
- actor: claude-code
  id: 01kzv691p8pxwf1zrr1mbqf40r
  text: |-
    ### implement — changed
    - evidence: 14 files changed + 2 new test files. Sources: TranscriptEvent.swift (Kind.isEntryKind), TranscriptTree.swift (cut fallback), SessionSidecar.swift (forkedAtHistoryOrdinal), RecordingSchemaVersion.swift (v2 doc), SessionTreeRestoration.swift, RoutedSessionActor.swift (historyOrdinal), RoutedSessionActorRecording/Forking/Compaction.swift, RoutedLLM.swift, RecordingLanguageModel.swift. Tests: new ForkAfterCompactionRestorationTests.swift (3 tests, red first then green) and Helpers/CompactionFoldFixtures.swift; updated RoutedSessionCompactTests, TranscriptTreeTests, SessionSidecarTests, 2 integration test files. `swift build --build-tests` clean; one full `swift test`: 884 tests in 83 suites passed (1 pre-existing known issue), 27 in 11 suites passed, 24 in 5 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-08-12T14:33:31.080776+00:00
- actor: claude-code
  id: 01kzv7cbtcmvaf3z57w3rhj5j0
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 282a598); engine reported 11 findings; 8 findings removed by the standing written rule for test code that existed before this commit; 3 findings stay open — Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:372, Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift:37, Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift:51
    - next: correct the 3 open findings in the checklist, then run the review again
  timestamp: 2026-08-12T14:52:48.332495+00:00
- actor: claude-code
  id: 01kzv7d83syfa6ccnv5bmq6aj3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 20+ files; split persistedEntryCount into the backend baseline and the monotonic historyOrdinal; fork records forkedAtHistoryOrdinal; restore cuts with the ordinal
    - test: green — swift test, 884 tests in 83 suites passed + 27 + 24, 0 failures (the one implement run is the test evidence)
    - commit: 282a598
    - review: findings — 3 open: TranscriptEvent.swift:372, CompactionFoldFixtures.swift:37, CompactionFoldFixtures.swift:51 (8 waived, pre-existing tests)
  timestamp: 2026-08-12T14:53:17.305738+00:00
- actor: claude-code
  id: 01kzv8gbyps1a5wff2j8jrtfvd
  text: |-
    Fixed the three open review findings.

    1. TranscriptEvent.swift `stamped` near-duplicate of `withCompactionCount`: the two functions construct two different types with two different field lists. No shared function can hold both bodies, and a change to one never applies to the other. The duplication-parsed rule gives the marker `// sah:allow duplication <reason>` for a deliberate fork in a different domain. The repository already carries this marker three times (RoutedLLM.swift, GuidedGeneration.swift, SessionConfiguration.swift) for the same shape. Applied the marker with the reason above `stamped`.

    2. CompactionFoldFixtures.swift magic numbers: read the Swift rule first (swiftlint `no_magic_numbers`, allowed values [0, 1, -1, 100]; a `let` declaration names its value). Added two named file-scope constants: `defaultKeepRecentTurns = 4` (the recency window each fold stage keeps by default) and `foldTargetMidpointDivisor = 2` (sets the deterministic budget target at the midpoint of the floor and the full estimate). Swept the whole file: no other unnamed literal remains (`0` and `1` are allowed values).

    3. Sweep for hand-built copies of the extracted fixtures: RoutedSessionCompactTests still held `deterministicShrinkBudget(for:)`, a body-identical private twin of the shared `deterministicFoldBudget(for:)` fixture that commit 282a598 extracted. Deleted the twin and pointed its two call sites at the shared fixture. Behavior is identical because the bodies were identical. The private `recencyWindowOnlyEstimate` copies in AutoCompactionTests and GuidedGenerationTests stay untouched: they are test code from before commit 282a598, which the standing waiver rule covers, and this change set does not touch those files.

    Verification: `swift build --build-tests` clean; one ungated `swift test` run: 884 tests in 83 suites passed (1 pre-existing known issue in the BoundedWait suite, same as the prior recorded run), 27 tests in 11 suites passed, 24 tests in 5 suites passed. Zero failures.
  timestamp: 2026-08-12T15:12:28.118985+00:00
- actor: claude-code
  id: 01kzv8gnprf3az1sb63f98ecb3
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift (sah:allow duplication marker on `stamped`), Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift (named constants `defaultKeepRecentTurns`, `foldTargetMidpointDivisor`), Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift (removed the `deterministicShrinkBudget` twin of the shared fixture). One `swift test` run: 884 tests in 83 suites passed (1 pre-existing known issue), 27 in 11 suites passed, 24 in 5 suites passed, 0 failures. All three review-finding boxes checked on the card.
    - next: /review
  timestamp: 2026-08-12T15:12:38.104076+00:00
depends_on:
- 01KZR9YPHRGDCZ26R5BH1008KB
position_column: doing
position_ordinal: '8180'
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
- Existing fork tests (cut pinned at fork time, grandfork counts) stay green.

## Review Findings (2026-08-12 09:35)

- [x] `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:372` — func `stamped` is a near-duplicate of `withCompactionCount` at Sources/FoundationModelsRouter/Recording/SessionSidecar.swift:430 (60 tokens, 90% alike).
- [x] `Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift:37` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift:51` — Magic numbers should be replaced by named constants.

Waiver note: The engine reported eleven findings. We removed eight findings by the standing written rule that removes findings which ask us to refactor test code that existed before commit 282a598. The removed findings were in RoutedSessionCompactTests.swift (lines 130, 141, 159), SessionSidecarTests.swift (lines 99, 114), and TranscriptTreeTests.swift (lines 184, 671, 756). This commit did not add or change those symbols. The two CompactionFoldFixtures.swift findings stay because this commit added that file. #transcript
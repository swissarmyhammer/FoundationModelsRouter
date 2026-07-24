---
comments:
- actor: claude-code
  id: 01kya6xze6svwjq056bm7ha7pn
  text: |-
    Implemented both halves of the task at the generate boundary in RoutedSessionActor (Sources/FoundationModelsRouter/Session/RoutedSession.swift):

    (a) Mid-turn fill reporting: SessionEvent.TokenUsage (Session/SessionEvent.swift) gained a new `contextFill: Double` field. `finishTurn` now reads `contextFill` right after `usageState`'s conditional update and stamps it onto every `.turnEnded` event — since a turn can auto-compaction-retry once (task 8213x39), this fires once per physical generate attempt, so a caller watching `streamEvents` sees the context meter update live during a turn (once for a blocked/failed attempt, once for the recovered retry), not only once the whole logical turn finishes.

    (b) Typed hard-ceiling budget error: TokenBudget (Compaction/TokenBudget.swift) gained an optional `hardCeiling: Double?` (default nil, opt-in) and a new public `ContextBudgetError.hardCeilingExceeded(fill:ceiling:)`. `runTurnAttempt` now checks `autoCompactionBudget?.hardCeiling` against measured `contextFill` immediately before calling the generate closure `body(composedPrompt)` — throwing deterministically, before ever submitting a doomed generate call, when fill is already at/over the ceiling. `isRecoverableContextOverflow` now also recognizes this new error alongside `LanguageModelError.contextSizeExceeded`, so it is caught by the exact same existing fold-harder-and-retry-once machinery (no new retry logic needed) — one retry, then surfaces if still exceeded (e.g. an unfoldable oversized transcript, or a no-op fold).

    Tests added:
    - TokenBudgetTests.swift: hardCeiling defaults to nil; accepts an override.
    - SessionEventStreamTests.swift: updated the existing turnEnded test's TokenUsage construction to include the new contextFill value.
    - AutoCompactionTests.swift: `hardCeilingFailsFastThenRecoversWithLivePerAttemptFill` (proves the blocked attempt never touches the backend — no textDelta before the compaction event — and that the two turnEnded events carry different, live, mid-turn contextFill values) and `hardCeilingStillExceededAfterRetrySurfacesError` (proves a genuinely no-op retry fold surfaces the same ContextBudgetError after exactly one retry, never looping).

    Verification: `xcrun swift build` clean; `xcrun swift test` — 533/533 passing (510 unit + 18 gated-integration [skip, no GPU/network here] + 5 evals), zero new warnings (only the pre-existing unrelated mlx-swift-lm Cmlx resource-bundle build note). Baseline before this task was 529 (506+18+5); net +4 new unit tests.

    Review: ran mcp__sah__review on the working diff. 16 findings, 14 about PRE-EXISTING test-file duplication (StubProbe/StubEmbeddingContainer/StubMetadataSource/makeTempDir/collect/configJSON/treeJSON/rawMetadata/profile(context:) already duplicated near-identically across TokenBudgetTests.swift/SessionEventStreamTests.swift/AutoCompactionTests.swift before this task) plus one pre-existing force-unwrap in the untouched `newestStampedUsage` and one pre-existing near-duplicate closure in the untouched session `init` — all out of scope per "no unrelated refactors while implementing," waived with this note rather than fixed. Fixed the one truly in-scope finding: added a missing doc comment on the new `ContextBudgetError.errorDescription`. Dispatched the double-check agent for adversarial verification of the semantics (contextFill read-after-mutation ordering, pre-flight-check placement, retry-once invariant, and a spot-check that the waived findings are genuinely pre-existing) before final hand-off.

    Leaving in `doing` per /implement's contract.
  timestamp: 2026-07-24T14:02:09.734714+00:00
- actor: claude-code
  id: 01kya78j258vvzqn46ne4cetxc
  text: |-
    Adversarial double-check (via really-done's gate) returned PASS, no findings. It independently traced: contextFill is read AFTER the usageState mutation in finishTurn (so a blocked pre-flight attempt correctly reports the stale prior fill); the hard-ceiling check sits strictly before body(composedPrompt) runs and after the proactive runTurn-level trigger fold, with no double-check/skip; isRecoverableContextOverflow's LanguageModelError.contextSizeExceeded branch is untouched and the new ContextBudgetError branch is purely additive; the "every failed turn leaves exactly one trace" invariant holds on this new pre-flight path (usageBefore==usageAfter, diffIncludedResponse false, exactly one synthetic bodyless close, no persistedEntryCount mutation); and it specifically traced why hardCeilingStillExceededAfterRetrySurfacesError is correct rather than coincidental — fold() returns before updating usageState on a genuine no-op (stagesApplied.isEmpty), so the stale pre-turn fill survives into the retry's own pre-check and correctly re-trips the ceiling. It re-ran `xcrun swift test --filter AutoCompactionTests` (8/8 pass) and the full suite fresh (533/533 passing), matching the reported figures independently. It also spot-checked two of the waived pre-existing-duplication findings via `git show HEAD:...`/`git diff` scope and confirmed StubProbe/makeTempDir/configJSON in TokenBudgetTests.swift predate this diff (a clean 12-line addition), and that ContextBudgetError/hardCeiling in TokenBudget.swift are pure additions while newestStampedUsage's force-unwraps sit entirely outside the diff.

    Task is green: build clean, 533/533 tests passing, zero new warnings, adversarial review PASS. Leaving in `doing` per /implement's contract — ready for /review.
  timestamp: 2026-07-24T14:07:56.485267+00:00
depends_on:
- 01KXTFS4FNT1P5F889D1PEQ9N7
position_column: doing
position_ordinal: '80'
title: Mid-turn fill reporting + typed hard-ceiling budget error at the generate boundary
---
Harness plan §5.1 absorbed. The native loop never yields mid-turn; the generate boundary inside RoutedSession is the only seam. (a) per-inner-call measured fill surfaced live — feeds the observable state's context meter during the turn, not just at its end; (b) optional hard ceiling: fail fast with a typed budget error BEFORE submitting a doomed generate — deterministic, caught by auto-compaction's retry-once. Parked research question (recorded, not asked): rewriting the forwarded transcript (fold-below-the-session) — rejected for v1, session/model view divergence.
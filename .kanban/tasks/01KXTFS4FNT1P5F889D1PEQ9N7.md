---
assignees:
- claude-code
depends_on: []
position_column: todo
position_ordinal: '8380'
title: 'TokenBudget + contextFill: measured token accounting'
---
## What
Implement the token-accounting layer of compaction_plan.md §1.4–1.5 in `Sources/FoundationModelsRouter/Compaction/TokenBudget.swift` and `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:

- `public struct TokenBudget: Sendable { var limit: Int; var trigger: Double = 0.80; var target: Double = 0.50 }`
- `var contextFill: Double { get async }` added to the `RoutedSession` protocol and implemented on `RoutedSessionActor`:
  - **Numerator (live)**: the *last turn's usage delta* — NEVER the cumulative value. `LanguageModelSessionBackend.usageTokenCounts()` (`Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`) returns **cumulative** counts; the actor already derives per-turn usage by delta (`Self.usageDelta(before:after:)` in `RoutedSession.swift`). Current size = newest turn's per-turn `tokensIn + tokensOut` (the newest turn's input delta IS the whole transcript tokenized by the actual model). Retain the delta `recordTranscriptDelta` already computes, or snapshot-diff `usageTokenCounts()` per turn. Using the raw cumulative value would overestimate fill monotonically and trip the 0.80 trigger far too early.
  - **Denominator**: the profile's resolved working context — `SlotResolution.contextTokens` (`Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`; note there is no `ResolvedSlot` type). Plumbing partially exists: `Router.swift` (~line 683) already passes `context: resolution.contextTokens` into session construction — verify the actor can reach it and finish the wiring if it currently stops short.
  - **Restored (pre-first-turn)**: newest stamped `.response` event (`tokensIn`/`tokensOut`) in that session's `transcript.jsonl`. Actor-path recordings already carry stamps today (`recordTranscriptDelta(grammar:since:usage:)`), so this is testable without the handle-stamping task. If no stamp exists, fill is *unknown* — never guessed. Represent unknown explicitly (e.g. optional or documented sentinel — pick one and document it) until the first turn re-measures.
  - Brand-new session before first turn: fill ≈ 0.

Update any `RoutedSession` conformers/stubs in `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift` and friends. Checkpoint-aware restored fill (using `CompactionSegment.tokensAfter`) is a later task (reconstruction) — leave a seam, not an implementation.

## Acceptance Criteria
- [ ] `contextFill` on a live session = last-turn usage delta / resolved `SlotResolution.contextTokens`
- [ ] After multiple turns, fill reflects only the newest turn's delta — a test that would fail under the cumulative reading passes
- [ ] After restore with stamped events, fill derives from the newest stamp; with no stamps, fill reports unknown (never a guess)
- [ ] New session before first turn reports ≈ 0
- [ ] `TokenBudget` defaults: trigger 0.80, target 0.50; `limit` defaultable from the profile's resolved context

## Tests
- [ ] `Tests/FoundationModelsRouterTests/TokenBudgetTests.swift` — budget defaults and fill math with a stub backend returning scripted cumulative `usageTokenCounts()`, including the multi-turn delta-vs-cumulative case
- [ ] Extend `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift` — restored-fill-from-stamps and unknown-fill cases
- [ ] `swift test --filter 'TokenBudget|TokenUsageMetering'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
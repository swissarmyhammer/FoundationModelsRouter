---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14gy9c0243ycbwrf9d1pxgb
  text: |-
    Picked up. Research done.

    Findings that set the design:

    - `performAutoCompaction(prompt:budget:)` calls `fold(...)` up to three times as it degrades (flash -> own model -> deterministic). A span opened inside `fold(...)` itself would therefore make two or three spans for one automatic compaction, which breaks the acceptance criterion "one automatic fold makes one span". So the one shared span site is a new private helper, `withCompactionSpan(trigger:_:)`, that both `compact(prompt:budget:)` and `performAutoCompaction(prompt:budget:)` call around their whole fold work. The card's "one span around the shared fold body" is read as "one span-opening site shared by both entry points", not "inside fold()".
    - The tier the span reports is derived, not assumed: when `CompactionResult.summarizerModel` is nil no summarizer wrote the applied summary, so the tier is `deterministic`; otherwise it is the tier that produced the result. That is true for a caller fold that `TurnTruncation` alone landed, and for the automatic path's deterministic fallback.
    - `FoldSummarizerTier` gets a third case, `deterministic`. It already carries `flash` and `ownModel`.
    - `RouterTracing` gets `CompactionTrigger` (caller/auto) beside `TurnEntryPoint`, plus the keys `compaction.trigger`, `compaction.tier`, `tokens.before`, `tokens.after`. The `// periphery:ignore` marker on `SpanName.compact` goes away.
    - The auto-compaction fixtures (`ConfiguredLLMContainer`, `PerSlotModelLoader`, `makeTriggeredSession`, `cannedText`, `turnCount`, `warmUpContextTokens`, `expectedWarmUpEntries`, `fixedBudget`) are private to `AutoCompactionTests`. The card says to use them from the new suite, so they move to `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift` and gain a `tracer` parameter. `AutoCompactionTests` then calls them through that namespace. No duplication.
    - `StubSessionBackend.replacingTranscript(_:)` copies `shouldThrow`, so a caller-driven fold is made to fail by flipping `container.lastBackend?.shouldThrow`, not the container flag. The container flag is what makes the *flash* tier fail, because that tier builds its summarizer through `container.makeSession(instructions:)`.
    - `SpanContentSafetyTests` already drives a caller fold through a tracer-carrying fixture and reads every attribute of every span, so it covers the new span with no edit.
  timestamp: 2026-08-28T15:48:44.544871+00:00
- actor: claude-code
  id: 01m14hdtpp5d62vryqbgcaxca1
  text: |-
    Implementation landed, TDD order kept.

    RED: the new suite was written first and run before any production edit. 7 of its 8 tests failed at `spans.count == 1 -> spans.count -> 0`, so each failed because no fold span existed. The eighth (`untracedFoldFoldsNormally`) passed from the start on purpose: it asserts fold behavior with no tracer, so it is the regression guard, not a span test.

    GREEN: all 8 pass.

    What the production change does:

    - `RouterTracing.SpanName.compact` lost its `// periphery:ignore` marker and its "no caller" note.
    - `RouterTracing.AttributeKey` gained `tokens.before`, `tokens.after`, `compaction.trigger` and `compaction.tier`. `compaction.tier` documents its three values in prose, because `FoldSummarizerTier` is private to the session actor and a DocC link to it would not resolve.
    - `RouterTracing.CompactionTrigger` (`caller`/`auto`) sits beside `TurnEntryPoint`, the same shape.
    - `RoutedSessionActor.withCompactionSpan(trigger:_:)` is the one span site both fold paths call. It wraps the whole compaction, not one `fold(...)` call, because the automatic path calls `fold(...)` once per tier as it degrades.
    - `performAutoCompaction(prompt:budget:)` now delegates its tier ladder to `foldThroughTiers(prompt:budget:)`, which returns the result and the tier that produced it. The ladder itself is unchanged, cancellation guards included.
    - `FoldSummarizerTier` gained `deterministic`.

    The tier written on the span is derived rather than assumed: when `CompactionResult.summarizerModel` is nil, no summarizer wrote the applied summary, so the span reports `deterministic`. That is correct for a caller fold `TurnTruncation` alone landed, for the automatic path's deterministic fallback, and for a fold whose summary was discarded. Otherwise the span reports the tier that ran.

    Test-fixture move: the auto-compaction fixtures were private to `AutoCompactionTests`, and the card asks the new suite to use them. `ConfiguredLLMContainer`, `PerSlotModelLoader`, `cannedText`, `turnCount`, `warmUpContextTokens`, `expectedWarmUpEntries()`, `fixedBudget` and `makeTriggeredSession(...)` moved to `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift`, which gained a `tracer` parameter and a `tempDirPrefix` parameter so each suite still names its own temp directory. `AutoCompactionTests` calls through the new namespace and its 12 tests stayed green across the move. Two literals the move exposed got names: `warmUpUsageStepTokens` and `belowRecencyFloorDivisor`.

    Discovery worth keeping: `StubSessionBackend.replacingTranscript(_:)` copies `shouldThrow`, and `ConfiguredLLMContainer.makeSession(instructions:)` reads the container flag. So a test makes the FLASH tier fail with `flash.shouldThrow = true` (a fresh container call) but must make the SESSION'S OWN model fail with `standard.lastBackend?.shouldThrow = true` (the live backend the fold clones). Flipping the container flag alone leaves the own-model tier working.

    Verification, all three green:
    - `swift build` — Build complete.
    - `swift test` — 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests. Baseline was 1078 in 111 with the same 2 known issues plus 83: the difference is exactly the new `CompactionTracingTests` suite and its 8 tests. The 2 known issues are the documented `RealModelHarness` embedding-slot one and the `BoundedWait` wall-clock one; no new failure.
    - `swift build --package-path IntegrationTests --build-tests` — Build complete.

    `SpanContentSafetyTests` was not edited and still passes, so no attribute of the new span carries transcript text or the summary.
  timestamp: 2026-08-28T15:57:13.814986+00:00
- actor: claude-code
  id: 01m14he037fcfe4hvbfv46j672
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Tracing/RouterTracing.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/CompactionTracingTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift (new), Tests/FoundationModelsRouterTests/AutoCompactionTests.swift. `swift build` complete; `swift test` 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests; `swift build --package-path IntegrationTests --build-tests` complete.
    - next: /review
  timestamp: 2026-08-28T15:57:19.335920+00:00
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: doing
position_ordinal: '80'
title: Open one span for each compaction fold
---
## What

Wrap each compaction fold in one span, for the caller-driven path and the automatic path.

- Instrument `compact(prompt:budget:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:76) and `performAutoCompaction(prompt:budget:)` (same file, line 107). Prefer one span around the shared `fold(...)` body (line 198), with the trigger as an attribute.
- Span name: `FoundationModelsRouter.compact` from `RouterTracing`. Kind: `.internal`.
- Attributes: `session.id`, `model.ref`, the trigger (`caller` or `auto`), `tokens.before`, `tokens.after`, and the summarizer tier that ran (deterministic only, model-assisted, or the degraded fallback; see `FoldSummarizerTier`).
- A fold that throws must record the error on the span and throw again. The automatic path's degrade to the deterministic tier must show as the tier attribute, not as a failed span.
- Do not put transcript text or the summary text in an attribute.

## Acceptance Criteria
- [x] One caller-driven `compact()` makes one span with the trigger `caller`.
- [x] One automatic fold makes one span with the trigger `auto`.
- [x] The token attributes show the fold's before and after estimates.
- [x] A summarizer failure on the caller path keeps the span, with the error recorded.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/CompactionTracingTests.swift`. Use `InMemoryTracer` with the fold fixtures (`Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift`) and the auto-compaction fixtures from `AutoCompactionTests.swift`.
- [x] Assert the span name, attributes, tier attribute on a degraded automatic fold, and the error record.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router #compaction
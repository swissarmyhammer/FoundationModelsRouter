---
assignees:
- claude-code
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: todo
position_ordinal: '8380'
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
- [ ] One caller-driven `compact()` makes one span with the trigger `caller`.
- [ ] One automatic fold makes one span with the trigger `auto`.
- [ ] The token attributes show the fold's before and after estimates.
- [ ] A summarizer failure on the caller path keeps the span, with the error recorded.

## Tests
- [ ] Add `Tests/FoundationModelsRouterTests/CompactionTracingTests.swift`. Use `InMemoryTracer` with the fold fixtures (`Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift`) and the auto-compaction fixtures from `AutoCompactionTests.swift`.
- [ ] Assert the span name, attributes, tier attribute on a degraded automatic fold, and the error record.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router #compaction
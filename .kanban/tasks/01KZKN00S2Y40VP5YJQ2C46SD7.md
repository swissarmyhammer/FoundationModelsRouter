---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Summarization's three knobs are unreachable from the production compaction path — Compactor.compact hardcodes Summarization()
---
Split out of `^zche4zy` (its review recorded this and ruled it out of scope for that card).

`Compactor.compact(_:prompt:budget:summarizer:pendingRuns:)` constructs the model-assisted stage as a bare `Summarization()`:

```swift
let folded = try await Summarization().apply(...)
```

So all three of the stage's tuning knobs — `keepRecentTurns`, `maxChunkTokens`, `summaryTokenRatio` — plus the derived `maximumOutputTokens` cap take their defaults on every production fold, and are reachable only by constructing `Summarization` directly (which only tests do). `compact` takes a `TokenBudget` and a `CompactionPrompt`, but nothing that reaches the stage's own configuration.

That means:
- A caller cannot trade compression for summary fidelity (`summaryTokenRatio`, default 0.25) even though it is a `public var`.
- A caller cannot widen or narrow the map-reduce chunk size (`maxChunkTokens`, default 2000) to suit its model's real context.
- `keepRecentTurns` is fixed at 4 for the fold, while the deterministic stages happen to default to the same 4 — a coincidence nothing enforces.

## Decide first, then implement
Is this intended (the knobs exist for tests and for a future direct-stage caller), or is it a gap? If a gap, the shape to weigh:
- a `Summarization` parameter on `compact`, defaulted to `Summarization()`, which keeps every existing caller source-compatible; versus
- widening `TokenBudget` or `CompactionPrompt`, which would put stage tuning in a type that is not about the stage.

## Acceptance Criteria
- [ ] A decision is recorded on this card: intended, or a gap
- [ ] If a gap: the production path can set all three knobs, with every existing `compact` call site unchanged
- [ ] If a gap: ungated coverage that a non-default knob set through `compact` actually reaches the summarizer call
- [ ] If intended: the knobs' doc comments say so, so the next reader does not re-open this

#phase-1
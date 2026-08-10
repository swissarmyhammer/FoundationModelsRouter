---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
title: A live session's fold still cannot be tuned — RoutedSession.compact reaches Compactor.compact without a Summarization
---
Discovered while implementing `^2c46sd7`, which made ``Summarization``'s three knobs reachable by adding a `summarization: Summarization = Summarization()` parameter to `Compactor.compact`.

That closes the gap for a caller who holds a bare `Transcript`. It does not close it for a caller who holds a session: `RoutedSession.compact(prompt:budget:)` -> `RoutedSessionActor.compact` calls `Compactor.compact` without a `summarization:` argument, so a live session always folds at `Summarization()`'s defaults — `keepRecentTurns` 4, `maxChunkTokens` 2000, `summaryTokenRatio` 0.25.

A session is where the knobs matter most: it is the layer that knows which model summarizes (its own backend, or its profile's `flash` slot) and therefore what chunk size that model's real context can take.

## Decide first, then implement
Same shape as `^2c46sd7`: is the session layer deliberately opinionated (one fold configuration for every session, so the surface stays small), or is this the same gap one layer up? If it is a gap, the shape to weigh is a `summarization` parameter on `RoutedSession.compact(prompt:budget:)`, defaulted so every existing caller stays source-compatible — versus a per-profile or per-session setting, which is a wider change and needs its own justification.

## Acceptance Criteria
- [ ] A decision is recorded on this card: intended, or a gap
- [ ] If a gap: a session's fold can set all three knobs, with every existing `RoutedSession.compact` call site unchanged
- [ ] If a gap: ungated coverage that a non-default knob set on a session reaches the summarizer call
- [ ] If intended: the session-level doc says so, so the next reader does not re-open this

#phase-1
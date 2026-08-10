---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzq0cy9r45p02bd8e6920cav
  text: |-
    ### Closed as redundant — the work landed on `^2c46sd7`

    `^2c46sd7`'s review judged that its own acceptance criterion 2 was not met while a live session still folded at `Summarization()`'s defaults: that card's words are "the production compaction path" and "every production fold", and `RoutedSessionActorCompaction.swift`'s single `Compactor.compact` call site — shared by the caller-driven `compact(prompt:budget:)` and by `performAutoCompaction(prompt:budget:)` — omitted `summarization:`. A follow-up card does not close a criterion another card states, so the session-path work was done under `^2c46sd7` rather than here.

    What landed there covers every acceptance criterion on this card: `RoutedSessionActor.summarization`, set from `RoutedModel.makeSession(... summarization:)` and `makeGuidedSession(... summarization:)`, inherited by `fork(workingDirectory:)`, read inside the one shared `fold(prompt:budget:summarizer:)`; plus three ungated tests that each fail when the wiring is dropped.

    Nothing this card describes is still open, so it is closed rather than left as a duplicate. See `^2c46sd7`'s comments for the decision, the shape, and the dropped-wiring proof.
  timestamp: 2026-08-10T23:33:49.496844+00:00
position_column: done
position_ordinal: ff8580
title: A live session's fold still cannot be tuned — RoutedSession.compact reaches Compactor.compact without a Summarization
---
Discovered while implementing `^2c46sd7`, which made ``Summarization``'s three knobs reachable by adding a `summarization: Summarization = Summarization()` parameter to `Compactor.compact`.

That closes the gap for a caller who holds a bare `Transcript`. It does not close it for a caller who holds a session: `RoutedSession.compact(prompt:budget:)` -> `RoutedSessionActor.compact` calls `Compactor.compact` without a `summarization:` argument, so a live session always folds at `Summarization()`'s defaults — `keepRecentTurns` 4, `maxChunkTokens` 2000, `summaryTokenRatio` 0.25.

A session is where the knobs matter most: it is the layer that knows which model summarizes (its own backend, or its profile's `flash` slot) and therefore what chunk size that model's real context can take.

## Decide first, then implement
Same shape as `^2c46sd7`: is the session layer deliberately opinionated (one fold configuration for every session, so the surface stays small), or is this the same gap one layer up? If it is a gap, the shape to weigh is a `summarization` parameter on `RoutedSession.compact(prompt:budget:)`, defaulted so every existing caller stays source-compatible — versus a per-profile or per-session setting, which is a wider change and needs its own justification.

## REDUNDANT (2026-08-10) — done under `^2c46sd7`
`^2c46sd7`'s own review ruled that its acceptance criterion 2 ("the production compaction path", "every production fold") was not met while a live session still folded at the defaults, so the session-path work landed on that card rather than here. Nothing this card describes is still open. Kept only as a record; do not implement it a second time.

## Acceptance Criteria
- [x] A decision is recorded on this card: intended, or a gap — a gap, recorded on `^2c46sd7`
- [x] If a gap: a session's fold can set all three knobs, with every existing `RoutedSession.compact` call site unchanged — the session carries a `Summarization` (`RoutedSessionActor.summarization`), set from `RoutedModel.makeSession(... summarization:)` / `makeGuidedSession(... summarization:)` and inherited by `fork`; the shared `fold(prompt:budget:summarizer:)` hands it to `Compactor.compact`, so the caller-driven fold and the automatic one both carry the knobs. `public protocol RoutedSession` is untouched, so no conformer and no `compact` call site needed an edit.
- [x] If a gap: ungated coverage that a non-default knob set on a session reaches the summarizer call — three tests, two on the caller-driven fold (`keepRecentTurns`, `summaryTokenRatio`) and one on the automatic fold, all of which fail when the wiring is dropped.
- [ ] If intended: the session-level doc says so, so the next reader does not re-open this — not applicable, the decision is "gap"
#phase-1
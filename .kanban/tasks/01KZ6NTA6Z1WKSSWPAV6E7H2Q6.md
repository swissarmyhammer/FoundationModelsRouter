---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7saxwfcfn50gm9ce1c5fx5
  text: |-
    Research complete. Findings:

    - Boundary write site: `Summarization.apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:)` synthesizes the summary `.response` entry carrying `.text(summary)` + `.custom(CompactionSegment)`. It is invoked only by `Compactor.compact(_:prompt:budget:summarizer:)` (pure, no session access). The session-side entry point with mailbox access is `RoutedSessionActor.fold(prompt:budget:summarizer:)` (RoutedSession.swift), shared by manual `compact()` and auto-compaction.
    - Mailbox: `RoutedSessionActor.mailbox` (nonisolated let, per-session). `SessionMailbox.status()` returns `[RunStatus]` with exactly the run-plane triple the eventplan names: completionToken, op, latestProgressDetail (plus tool/kind, which stay out of the boundary per the task's "token, op, progress" rule).
    - Model visibility: the vendored fork's TranscriptConverter renders only `.text`/`.structure` segments into the model prompt — `.custom` segments are invisible. So "visible the same way other boundary metadata is" means an additional `.text` segment on the synthesized boundary entry (the summary text is how the boundary reaches the model today). Plan: segments become [.text(summary), .text(pendingRuns rendering), .custom(segment)] when runs are parked; unchanged otherwise. `Folded.summary`/`CompactionResult.summary` stays the summarizer text alone.
    - Codable back-compat: `Content` uses synthesized Codable; adding `pendingRuns: [PendingRunSummary]?` gets decodeIfPresent semantics automatically, so previously recorded segments decode with nil.
    - Deterministic-only folds (ToolOutputElision/TurnTruncation) synthesize no boundary entry at all — the field only lands when Summarization runs, which is the only place a boundary exists.
    - Plumbing: `Compactor.compact` and `Summarization.apply` gain `pendingRuns: [CompactionSegment.PendingRunSummary] = []` (defaults keep the bare-session `noteCompaction` recipe and all existing callers unchanged); `fold` reads `await mailbox.status()` at fold time and maps it in.
    - Test homes: hermetic session-level suite `RoutedSessionCompactTests` (stub backend + InMemoryRecorder, budget = recencyOnly*2/target 0.25 forces Summarization) for compact-with-parked-run round trip and empty-mailbox no-op; `CompactionSegmentTests` for Codable round trip + back-compat decode. Fake-run parking pattern (RunLatch) from `SessionMailboxTests`.
  timestamp: 2026-08-05T01:41:47.023443+00:00
- actor: claude-code
  id: 01kz7t0atze1wg3w0csm226ser
  text: |-
    Implementation landed, TDD (failing tests first, then wiring):

    Production:
    - `Compaction/CompactionSegment.swift`: new nested `CompactionSegment.PendingRunSummary` (Codable/Equatable/Sendable; completionToken, op, latestProgressDetail — run plane only) and `Content.pendingRuns: [PendingRunSummary]?` (defaulted init param; synthesized Codable gives decodeIfPresent back-compat, and the nil case encodes no key so the empty-mailbox boundary is byte-identical to before). `description` gains a "; pending runs: N" suffix only when present. New `renderedPendingRuns(_:)` produces the model-visible text (mentions status()/wait()/cancel(), one line per run).
    - `Compaction/Summarization.swift`: `apply(...)` gains `pendingRuns: [CompactionSegment.PendingRunSummary] = []`; when non-empty the synthesized boundary entry carries a second `.text` segment (`<entryId>-pending-runs`) with the rendering — chosen because the vendored fork's TranscriptConverter renders only `.text`/`.structure` segments into the model prompt, so a `.custom` segment alone would be invisible to the model. The `.custom(CompactionSegment)` stays last (existing consumers pattern-match `segments.last`). tokensAfter's two-pass build includes the new segment.
    - `Compaction/Compactor.swift`: `compact(...)` gains the defaulted `pendingRuns` pass-through, so the bare-session `noteCompaction` recipe and all existing callers are untouched.
    - `Session/RoutedSession.swift` `fold(...)`: reads `await mailbox.status()` at the moment the boundary is written (pure snapshot, no side effects) and maps RunStatus → PendingRunSummary. Covers both manual `compact()` and both auto-compaction tiers, since all funnel through `fold`.

    Tests (watched fail first — compile errors for the missing API, per new-API TDD — then pass):
    - `CompactionSegmentTests`: pendingRuns Codable round trip; legacy-JSON decode without the field (pendingRuns nil, all other fields intact).
    - `RoutedSessionCompactTests`: compact-with-parked-run round trip (parks a fake run via the SessionMailboxTests RunLatch pattern, updates progress, forces Summarization; asserts the recorded boundary segment carries exactly [token, op, progress] and the second text segment contains token/op/progress/"status()"); empty-mailbox no-op (pendingRuns nil, boundary keeps exactly [summary text, custom] — 2 segments).

    Double-check verdict was REVISE with one finding: the two signature changes broke 21 stale DocC selector links (`Compactor/compact(_:prompt:budget:summarizer:)` and `Summarization/apply(_:prompt:tokensBefore:priorStagesApplied:summarizer:)`) across Sources/Tests. Fixed every occurrence to the new `...pendingRuns:)` selectors (kanban historical records left frozen). Re-verified: `swift build` clean; `swift test` 722+20+12 tests green, zero failures.
  timestamp: 2026-08-05T01:53:28.415095+00:00
- actor: claude-code
  id: 01kz7t0gbk7pbmqambvaxm3nhh
  text: |-
    ### implement — changed
    - evidence: 6 files (production: Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift, Compactor.swift, Summarization.swift, Session/RoutedSession.swift; tests: Tests/FoundationModelsRouterTests/CompactionSegmentTests.swift, RoutedSessionCompactTests.swift) plus DocC-selector updates in TranscriptReconstruction.swift, CompactionPrompt.swift, CompactionStage.swift, Helpers/TranscriptTestHelpers.swift, and 3 eval-support files. swift build clean; swift test 722+20+12 tests, 0 failures.
    - next: /review (task left in doing)
  timestamp: 2026-08-05T01:53:34.067118+00:00
depends_on:
- 01KZ6MZPV6VDYYDBACD3G930C4
position_column: doing
position_ordinal: '80'
title: '[Router] Carry live completionTokens across the compaction boundary'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"The sandbox globals": "Rediscovery of in-flight work after compaction belongs to the run plane. … Router's compaction boundary carries the live `completionTokens` … A post-compaction model reads its pending work from the boundary. Then it calls `status()`." Added by the plan double-check: this behavior was owned by no task in any phase, and phases 2–5 would never pick it up.

## What
Research note: eventplan's analogy ("in the same way that boundary metadata keeps discovered-tool state") is aspirational — `Compaction/CompactionSegment.swift`'s `Content { liveWindowEntryIds, foldedEntryIds, tokensBefore, tokensAfter, stagesApplied, promptName }` carries no tool state of any kind today. This task creates the first such carrier.

- Add a field to `CompactionSegment.Content` (Codable; decode with `decodeIfPresent` so previously recorded segments load unchanged), e.g. `pendingRuns: [PendingRunSummary]?` with token, op, and latest progress detail per live parked run — read from the session's `SessionMailbox` at the moment the compaction boundary is written.
- On the post-compaction side, the boundary's pending-run summaries must be visible to the model the same way other boundary metadata is (in the compacted-transcript rendering), so a post-compaction model knows its tokens and can call `status()` for the live view.
- Keep it run-plane only: token, op, progress — never output content.

## Acceptance Criteria
- [ ] Compacting a session that holds a parked run records that run's `completionToken`, op, and latest progress in the boundary segment
- [ ] A previously recorded `CompactionSegment` JSON without the new field still decodes (back-compat)
- [ ] The post-compaction rendered boundary carries the pending-run summary; a session with no parked runs adds nothing
- [ ] `swift test` green

## Tests
- [ ] Extend Router's compaction tests (`Compaction/` suites, pattern from `CompactionRoundTripIntegrationTests`' hermetic siblings): compact-with-parked-run round trip; back-compat decode; empty-mailbox no-op
- [ ] `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first
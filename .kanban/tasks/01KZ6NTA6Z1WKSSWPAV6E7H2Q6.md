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
- actor: claude-code
  id: 01kz7w57gajapz8pssrtyew8fa
  text: |-
    ### review — findings
    - evidence: 1 finding recorded — Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:42 (add Sendable conformance). Scope: review sha HEAD~1..HEAD (f34ecf2), backend local. Engine counts: 3 findings / 3 confirmed / 1 refuted; 2 dropped per the existing-test exception (RoutedSessionCompactTests.swift:516, :542 — fixes require refactoring pre-existing SessionMailboxTests helpers untouched by this commit).
    - next: implementer fixes the Sendable finding, checks the box, then re-review
  timestamp: 2026-08-05T02:31:05.994100+00:00
- actor: claude-code
  id: 01kz7w970g2psy501fjcs5eytv
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 core files (CompactionSegment PendingRunSummary + pendingRuns, Summarization boundary text segment, RoutedSession.fold mailbox.status() read, CompactionSegmentTests + RoutedSessionCompactTests) + DocC selector updates
    - test: green — swift test, 754 passed, 0 failures, 32 expected gated skips
    - commit: f34ecf2
    - review: findings — 1: Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:42 (add Sendable conformance); engine 3 confirmed, 2 dropped per existing-tests rule
  timestamp: 2026-08-05T02:33:16.560640+00:00
- actor: claude-code
  id: 01kz7yhz4ykjcg040qmpcjyzj6
  text: |-
    Review-finding fix pass (Sendable finding) complete. What happened and what the next agent should know:

    - Finding fix: added explicit `Sendable` to `CompactionSegment`'s declaration (Compaction/CompactionSegment.swift). File sweep per the whole-file rule: `PendingRunSummary` and `Content` already declared Sendable — CompactionSegment was the only type in the file with the flagged shape.
    - Premise correction (per double-check, recorded so it is not carried forward as fact): the finding's stated risk ("risks concurrency violations") never existed. `PersistableCustomSegment` refines Apple's `Transcript.CustomSegment`, which refines `Sendable` (verified in the SDK swiftinterface: `public protocol CustomSegment : ... Swift::Sendable`), so the conformance was already inherited. The explicit restatement is documentation-only — same pattern as the declaration's existing explicit `Equatable`/`CustomStringConvertible`, which are also protocol-implied. This is also why the TDD RED step could not go red: the guard test compiled immediately.
    - TDD: added `compactionSegmentIsSendable` (compile-time `requiresSendable` guard) to CompactionSegmentTests; its comment states the inherited-conformance truth explicitly.
    - Self-review (`review working`) surfaced 3 additional findings — mapper/recording-mirror/resuming round-trip tests did not exercise `pendingRuns`. Fixed via the engine's own suggested route: `makeContent` now defaults `pendingRuns` to a shared `fixturePendingRun`, with explicit survival assertions in all three tests (plus the Codable field-by-field test). The nil/legacy path stays covered by the dedicated legacy-JSON decode test and RoutedSessionCompactTests' empty-mailbox test.
    - A later self-review pass demanded `public` on `renderedPendingRuns`; double-check refuted its premise (only caller is in-module Summarization; repo precedent keeps DocC-linked statics internal, e.g. Compactor.estimatedTokenCount). Reconciled by making the access level explicit — `internal static func` with a doc note — which removes the engine's flagged cause (implicit spelling) without widening the public API. Final `review working` after that: clean (0 findings).
    - Discovered work filed as ^syfeavd: OperationEventSegment has the same implicit-spelling declaration shape (different file, out of this finding's file scope), with the corrected premise recorded on that card.
    - Verification: swift build clean; swift test 723+20+12 = 755 tests, 0 failures (expected gated skips only).
  timestamp: 2026-08-05T03:13:00.574700+00:00
- actor: claude-code
  id: 01kz7yj5d8h3kng1t68bea2rrv
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift (explicit Sendable on CompactionSegment; renderedPendingRuns spelled `internal` with doc note), Tests/FoundationModelsRouterTests/CompactionSegmentTests.swift (Sendable guard test; fixturePendingRun default in makeContent + pendingRuns survival assertions in Codable/mapper/recording-mirror/resuming tests). Review finding checked on the card. swift build clean; swift test 723+20+12 = 755 tests, 0 failures; final `review working` clean (0 findings).
    - next: /review (task left in doing)
  timestamp: 2026-08-05T03:13:06.984533+00:00
- actor: claude-code
  id: 01kz7ymv7dahkz3gxkvzbrzx72
  text: |-
    ### test — green
    - evidence: `swift test` (iteration 2, post-findings-fix) — 723 + 20 + 12 = 755 tests passed across 3 test runs, 0 failed; 32 gated skips (expected, `FM_ROUTER_INTEGRATION_TESTS` not set); only the known pre-existing llbuild warning "missing creator for mutated node" from the mlx-swift `Cmlx.bundle` — no new warnings
    - next: hand off to review
  timestamp: 2026-08-05T03:14:34.861703+00:00
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
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-08-04 20:59)

- [x] `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:42` — CompactionSegment should conform to Sendable. The struct contains only immutable fields (all `let`), its nested types PendingRunSummary and Content both explicitly conform to Sendable, and in a router/session architecture this type likely crosses actor/task boundaries. The absence of explicit Sendable conformance when nested types have it is inconsistent and risks concurrency violations. Add `Sendable` to line 42: `public struct CompactionSegment: PersistableCustomSegment, Equatable, CustomStringConvertible, Sendable`.

Note: two engine findings (RoutedSessionCompactTests.swift:516 RunLatch extraction, :542 parkFakeRun reuse) were dropped under the review skill's written exception — each requires refactoring pre-existing test helpers in SessionMailboxTests.swift, untouched by this commit. #phase-1 #router-first
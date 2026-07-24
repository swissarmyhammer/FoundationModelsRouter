---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky8q4cbkrzvxg9j6zxvv46dn
  text: |-
    Implemented via TDD (wrote Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift first, watched it fail to compile with "value of type 'any RoutedSession' has no member 'compact'", then implemented production code to make it pass).

    Research findings before implementing:
    - contextFill/contextTokens/usageState already existed on RoutedSession/RoutedSessionActor from a prior task — only compact() itself was missing.
    - Compactor.compact(_:prompt:budget:summarizer:), CompactionResult, CompactionPrompt, TokenBudget, CompactionSegment, TranscriptDiffer.diffByEntryId (already built for RecordingLanguageModel.noteCompaction and explicitly documented as "the counterpart to RoutedSessionActor's in-place compact() swap") were all already in place from earlier build-order steps.
    - No existing mechanism to rebuild a LanguageModelSessionBackend from an arbitrary Transcript while keeping the same underlying model/tools — added a new LanguageModelSessionBackend requirement `replacingTranscript(_:)` (default extension forwards to makeFork(), so none of the ~15 other test-stub conformers needed changes) with real implementations on StubSessionBackend and the live MLXFoundationModelsSessionBackend.

    Design decision worth flagging: the model-assisted Summarization stage's summarizer must NOT reuse the session's own live/accumulating backend directly — doing so would (a) risk exceeding the real context window (the very reason compaction is running), (b) inject an extra "please summarize" turn into the live conversation being folded away, and (c) leak one map-reduce chunk's prompt/response into the next chunk's context. Solved by building a fresh, disposable backend per summarize() call via `backend.replacingTranscript(Transcript(entries: []))` (a blank-slate session over the same resident model) — `BackendCompactionSummarizer` in RoutedSession.swift.

    `RoutedSessionActor.backend` changed from `nonisolated let` to a plain actor-isolated `var` so compact() can swap it; verified via build that no isolation errors result (all access sites are already actor-isolated).

    Tests: Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift, 6 tests, all green:
    - compact() shrinks the live window + accurate CompactionResult
    - id/recordingDirectory preserved + append-only recording + summary entry with CompactionSegment appended
    - respond() works normally after compaction (follow-up turn records as normal append)
    - compact() with no args resolves CompactionPrompt.default + contextTokens-based budget
    - compact(prompt:) threads a custom prompt name into the recorded CompactionSegment
    - compact() with an already-under-budget transcript is a no-op (stagesApplied empty, nothing recorded)

    Full suite: 470 tests / 51 suites passing (baseline was 464/50 before this task). Zero warnings, zero diagnostics. Adversarial double-check dispatched to verify design (actor isolation safety, throw-path state consistency, diff/append-only correctness, test determinism) — will act on findings before finishing.
  timestamp: 2026-07-24T00:06:47.923630+00:00
- actor: claude-code
  id: 01ky8qw55j8vvtbz8v0g5tj2mm
  text: |-
    Adversarial double-check verdict: REVISE — one finding: no test exercised the throw path (summarizer fails mid-fold) to verify session.id/recordingDirectory/contextFill/recorded events stay untouched. Added `compactLeavesSessionUntouchedWhenSummarizerThrows` to RoutedSessionCompactTests.swift covering exactly that (flips `StubSessionBackend.shouldThrow` on the live backend before calling compact(), confirms `Compactor.compact`'s throw propagates before any of backend/persistedEntryCount/usageState are touched, then confirms a subsequent respond() still works normally). Everything else in the double-check passed on inspection (id-based diff/append-only correctness, BackendCompactionSummarizer design, actor-isolation safety of the now-mutable `backend` var, test budget-math determinism).

    Final state: 471 tests / 51 suites passing (was 464/50 baseline), zero build warnings, zero diagnostics. Task left in `doing` for /review.
  timestamp: 2026-07-24T00:19:46.994833+00:00
depends_on:
- 01KXTFS4FNT1P5F889D1PEQ9N7
- 01KXTFSXYF1SH9WQ9Z2E3B6D6V
- 01KXTFT9V4EPQJFJADAK36ZY10
position_column: doing
position_ordinal: '80'
title: 'RoutedSession.compact(): in-place fold on the actor'
---
## What
The session-level entry point (compaction_plan.md §1.4, requirement 1) in `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:

- Add to the `RoutedSession` protocol:
  `@discardableResult func compact(prompt: CompactionPrompt, budget: TokenBudget?) async throws -> CompactionResult` (defaults `.default` / `nil` via extension or defaulted parameters; `budget: nil` means the profile's resolved working context).
- Implement on `RoutedSessionActor` **on top of the bare primitives** (one mechanism, two entry points): run `Compactor.compact` over the current transcript (summarizer defaults to the session's own model; profile `flash` slot is the documented override), call the recorder path equivalent of `noteCompaction` so the summary entry + `CompactionSegment` reach `transcript.jsonl` append-only, then swap the inner Apple session in place — same actor, same nonisolated `id: ULID`, same recorder, same transcript directory and `sessions.jsonl` identity (requirement 4 by construction).
- Reactive recovery path documented in the API docs: catch `exceededContextWindowSize`, compact with a lowered target, retry once (§1.5 tail).
- Update conformers/stubs (`Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift`, any test doubles conforming to `RoutedSession`).

## Acceptance Criteria
- [x] `compact()` shrinks the live window (post-compact `contextFill` < pre-compact), returns an accurate `CompactionResult`
- [x] `session.id` and the transcript directory are byte-identical before/after; recording is append-only (pre-fold events untouched)
- [x] `respond`/`streamResponse` work normally after compaction; a follow-up turn records as a normal append
- [x] Default prompt/budget resolve as specified when omitted

## Tests
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift` — with stub backend + fake summarizer: id stability, append-only recording, result accuracy, defaults resolution, post-compact turn
- [x] `swift test --filter RoutedSessionCompact` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
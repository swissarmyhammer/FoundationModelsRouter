---
assignees:
- claude-code
depends_on:
- 01KXTFS4FNT1P5F889D1PEQ9N7
- 01KXTFSXYF1SH9WQ9Z2E3B6D6V
- 01KXTFT9V4EPQJFJADAK36ZY10
position_column: todo
position_ordinal: '8780'
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
- [ ] `compact()` shrinks the live window (post-compact `contextFill` < pre-compact), returns an accurate `CompactionResult`
- [ ] `session.id` and the transcript directory are byte-identical before/after; recording is append-only (pre-fold events untouched)
- [ ] `respond`/`streamResponse` work normally after compaction; a follow-up turn records as a normal append
- [ ] Default prompt/budget resolve as specified when omitted

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift` — with stub backend + fake summarizer: id stability, append-only recording, result accuracy, defaults resolution, post-compact turn
- [ ] `swift test --filter RoutedSessionCompact` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
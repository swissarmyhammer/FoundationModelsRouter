---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky9awxdyajnsfrsmyjeje00f
  text: |-
    Research: read compaction_plan.md in full plus the actual implemented sources (RoutedSession.compact(prompt:budget:)/contextFill, TokenBudget, CompactionPrompt, CompactionResult, Compactor, CompactionStage/ToolOutputElision/TurnTruncation/Summarization, CompactionSegment, RecordingLanguageModel.noteCompaction) and existing tests (RoutedSessionCompactTests, NoteCompactionTests, CompactionSegmentTests, CompactorPipelineTests, CompactionStageTests). Confirmed: no .docc catalog exists anywhere under Sources/ (only vendored dependency checkouts have one) — this repo's established convention is rich prose doc comments on the public API, which was already followed exceptionally thoroughly for every compaction symbol by the prior implementation tasks (every public symbol already had a doc comment; verified via an awk sweep of Compaction/*.swift + RoutedSession.swift + RecordingLanguageModel.swift finding zero undocumented public declarations).

    What was actually missing per the acceptance criteria:
    1. The reactive-pattern doc example on RoutedSession.compact(prompt:budget:) caught a bare `catch { }` rather than a specific error type. Looked up the actual macOS 27 FoundationModels.swiftinterface (Xcode-beta SDK) and confirmed `LanguageModelError.contextSizeExceeded(_:)` is the current, non-deprecated API for context overflow (the plan's `GenerationError.exceededContextWindowSize` is deprecated as of macOS 27, on a *different* error type than this repo's own unrelated `RoutedLLM.GenerationError`). Updated the doc comment to catch `LanguageModelError.contextSizeExceeded` specifically, per the /finish orchestration instruction to reflect real implemented API rather than the plan's original sketch.
    2. Tests/FoundationModelsRouterTests/ExamplesTests.swift had no compaction example at all. Added a new "MARK: - Compaction" section with two tests mirroring the doc comment's two code samples: `proactiveCompactionBetweenTurns()` (drives contextFill to 0.3/0.6/0.9 via a mutated StubSessionBackend.usageIncrement, compacts once the 0.80 trigger is crossed) and `reactiveCompactionRecoversFromContextOverflow()` (a private `respondWithReactiveCompaction` helper copied verbatim from the doc comment's own catch/compact/retry shape, driven against a new `OverflowOnceBackend` stub that throws `LanguageModelError.contextSizeExceeded` once then recovers).

    Verification: `swift build` and `swift build --build-tests` clean, zero warnings from own code (only a pre-existing unrelated SwiftPM "missing creator for mutated node" warning about the vendored mlx-swift Cmlx bundle). `swift test` full run: 484 tests in the main unit target + 17 in the gated integration target (all skip/pass, none failing) + 5 in the evals target — all green, 0 failures. Baseline before this task's 2 new tests was 482+17+5=504, matching the orchestration prompt's stated baseline exactly.

    No swift-docc-plugin dependency exists in Package.swift, so there is no "swift package generate-documentation" step in this repo to run — that acceptance criterion is conditional ("if the repo has a docs build step") and does not apply.

    Adversarial double-check agent dispatched to review the diff before handoff.
  timestamp: 2026-07-24T05:52:14.782595+00:00
- actor: claude-code
  id: 01ky9bgbnjwhjcyn1ptn75gx0a
  text: |-
    Adversarial double-check (via the double-check agent) returned REVISE with one high-severity finding: `reactiveCompactionRecoversFromContextOverflow` was vacuous — `OverflowOnceBackend`'s first call threw before appending anything to its transcript, so `compact(budget:)` always no-op'd (empty transcript, stagesApplied empty, no backend swap) and the test only proved the stub's one-time-overflow-then-recover behavior, not that `compact()` did anything. It would have stayed green even if the `compact()` call were deleted from the reactive pattern.

    Fixed: `OverflowOnceBackend` now takes seed transcript content at construction (`seedEntries(turnCount:responseText:)`, 6 synthetic turns — more than TurnTruncation's 4-turn recency window) and a shared `ReplaceSpy` that counts `replacingTranscript(_:)` calls (only reachable when compact() performs a genuine, non-empty-stagesApplied fold). The test derives a `contextTokens` value from the seeded transcript's real recency-window-only estimate vs. full pre-fold estimate (mirroring RoutedSessionCompactTests' derivation technique) so the reactive pattern's hardcoded `target: 0.35` lands strictly between them — guaranteeing `TurnTruncation` alone lands under target — then asserts `replaceSpy.replaceCount == 1` in addition to the recovered reply.

    Verified the fix is real, not just plausible-looking: temporarily reverted the `compact()` line inside `respondWithReactiveCompaction` back out (commented it), reran `swift test --filter reactiveCompactionRecoversFromContextOverflow` — it now correctly FAILS (`replaceSpy.replaceCount == 1 → false, replaceSpy.replaceCount → 0`) — then restored the line and reran to confirm GREEN again. Full-suite `swift test` after the fix: still 484+17+5 = 506 tests, 0 failures, build clean.

    Also addressed the double-check's two low/informational findings: softened the `proactiveCompactionBetweenTurns` test's description from "mirrors ... own doc example" to "exercises the shape of ... own doc example" (it's pattern-equivalent, not a verbatim textual copy, since it goes through an explicit `TokenBudget` rather than the doc's hardcoded `0.80`/zero-arg `compact()`); added a one-line doc clarification on `RoutedSession.compact(prompt:budget:)`'s reactive-pattern sample explaining where an external caller's `contextTokens` comes from (a resolved slot's `SlotResolution.contextTokens`, e.g. `profile.standard.resolution.contextTokens`).

    Task remains in `doing`, green, ready for `/review`.
  timestamp: 2026-07-24T06:02:51.954821+00:00
depends_on:
- 01KXTFVEAQCJSE7CXA8RJVRGT9
position_column: doing
position_ordinal: '80'
title: 'DocC: compaction guide with proactive/reactive patterns'
---
## What
Document compaction (compaction_plan.md §6.10) in the package's DocC (follow the existing documentation convention — DocC catalog if one exists, otherwise rich doc comments on the public API):

- `compact(prompt:budget:)`, `contextFill`, `TokenBudget`, `CompactionPrompt`, `CompactionResult`, `Compactor`, `noteCompaction` — full doc comments with the invariants (append-only recording, checkpoint restore, stable session id).
- The **proactive pattern** as the inline example: check `contextFill >= budget.trigger` between turns — turns never die.
- The **reactive pattern** as the documented recovery path: catch `exceededContextWindowSize`, compact with a lowered target, retry once.
- The bare-session recipe: `Compactor.compact` + `noteCompaction` + rebuild `LanguageModelSession(model: same handle, tools:, transcript:)`.
- Custom prompts: passing a named `CompactionPrompt`, and that the name is recorded in the `CompactionSegment` for eval attribution.

## Acceptance Criteria
- [ ] Every new public symbol has a doc comment; the proactive and reactive patterns appear as compilable inline examples
- [ ] `swift build` emits no documentation-related warnings for the new symbols

## Tests
- [ ] Doc example snippets are mirrored by (or extracted into) test cases in `Tests/FoundationModelsRouterTests/ExamplesTests.swift` so they cannot rot; `swift test --filter Examples` passes
- [ ] If the repo has a docs build step (e.g. `swift package generate-documentation`), it completes without errors

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
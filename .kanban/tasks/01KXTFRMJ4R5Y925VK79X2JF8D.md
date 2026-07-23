---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7s437bq4ve5h7f63jwxz26
  text: |-
    Implemented via TDD. Wrote 3 new tests in RecordingLanguageModelTests.swift (syncWithUsageStampsTokens, syncWithoutUsageLeavesTokensNil, multiTurnSyncStampsPerTurnUsage) — confirmed RED (compile error "Extra argument 'usage' in call") before implementing.

    Changes:
    - Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift: `RecordingLanguageModel.sync(_:usage:)` and `RecordingLanguageModelState.sync(_:usage:)` now take `usage: (input: Int, output: Int)? = nil` (defaulted, existing callers unaffected). Threaded through `enterGateAndDiff(_:usage:)` into `diffAndRecord(current:usage:)`, which finds the diff's *last* `.response`-kind partial (mirroring RoutedSessionActor.recordTranscriptDelta's placement) and stamps tokensIn/tokensOut onto only that partial via the new `TranscriptEvent.Partial.stampingUsage(tokensIn:tokensOut:)` helper.
    - Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift: added `Partial.stampingUsage(tokensIn:tokensOut:)`, a copy-with-tokens-replaced helper mirroring the existing `mapBody` pattern. TranscriptDiffer itself untouched — stays narrow per its own doc comment.

    `swift test --filter RecordingLanguageModel` — 11/11 pass (8 existing + 3 new). Running full swift build / build --build-tests / swift test next for really-done verification.
  timestamp: 2026-07-23T15:22:21.291098+00:00
- actor: claude-code
  id: 01ky7scdtaatb7g96zfypmqzm4
  text: |-
    really-done verification complete:
    - swift build: green (only known pre-existing mlx-swift_Cmlx.bundle warning)
    - swift build --build-tests: green
    - swift test --filter RecordingLanguageModel: 11/11 pass
    - swift test (full suite): 419 tests in 45 suites passed (416 baseline + 3 new), 16 gated/skipped in 6 suites unchanged — zero regressions

    Adversarial double-check agent (subagent_type: double-check): verdict PASS, no findings. It independently re-ran build/build-tests/filtered-test/full-test and confirmed the diff — including that the last-`.response`-kind stamping logic matches RoutedSessionActor's own placement, the shrink-guard correctly skips stamping, tool-using turns' `.toolCalls`/`.toolOutput` kinds never collide with `.response`, the multi-turn test genuinely proves non-cumulative behavior (10/5 then 7/3, not 17/12), TranscriptDiffer.swift is untouched, and no other in-Sources caller of `.sync(` exists to update.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-23T15:26:54.282308+00:00
position_column: doing
position_ordinal: '80'
title: 'Handle usage stamping: sync(_:usage:) on RecordingLanguageModel'
---
## What
Close the recording gap in compaction_plan.md §1.5: events recorded through the `RecordingLanguageModel` handle carry `tokensIn: nil` because `TranscriptDiffer` is deliberately narrow and no handle-path caller supplies turn stamps.

Extend the handle's public turn-end hook in `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` — `public func sync(_ transcript: Transcript)` — to `sync(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil)` (defaulted so existing callers keep compiling). When usage is supplied, the handle stamps `tokensIn`/`tokensOut` onto the turn-final `.response` event it syncs, matching what `RoutedSessionActor.recordTranscriptDelta(grammar:since:usage:)` already does on the routed path. `TranscriptDiffer` (`Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift`) stays narrow — stamping happens at the handle layer.

The turn owner holds the session and reads `session.usage` (per-turn delta, same convention as the actor path: `LanguageModelSessionBackend.usageTokenCounts()` in `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`). Update the internal `sync` call path (line ~315 region) as needed and any in-repo call sites/examples that should now pass usage.

## Acceptance Criteria
- [ ] `sync(_:usage:)` with usage stamps `tokensIn`/`tokensOut` on the synced turn-final `.response` event in that session's `transcript.jsonl`
- [ ] `sync(_:)` without usage behaves exactly as today (nil stamps, no behavior change)
- [ ] Existing callers compile unchanged (defaulted parameter)

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift` (or add `RecordingHandleUsageStampTests.swift`): sync with usage → recorded `.response` event carries the stamps; sync without → nil; multi-turn deltas stamp per-turn, not cumulative
- [ ] `swift test --filter RecordingLanguageModel` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
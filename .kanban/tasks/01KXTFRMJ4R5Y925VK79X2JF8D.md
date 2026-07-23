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
- actor: claude-code
  id: 01ky7tvngdc44yf2bk1whaj8j8
  text: |-
    Resolved review finding: extracted the shared copy-with-modification helper.

    In Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift, added a private `Partial.with(text:tokensIn:tokensOut:entry:)` that builds the single underlying `Partial(...)` construction. Both `mapBody(_:)` and `stampingUsage(tokensIn:tokensOut:)` now call it instead of each hand-rolling a full `Partial` copy:
    - `mapBody` → `with(text: mappedText, entry: mappedEntry)`
    - `stampingUsage` → `with(tokensIn: tokensIn, tokensOut: tokensOut)`

    The helper's parameters are doubly-optional (`String??`, `Int??`, `TranscriptEntryPayload??`), defaulting to `nil` (outer optional) meaning "leave this field as-is" — falls back to `self.field` via `param ?? self.field`. A caller that explicitly passes a `nil` value (inner optional, e.g. `mappedText == nil` from `GatingRecorder`'s trimming/redaction transforms) still gets that field overwritten to `nil`, because Swift's optional-to-optional argument promotion wraps the passed `String?` into `.some(nil)` at the `String??` parameter. Verified this preserves old behavior exactly for both callers, since each always passes its own fields explicitly and never touches the other's.

    Checked the finding's checkbox in the description.

    really-done verification (fresh run):
    - swift build: green (only the known pre-existing mlx-swift_Cmlx.bundle warning)
    - swift build --build-tests: green (removed stale default.metallib first, per repo convention)
    - swift test: 419 tests in 45 suites passed, 16 gated/skipped in 6 suites — matches the prior verified baseline exactly, zero failures/regressions

    Adversarial double-check agent (subagent_type: double-check): verdict PASS. Independently confirmed both methods route through the same `with(...)` call, traced the doubly-optional semantics against pre-diff behavior via `git show HEAD:...`, checked all call sites (RoutedSession.swift, GatingRecorder.swift, RecordingLanguageModel.swift) are unaffected, re-ran build/build-tests/test fresh with matching results, and confirmed the diff is scoped to this one file.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-23T15:52:42.253511+00:00
position_column: doing
position_ordinal: '80'
title: 'Handle usage stamping: sync(_:usage:) on RecordingLanguageModel'
---
## What
Close the recording gap in compaction_plan.md §1.5: events recorded through the `RecordingLanguageModel` handle carry `tokensIn: nil` because `TranscriptDiffer` is deliberately narrow and no handle-path caller supplies turn stamps.

Extend the handle's public turn-end hook in `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` — `public func sync(_ transcript: Transcript)` — to `sync(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil)` (defaulted so existing callers keep compiling). When usage is supplied, the handle stamps `tokensIn`/`tokensOut` onto the turn-final `.response` event it syncs, matching what `RoutedSessionActor.recordTranscriptDelta(grammar:since:usage:)` already does on the routed path. `TranscriptDiffer` (`Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift`) stays narrow — stamping happens at the handle layer.

The turn owner holds the session and reads `session.usage` (per-turn delta, same convention as the actor path: `LanguageModelSessionBackend.usageTokenCounts()` in `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`). Update the internal `sync` call path (line ~315 region) as needed and any in-repo call sites/examples that should now pass usage.

## Acceptance Criteria
- [x] `sync(_:usage:)` with usage stamps `tokensIn`/`tokensOut` on the synced turn-final `.response` event in that session's `transcript.jsonl`
- [x] `sync(_:)` without usage behaves exactly as today (nil stamps, no behavior change)
- [x] Existing callers compile unchanged (defaulted parameter)

## Tests
- [x] Extend `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift` (or add `RecordingHandleUsageStampTests.swift`): sync with usage → recorded `.response` event carries the stamps; sync without → nil; multi-turn deltas stamp per-turn, not cumulative
- [x] `swift test --filter RecordingLanguageModel` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction

## Review Findings (2026-07-23 10:41)

- [x] `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:248` — stampingUsage duplicates the Partial copy-with-modification pattern from mapBody. Both methods construct a new Partial with nearly identical field assignments, differing only in which fields are modified. Extract a shared helper method that accepts optional parameters for fields to modify, such as `with(text:tokensIn:tokensOut:entry:)`, to eliminate the repeated Partial construction pattern and reduce maintenance burden if Partial's fields change.
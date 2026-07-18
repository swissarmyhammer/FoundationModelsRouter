---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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
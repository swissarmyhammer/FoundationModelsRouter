---
assignees:
- claude-code
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
- 01KXTFS4FNT1P5F889D1PEQ9N7
position_column: todo
position_ordinal: '8880'
title: 'Checkpoint-aware reconstruction: restore view, fullHistory view, sidecar count'
---
## What
Teach reconstruction the compaction checkpoint (compaction_plan.md §3, requirement 3):

- `Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift` — `effectiveTranscript` (which already interprets events, e.g. skipping failed-turn bodyless closes) learns `CompactionSegment`: the default (restore) view finds the **newest** compaction entry and rebuilds the live window from its ordered entry ids plus every entry recorded after it. Add a `fullHistory` option that keeps every entry in `seq` order for browsers, rendering the compaction entry as a fold marker (never duplicating the summary against what it replaced). Repeated compactions nest: only the newest checkpoint governs restore; earlier ones are historical markers.
- `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` — `restoreSessionTree` hands back sessions whose live window is the checkpointed view (compacted, under budget).
- `Sources/FoundationModelsRouter/Recording/SessionSidecar.swift` — optional compaction count so browsers can badge folded sessions.
- Restored `contextFill` (seam left by the TokenBudget task): newest stamped `.response` event **after** the newest checkpoint; if the compaction entry is the newest thing, the `CompactionSegment.tokensAfter`; else unknown.

## Acceptance Criteria
- [ ] Restore view = checkpoint's ordered live-window entries + everything after it — never the full pre-compaction history
- [ ] `fullHistory` view retains every event in `seq` order with the compaction entry as a fold marker
- [ ] Repeated compactions: only the newest checkpoint governs restore
- [ ] `restoreSessionTree` restores a compacted, under-budget session with unchanged id; sidecar carries the compaction count
- [ ] Restored fill: stamp-after-checkpoint > checkpoint `tokensAfter` > unknown, in that precedence

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift` and `SessionTreeRestorationTests.swift`: fixture `transcript.jsonl` files with zero/one/multiple checkpoints; both views; sidecar count; restored-fill precedence; old recordings (no checkpoint) restore exactly as today
- [ ] `swift test --filter 'TranscriptReconstruction|SessionTreeRestoration'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
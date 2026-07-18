---
assignees:
- claude-code
depends_on:
- 01KXTFQVKKDB1PPCXZQDWS80MS
- 01KXTFS4FNT1P5F889D1PEQ9N7
position_column: todo
position_ordinal: '8480'
title: Deterministic stages + Compactor pipeline (ToolOutputElision, TurnTruncation)
---
## What
Build the model-free half of the compaction pipeline (compaction_plan.md §1.3) in `Sources/FoundationModelsRouter/Compaction/`:

- `Compactor.swift` — `Compactor.compact(_ transcript: Transcript, budget: TokenBudget) -> CompactionResult` pipeline skeleton: stages run in order until under target; prospective size check uses a character-ratio estimate calibrated by the measured pre-fold count (§1.5). `TokenBudget` comes from the token-accounting task (1peq9n7 — a dependency of this task). The model-free pipeline takes NO prompt parameter — the Summarization task (e3b6d6v) adds the `prompt: CompactionPrompt` parameter when it wires in the final stage. Define `CompactionResult { summary: String?, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String] }` here; `summary` stays nil for model-free runs.
- `ToolOutputElision.swift` — `keepRecentTurns: 4` default; replaces `toolOutput` payloads older than the recency window with a one-line placeholder naming the tool; `toolCalls`/`toolOutput` pairing preserved (only payloads shrink).
- `TurnTruncation.swift` — `keepRecentTurns: 4` default; drops oldest complete turns; never splits a turn or orphans a tool pair.

Invariants (assert in tests): instructions never modified or dropped; tool pairs kept/elided/dropped together; the recency window survives verbatim; stages are pure (`Transcript → Transcript`, same input → same output); a transcript whose tail alone exceeds target is returned unchanged with the shortfall reported in `CompactionResult`.

## Acceptance Criteria
- [ ] Each stage is a pure function over `Transcript`; every §1.3 invariant holds on fixture transcripts
- [ ] Pipeline stops as soon as a stage lands under target; `stagesApplied` records exactly the stages run
- [ ] Oversized-tail transcript returned unchanged with shortfall reported
- [ ] Compiles with only this task's and its dependencies' types — no forward references to `CompactionPrompt`

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CompactionStageTests.swift` — fixture transcripts (mixed prompt/response/tool traffic) covering every invariant, elision placeholder content, turn-boundary edge cases (tool pair at the window edge, transcript with only instructions, fewer turns than keepRecentTurns)
- [ ] `Tests/FoundationModelsRouterTests/CompactorPipelineTests.swift` — stage ordering, early stop, oversized-tail shortfall
- [ ] `swift test --filter 'CompactionStage|CompactorPipeline'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction
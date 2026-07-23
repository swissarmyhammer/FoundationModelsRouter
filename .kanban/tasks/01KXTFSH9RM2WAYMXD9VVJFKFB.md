---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky85gq4jmc63bvas3cbrsxq9
  text: |-
    Implemented via TDD (wrote CompactionStageTests.swift + CompactorPipelineTests.swift first, confirmed RED via `swift build --build-tests` compile failure, then implemented production code, confirmed GREEN).

    Files added under Sources/FoundationModelsRouter/Compaction/:
    - TranscriptTurns.swift — internal `TranscriptTurn`/`TranscriptTurns.split(_:)`/`.partition(_:keepRecentTurns:)`: shared turn-boundary logic both stages build on. A "turn" = a `.prompt` entry through everything up to (not including) the next `.prompt`; everything before the first `.prompt` (normally just `.instructions`) is the untouchable "header".
    - CompactionStage.swift — `public protocol CompactionStage: Sendable { static var stageName: String; func apply(_ transcript: Transcript) -> Transcript }`. Only the two deterministic stages conform; the later async/model-assisted Summarization stage wires in differently.
    - ToolOutputElision.swift / TurnTruncation.swift — both `keepRecentTurns: Int = 4`, pure `apply(_:) -> Transcript`.
    - Compactor.swift — `CompactionResult` (exactly the 4 fields the task specifies: summary/tokensBefore/tokensAfter/stagesApplied) + `Compactor.compact(_ transcript:budget:)`.

    One deliberate deviation worth flagging: the task text and compaction_plan.md both write the signature as `Compactor.compact(_ transcript: Transcript, budget: TokenBudget) -> CompactionResult`, but CompactionResult (as literally specified, 4 fields) carries no Transcript. Since compaction_plan.md §1.1 defines compaction itself as a pure `Transcript -> Transcript` function, and both downstream consumers (RoutedSessionActor.compact swapping its inner session; the bare-session recipe calling `noteCompaction(_ compacted: Transcript)`) need the folded transcript itself, a `-> CompactionResult`-only return would make the pipeline non-functional for its stated purpose. Implemented as `-> (transcript: Transcript, result: CompactionResult)` instead — CompactionResult's shape is unchanged from spec. Flagging this so the Summarization task (e3b6d6v) and RoutedSession.compact task (ffsjqha) know to expect the tuple return rather than bare CompactionResult.

    Token estimation: no live measurement is available at this pure-Transcript layer, so `Compactor.estimatedTokenCount(of:)` estimates via a character-ratio heuristic (4.0 chars/token, documented) applied to the JSON-encoded byte size of each entry's `TranscriptEntryPayload` mirror (reusing `TranscriptEntryMapper.event(from:)` — covers every entry kind's content, not just `.text` segments). Tests derive expected before/after relationships from this same function rather than hand-computed constants, to stay robust to the payload's exact JSON shape.

    Pipeline semantics: stops as soon as a stage's estimated result is <= target; already-under-target transcripts run zero stages; the oversized-tail case (recency window alone exceeds target) returns the *original* transcript unchanged with `stagesApplied == []`, reporting the shortfall via `tokensAfter` (still > target, visible to the caller who has the budget).

    Verification: `swift test --filter 'CompactionStage|CompactorPipeline'` — 15/15 new tests passed. Full `swift build`, `swift build --build-tests`, `swift test` run next.
  timestamp: 2026-07-23T18:58:57.810947+00:00
- actor: claude-code
  id: 01ky86s512f5c6yd9w8429b12r
  text: |-
    Adversarial double-check (via really-done) ran on the initial implementation and returned REVISE with two findings, both fixed:

    1. (High) `Compactor.compact`'s oversized-tail branch reported `tokensAfter` as the size of the discarded, fully-elided-and-truncated `current` transcript rather than the size of what the function actually returns (the unchanged original `transcript`). Contradicted the struct's own doc comment and would mislead a caller (e.g. a future RoutedSessionActor.compact) about how close the returned transcript is to budget. The original test for this path only used 2 turns against keepRecentTurns=4, so `old` was always empty and `current` stayed identical to `transcript` — masking the bug. Fixed: oversized-tail branch now returns `tokensAfter: tokensBefore`. Added a regression test (`oversizedTailWithOldTurnsReportsTokensAfterForTheReturnedTranscript`) with 6 turns (old turns non-empty, so `current` really does shrink inside the pipeline loop) — watched it fail red against the bug, confirmed green after the fix.

    2. (Low) `TranscriptTurns.partition(_:keepRecentTurns:)` treated `keepRecentTurns <= 0` as "protect everything" (old: [], recent: turns) — backwards from "keep the newest zero turns," and undocumented/untested. Fixed: `keepRecentTurns <= 0` now correctly means "protect nothing" (old: turns, recent: []), documented on the function, with a new regression test (`nonPositiveKeepRecentTurnsProtectsNoTurns`) — watched red, confirmed green.

    Both fixes done via TDD (test added, watched fail for the right reason, fixed production code, watched pass). Re-ran the full suite after fixing: `swift build`, `swift build --build-tests`, `swift test` all green — 451 tests in 49 suites passing (baseline 434 + 17 new stage/pipeline tests), 16 gated/skipped in 6 suites unchanged, zero failures, only the known pre-existing mlx-swift_Cmlx.bundle warning.

    Task left in `doing`, green, ready for `/review`. All 4 acceptance-criteria checkboxes and both Tests-section items are satisfied; not checking them off in the description per the kanban-corruption note in memory — verified manually instead.
  timestamp: 2026-07-23T19:21:02.754088+00:00
- actor: claude-code
  id: 01ky89r3kmdkxb0mfy9vh78xe8
  text: |-
    Addressed the 3 review findings (test-file duplication of makeInstructions()/makeTurn()/makeTurns() between CompactionStageTests.swift and CompactorPipelineTests.swift).

    Checked Tests/FoundationModelsRouterTests/Helpers/ first: only StubSessionBackend.swift existed there (a session-backend stub, unrelated to transcript-fixture construction), so no existing helper covered this ground — created a new file rather than extending an unrelated one.

    Fix: created Tests/FoundationModelsRouterTests/Helpers/TranscriptTestHelpers.swift with `enum TranscriptFixtures` holding `makeInstructions()`, `makeTurn(index:promptText:toolOutputText:responseText:)`, and `makeTurns(_:toolOutputText:)` — byte-identical bodies to what both test files had duplicated. Removed the duplicated private static funcs from both CompactionStageTests.swift and CompactorPipelineTests.swift, and rewrote every call site (`Self.makeInstructions()` -> `TranscriptFixtures.makeInstructions()`, etc.) in both files. CompactorPipelineTests.swift's own `makeBudget(targetTokens:)` helper (not part of the duplication — unique to that file) was left untouched.

    Note: found a 4th, pre-existing occurrence of a similar `makeInstructions()` in CompactionSpikeTests.swift — NOT touched, since it wasn't one of the 3 findings and the task said no unrelated refactors. Flagging in case a future cleanup wants to fold it in too.

    Verification: swift build, swift build --build-tests, swift test all green — 451 tests in 49 suites passed, 16 gated/skipped in 6 suites unchanged, zero failures, only the known pre-existing mlx-swift_Cmlx.bundle warning. Matches the prior verified baseline exactly (no test count regression/change, since this was a pure test-code refactor).

    Checked all 3 review-finding checkboxes in the description. Task left in `doing` per /implement process (pulled back from `review`), ready for `/review` to re-verify.
  timestamp: 2026-07-23T20:12:54.260863+00:00
depends_on:
- 01KXTFQVKKDB1PPCXZQDWS80MS
- 01KXTFS4FNT1P5F889D1PEQ9N7
position_column: doing
position_ordinal: '80'
title: Deterministic stages + Compactor pipeline (ToolOutputElision, TurnTruncation)
---
## What
Build the model-free half of the compaction pipeline (compaction_plan.md §1.3) in `Sources/FoundationModelsRouter/Compaction/`:

- `Compactor.swift` — `Compactor.compact(_ transcript: Transcript, budget: TokenBudget) -> CompactionResult` pipeline skeleton: stages run in order until under target; prospective size check uses a character-ratio estimate calibrated by the measured pre-fold count (§1.5). `TokenBudget` comes from the token-accounting task (1peq9n7 — a dependency of this task). The model-free pipeline takes NO prompt parameter — the Summarization task (e3b6d6v) adds the `prompt: CompactionPrompt` parameter when it wires in the final stage. Define `CompactionResult { summary: String?, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String] }` here; `summary` stays nil for model-free runs.
- `ToolOutputElision.swift` — `keepRecentTurns: 4` default; replaces `toolOutput` payloads older than the recency window with a one-line placeholder naming the tool; `toolCalls`/`toolOutput` pairing preserved (only payloads shrink).
- `TurnTruncation.swift` — `keepRecentTurns: 4` default; drops oldest complete turns; never splits a turn or orphans a tool pair.

Invariants (assert in tests): instructions never modified or dropped; tool pairs kept/elided/dropped together; the recency window survives verbatim; stages are pure (`Transcript → Transcript`, same input → same output); a transcript whose tail alone exceeds target is returned unchanged with the shortfall reported in `CompactionResult`.

## Acceptance Criteria
- [x] Each stage is a pure function over `Transcript`; every §1.3 invariant holds on fixture transcripts
- [x] Pipeline stops as soon as a stage lands under target; `stagesApplied` records exactly the stages run
- [x] Oversized-tail transcript returned unchanged with shortfall reported
- [x] Compiles with only this task's and its dependencies' types — no forward references to `CompactionPrompt`

## Tests
- [x] `Tests/FoundationModelsRouterTests/CompactionStageTests.swift` — fixture transcripts (mixed prompt/response/tool traffic) covering every invariant, elision placeholder content, turn-boundary edge cases (tool pair at the window edge, transcript with only instructions, fewer turns than keepRecentTurns)
- [x] `Tests/FoundationModelsRouterTests/CompactorPipelineTests.swift` — stage ordering, early stop, oversized-tail shortfall
- [x] `swift test --filter 'CompactionStage|CompactorPipeline'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction

## Review Findings (2026-07-23 14:26)

- [x] `Tests/FoundationModelsRouterTests/CompactionStageTests.swift:19` — makeInstructions() is duplicated across test files; both CompactionStageTests and CompactorPipelineTests define identical implementations, requiring maintenance in two places when the fixture structure changes. Extract makeInstructions(), makeTurn(), and makeTurns() to a shared test helper file (e.g., TranscriptTestHelpers.swift in Tests/FoundationModelsRouterTests/Helpers/) and import it in both test suites.
- [x] `Tests/FoundationModelsRouterTests/CompactionStageTests.swift:32` — makeTurn() is duplicated across test files; both CompactionStageTests and CompactorPipelineTests define identical implementations, requiring maintenance in two places when the fixture structure changes. Extract makeInstructions(), makeTurn(), and makeTurns() to a shared test helper file (e.g., TranscriptTestHelpers.swift in Tests/FoundationModelsRouterTests/Helpers/) and import it in both test suites.
- [x] `Tests/FoundationModelsRouterTests/CompactorPipelineTests.swift:30` — makeTurn() duplicates the implementation in CompactionStageTests.swift; maintaining identical fixture code in two test files creates unnecessary coupling and divergence risk. Extract makeInstructions(), makeTurn(), and makeTurns() to a shared test helper file (e.g., TranscriptTestHelpers.swift in Tests/FoundationModelsRouterTests/Helpers/) and import it in both test suites.
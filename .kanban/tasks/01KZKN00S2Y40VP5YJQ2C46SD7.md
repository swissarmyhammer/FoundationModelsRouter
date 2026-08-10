---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzpxf88pwsq6a9qeaxxj8x3p
  text: |-
    ### Decision — this is a GAP, not intended

    Evidence gathered before deciding:

    1. `Summarization` is `public struct` with a `public init(keepRecentTurns:maxChunkTokens:summaryTokenRatio:)` and all three knobs declared `public var`, each with a full doc comment naming its default. That is public, documented, tunable API.
    2. Nothing in production constructs `Summarization` directly. `rg 'Summarization\('` over `Sources/` returns exactly one hit — `Compactor.swift`'s bare `Summarization()`. Every other construction is in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` (14 sites). So there is no production direct-stage caller today.
    3. The "future direct-stage caller" reading does not hold: an external caller cannot rebuild the pipeline around a tuned stage, because the machinery it would need is internal, not public — `Compactor.stages`, `Compactor.charsPerTokenEstimate`, and `Compactor.estimatedTokenCount(of:)` all lack `public`. Only `Compactor.compact` is public, and it hardcodes `Summarization()`. So the three public knobs are unreachable from every public entry point.
    4. No doc comment, DocC article, or prior card states an intent that the knobs are test-only. The one prior statement is on `^zche4zy`'s "Design-Question Verification (2026-08-09 10:58)" section, which records the unreachability as an observation and rules it out of scope for that card: "Note that `Compactor.compact` constructs `Summarization()` with all defaults, so none of the three knobs is settable from the production path; all three are reachable only by constructing the stage directly." That is the note this card was split from, not a decision that it is intended.

    Decision: gap. Proceeding with AC #2/#3 — a `Summarization` parameter on `compact`, defaulted to `Summarization()`. Not widening `TokenBudget`/`CompactionPrompt`, per the card.
  timestamp: 2026-08-10T22:42:39.510448+00:00
- actor: claude-code
  id: 01kzpxzkzy1a3nt5d4gcjmhh29
  text: |-
    ### Implementation

    New signature (the card's preferred shape, not a widened `TokenBudget`/`CompactionPrompt`):

    ```swift
    public static func compact(
        _ transcript: Transcript,
        prompt: CompactionPrompt = .default,
        budget: TokenBudget,
        summarizer: (any CompactionSummarizer)? = nil,
        summarization: Summarization = Summarization(),
        pendingRuns: [CompactionSegment.PendingRunSummary] = []
    ) async throws -> (transcript: Transcript, result: CompactionResult)
    ```

    The body now folds with `summarization.apply(...)` instead of `Summarization().apply(...)`.

    **Source compatibility.** `summarization` sits between `summarizer` and `pendingRuns`, and every existing call site passes its arguments in declaration order, so all 13 existing call sites compile unchanged with no edit: 1 production (`RoutedSessionActorCompaction.swift`), 2 evals (`CompactionEvaluationTests.swift`, `CompactionEvalRealSubjectRunner.swift`), 10 unit tests (`CompactorPipelineTests.swift` x5, `SummarizationStageTests.swift` x5, counting the two this card rewrote to use a shared fixture but not to pass the new argument). Verified by a full `swift build --build-tests` with zero errors and zero warnings.

    **Doc-symbol rename.** Adding a parameter renames the DocC symbol, so all 24 references to `compact(_:prompt:budget:summarizer:pendingRuns:)` across 11 files became `compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`. `Scripts/check-doc-links.py` reports 0 stale and 0 unresolved over 1298 symbol links. The `- Parameter` half the checker is blind to was checked by hand: the new key is `- summarization:`, which is both the external label and the internal name (no separate label), and the doc list order still matches the signature order.

    **Coverage (AC #3).** Three ungated tests in `SummarizationStageTests`, one per knob, each observing the non-default value at the summarization stage rather than merely that the argument is accepted:
    - `compactCarriesSummaryTokenRatioIntoTheSummarizerCall` — asserts the `maxTokens` the summarizer was handed equals the ceiling a ratio of 0.5 earns, and does **not** equal the ceiling the default 0.25 earns.
    - `compactCarriesMaxChunkTokensIntoTheChunking` — a chunk ceiling wide enough for the whole span makes one summarizer call over both old turns, where the default 2000 makes three (2 map + 1 reduce).
    - `compactCarriesKeepRecentTurnsIntoTheFold` — a window of 2 leaves a two-turn tail and puts turn 4 inside the span the summarizer read, where the default 4 keeps turn 4 out of it.

    **Proof the tests catch a dropped parameter.** The wiring was temporarily reverted to `Summarization().apply(...)` (parameter accepted, ignored) and the suite re-run: exactly those three tests failed, with 6 issues, and no other test moved. The wiring was then restored and the suite went green again.

    **One refactor, and why it is not unrelated.** Three new tests would each have repeated the eight-line fold fixture the two existing `Compactor.compact` tests already spell out inline — a duplication finding by construction. The fixture is now one `makeModelAssistedFoldFixture()` helper and those two existing tests call it, so the diff removes a copy rather than adding three. Its turn text now carries the turn index, which is what lets a test read off a summarizer prompt which turns the fold condensed.

    **Also documented.** `Summarization`'s type doc now states that `compact` takes the stage itself, so the three knobs are the pipeline's own tuning and a caller with no opinion gets `Summarization()` by omitting it. No default value changed: 4, 2000, 0.25 and the 128 floor are untouched.

    **Discovered, filed as `^jnd5ktx`.** The session layer is one level further out and still hardcodes the default: `RoutedSession.compact(prompt:budget:)` -> `RoutedSessionActor.compact` calls `Compactor.compact` with no `summarization:`, so a live session always folds at the defaults. Out of scope here — this card names `Compactor.compact` as the production path — so it is a card of its own with the same decide-first shape.
  timestamp: 2026-08-10T22:51:35.806297+00:00
- actor: claude-code
  id: 01kzpy06x8rtsvgzt8n2acj91x
  text: |-
    ### Correction to the call-site count in the comment above

    The count is **12** pre-existing `Compactor.compact` call sites, not 13, and `SummarizationStageTests.swift` holds 4 of them, not 5. Counted with `rg -n "Compactor\.compact\(" Sources Tests`, which now reports 15 in total — the 12 below plus the 3 this card added:

    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift` — 1 (the only production call site)
    - `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift` — 1
    - `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` — 1
    - `Tests/FoundationModelsRouterTests/CompactorPipelineTests.swift` — 5
    - `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` — 4

    All 12 still compile with no edit to the call itself: none passes the new argument, and none had to be reordered.
  timestamp: 2026-08-10T22:51:55.176344+00:00
- actor: claude-code
  id: 01kzpy0gvqq0cbqwv02td4nt0v
  text: |-
    ### implement — changed
    - evidence: 13 files. Production: `Sources/FoundationModelsRouter/Compaction/Compactor.swift` (new `summarization: Summarization = Summarization()` parameter, folds with it), `Sources/FoundationModelsRouter/Compaction/Summarization.swift` (type doc states the knobs are reachable through `compact`), plus the DocC symbol rename in `CompactionPrompt.swift`, `CompactionStage.swift`, `RoutedSession.swift`, `RoutedSessionActorCompaction.swift`, `CompactionEvaluation.swift`, `CompactionEvaluationOutcome.swift`, `CompactionEvalRealSubjectRunner.swift`, `CompactionTokenAccountingTests.swift`, `RoutedSessionCompactTests.swift` — 24 references across 11 files. Tests: `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` (3 new knob tests, one shared fold fixture).
    - verification: ungated `swift test` 835 tests (786 + 25 + 24), 0 failures, 1 pre-existing known issue, 0 compiler warnings; `python3 Scripts/check-doc-links.py` 0 stale, 0 unresolved over 1298 links; 12 pre-existing call sites compile unchanged. Not run: `FM_ROUTER_INTEGRATION_TESTS=1` and `MULTITOOL_INTEGRATION=1` (27B model, 8-11 min) — no acceptance criterion needs them, the coverage this card asks for is ungated by design.
    - next: `/review`
  timestamp: 2026-08-10T22:52:05.367726+00:00
position_column: doing
position_ordinal: '80'
title: Summarization's three knobs are unreachable from the production compaction path — Compactor.compact hardcodes Summarization()
---
Split out of `^zche4zy` (its review recorded this and ruled it out of scope for that card).

`Compactor.compact(_:prompt:budget:summarizer:pendingRuns:)` constructs the model-assisted stage as a bare `Summarization()`:

```swift
let folded = try await Summarization().apply(...)
```

So all three of the stage's tuning knobs — `keepRecentTurns`, `maxChunkTokens`, `summaryTokenRatio` — plus the derived `maximumOutputTokens` cap take their defaults on every production fold, and are reachable only by constructing `Summarization` directly (which only tests do). `compact` takes a `TokenBudget` and a `CompactionPrompt`, but nothing that reaches the stage's own configuration.

That means:
- A caller cannot trade compression for summary fidelity (`summaryTokenRatio`, default 0.25) even though it is a `public var`.
- A caller cannot widen or narrow the map-reduce chunk size (`maxChunkTokens`, default 2000) to suit its model's real context.
- `keepRecentTurns` is fixed at 4 for the fold, while the deterministic stages happen to default to the same 4 — a coincidence nothing enforces.

## Decide first, then implement
Is this intended (the knobs exist for tests and for a future direct-stage caller), or is it a gap? If a gap, the shape to weigh:
- a `Summarization` parameter on `compact`, defaulted to `Summarization()`, which keeps every existing caller source-compatible; versus
- widening `TokenBudget` or `CompactionPrompt`, which would put stage tuning in a type that is not about the stage.

## Decision (2026-08-10): a gap
Recorded in full in this card's comments. In short: `Summarization` is public with three `public var` knobs, no production code constructs it directly, and the pipeline machinery a direct-stage caller would need (`Compactor.stages`, `Compactor.estimatedTokenCount(of:)`) is internal — so the knobs are unreachable from every public entry point. No doc or prior card states an intent that they are test-only.

## Acceptance Criteria
- [x] A decision is recorded on this card: intended, or a gap
- [x] If a gap: the production path can set all three knobs, with every existing `compact` call site unchanged
- [x] If a gap: ungated coverage that a non-default knob set through `compact` actually reaches the summarizer call
- [ ] If intended: the knobs' doc comments say so, so the next reader does not re-open this — not applicable, the decision is "gap"
#phase-1
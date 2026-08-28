---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14gy9c0243ycbwrf9d1pxgb
  text: |-
    Picked up. Research done.

    Findings that set the design:

    - `performAutoCompaction(prompt:budget:)` calls `fold(...)` up to three times as it degrades (flash -> own model -> deterministic). A span opened inside `fold(...)` itself would therefore make two or three spans for one automatic compaction, which breaks the acceptance criterion "one automatic fold makes one span". So the one shared span site is a new private helper, `withCompactionSpan(trigger:_:)`, that both `compact(prompt:budget:)` and `performAutoCompaction(prompt:budget:)` call around their whole fold work. The card's "one span around the shared fold body" is read as "one span-opening site shared by both entry points", not "inside fold()".
    - The tier the span reports is derived, not assumed: when `CompactionResult.summarizerModel` is nil no summarizer wrote the applied summary, so the tier is `deterministic`; otherwise it is the tier that produced the result. That is true for a caller fold that `TurnTruncation` alone landed, and for the automatic path's deterministic fallback.
    - `FoldSummarizerTier` gets a third case, `deterministic`. It already carries `flash` and `ownModel`.
    - `RouterTracing` gets `CompactionTrigger` (caller/auto) beside `TurnEntryPoint`, plus the keys `compaction.trigger`, `compaction.tier`, `tokens.before`, `tokens.after`. The `// periphery:ignore` marker on `SpanName.compact` goes away.
    - The auto-compaction fixtures (`ConfiguredLLMContainer`, `PerSlotModelLoader`, `makeTriggeredSession`, `cannedText`, `turnCount`, `warmUpContextTokens`, `expectedWarmUpEntries`, `fixedBudget`) are private to `AutoCompactionTests`. The card says to use them from the new suite, so they move to `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift` and gain a `tracer` parameter. `AutoCompactionTests` then calls them through that namespace. No duplication.
    - `StubSessionBackend.replacingTranscript(_:)` copies `shouldThrow`, so a caller-driven fold is made to fail by flipping `container.lastBackend?.shouldThrow`, not the container flag. The container flag is what makes the *flash* tier fail, because that tier builds its summarizer through `container.makeSession(instructions:)`.
    - `SpanContentSafetyTests` already drives a caller fold through a tracer-carrying fixture and reads every attribute of every span, so it covers the new span with no edit.
  timestamp: 2026-08-28T15:48:44.544871+00:00
- actor: claude-code
  id: 01m14hdtpp5d62vryqbgcaxca1
  text: |-
    Implementation landed, TDD order kept.

    RED: the new suite was written first and run before any production edit. 7 of its 8 tests failed at `spans.count == 1 -> spans.count -> 0`, so each failed because no fold span existed. The eighth (`untracedFoldFoldsNormally`) passed from the start on purpose: it asserts fold behavior with no tracer, so it is the regression guard, not a span test.

    GREEN: all 8 pass.

    What the production change does:

    - `RouterTracing.SpanName.compact` lost its `// periphery:ignore` marker and its "no caller" note.
    - `RouterTracing.AttributeKey` gained `tokens.before`, `tokens.after`, `compaction.trigger` and `compaction.tier`. `compaction.tier` documents its three values in prose, because `FoldSummarizerTier` is private to the session actor and a DocC link to it would not resolve.
    - `RouterTracing.CompactionTrigger` (`caller`/`auto`) sits beside `TurnEntryPoint`, the same shape.
    - `RoutedSessionActor.withCompactionSpan(trigger:_:)` is the one span site both fold paths call. It wraps the whole compaction, not one `fold(...)` call, because the automatic path calls `fold(...)` once per tier as it degrades.
    - `performAutoCompaction(prompt:budget:)` now delegates its tier ladder to `foldThroughTiers(prompt:budget:)`, which returns the result and the tier that produced it. The ladder itself is unchanged, cancellation guards included.
    - `FoldSummarizerTier` gained `deterministic`.

    The tier written on the span is derived rather than assumed: when `CompactionResult.summarizerModel` is nil, no summarizer wrote the applied summary, so the span reports `deterministic`. That is correct for a caller fold `TurnTruncation` alone landed, for the automatic path's deterministic fallback, and for a fold whose summary was discarded. Otherwise the span reports the tier that ran.

    Test-fixture move: the auto-compaction fixtures were private to `AutoCompactionTests`, and the card asks the new suite to use them. `ConfiguredLLMContainer`, `PerSlotModelLoader`, `cannedText`, `turnCount`, `warmUpContextTokens`, `expectedWarmUpEntries()`, `fixedBudget` and `makeTriggeredSession(...)` moved to `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift`, which gained a `tracer` parameter and a `tempDirPrefix` parameter so each suite still names its own temp directory. `AutoCompactionTests` calls through the new namespace and its 12 tests stayed green across the move. Two literals the move exposed got names: `warmUpUsageStepTokens` and `belowRecencyFloorDivisor`.

    Discovery worth keeping: `StubSessionBackend.replacingTranscript(_:)` copies `shouldThrow`, and `ConfiguredLLMContainer.makeSession(instructions:)` reads the container flag. So a test makes the FLASH tier fail with `flash.shouldThrow = true` (a fresh container call) but must make the SESSION'S OWN model fail with `standard.lastBackend?.shouldThrow = true` (the live backend the fold clones). Flipping the container flag alone leaves the own-model tier working.

    Verification, all three green:
    - `swift build` — Build complete.
    - `swift test` — 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests. Baseline was 1078 in 111 with the same 2 known issues plus 83: the difference is exactly the new `CompactionTracingTests` suite and its 8 tests. The 2 known issues are the documented `RealModelHarness` embedding-slot one and the `BoundedWait` wall-clock one; no new failure.
    - `swift build --package-path IntegrationTests --build-tests` — Build complete.

    `SpanContentSafetyTests` was not edited and still passes, so no attribute of the new span carries transcript text or the summary.
  timestamp: 2026-08-28T15:57:13.814986+00:00
- actor: claude-code
  id: 01m14he037fcfe4hvbfv46j672
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Tracing/RouterTracing.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Tests/FoundationModelsRouterTests/CompactionTracingTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift (new), Tests/FoundationModelsRouterTests/AutoCompactionTests.swift. `swift build` complete; `swift test` 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests; `swift build --package-path IntegrationTests --build-tests` complete.
    - next: /review
  timestamp: 2026-08-28T15:57:19.335920+00:00
- actor: claude-code
  id: 01m14hqjqqmz2xrap880exp3v5
  text: |-
    ### review — findings
    - evidence: 2 findings, 2 confirmed, 0 refuted over `review sha HEAD~1..HEAD` — Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift:136, Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift:182
    - both findings are `code-hygiene/magic-numbers-swift` on text moved from AutoCompactionTests.swift (line 142 and line 189 at HEAD~1); give the repeat count 60 and the trigger 0.8 a name, as the other constants in that file have
    - the span site at the two entry points is correct: a span inside `fold(...)` would make two or three spans for one automatic fold and would show a degrade as a failed span, which the card forbids
    - the tier derivation is correct: the automatic path's last tier is `fold(summarizer: nil, ...)`, which does not throw, so the span records no error on a degrade; the caller path has no catch, so `withSpan` records the summarizer error and raises it again
    - next: name the two constants, then run the review again
  timestamp: 2026-08-28T16:02:33.335931+00:00
- actor: claude-code
  id: 01m14hre6m2dvrjbx2mqa5rhap
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files; RouterTracing.swift, RoutedSessionActorCompaction.swift, new CompactionTracingTests.swift, new Helpers/AutoCompactionFixtures.swift, AutoCompactionTests.swift
    - test: green — swift test, 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests. Baseline was 1078 in 111 suites, so the difference is exactly the new suite. `swift build --package-path IntegrationTests --build-tests` also completed.
    - commit: f82dcd9
    - review: findings — Helpers/AutoCompactionFixtures.swift:136, Helpers/AutoCompactionFixtures.swift:182, both code-hygiene/magic-numbers-swift
    - next: name the two constants, then review again

    The reviewer held the two design decisions to be correct, and gave the reason. The card wrote the `fold(...)` span site as a preference and not a rule, and two of the card's own acceptance criteria forbid that site: `foldThroughTiers` calls `fold(...)` up to three times as it degrades, so a span there would make two or three spans for one automatic fold, and the degrade would read as a failed span. The chosen site satisfies the criteria.

    The two findings are magic numbers in text that moved verbatim from `AutoCompactionTests.swift`; only the access level changed in the move. The file already names its other constants, so the fix follows the pattern the file sets.
  timestamp: 2026-08-28T16:03:01.460111+00:00
- actor: claude-code
  id: 01m14hyx4bm31qfqsjrj0sn0mf
  text: |-
    Both review findings are corrected in `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift`.

    - The repeat count `60` in `cannedText` is now `private static let cannedTextRepeatCount = 60`.
    - The trigger fraction `0.8` in `fixedBudget` is now `private static let fixedBudgetTriggerFraction = 0.8`.

    Each new constant has a doc comment that tells what the number is for. Both use the same `private static let` shape as `warmUpUsageStepTokens` and `belowRecencyFloorDivisor`, which the file already had.

    The whole file was read for other literals of the same class. `dump validators` gives the rule as swiftlint `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`, and the rule reports nothing for a declaration that names its value (a `var`, a stored property, a `static let`, an enumeration raw value, or a default parameter). Against that rule the file now holds no other unnamed literal:

    - `DownloadProgress(bytesDownloaded: 1, bytesTotal: 1)`, in both loader methods, uses `1`, which the allow-list carries.
    - `(turn + 1) * warmUpUsageStepTokens` uses `1`, which the allow-list carries.
    - `turnCount`, `warmUpContextTokens`, `warmUpUsageStepTokens` and `belowRecencyFloorDivisor` are `static let` declarations that name their own values.

    Three doc comments said `0.8` in prose beside the literal. They now name `fixedBudgetTriggerFraction` instead, so the value has one home: the documentation of `warmUpUsageStepTokens`, of `fixedBudget`, and of `makeTriggeredSession(budget:tools:summarization:tracer:tempDirPrefix:)`.

    Verification, all three green:
    - `swift build` — Build complete.
    - `swift test` — 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests. The count is the same as the baseline, as a naming change must be. The 2 known issues are the documented `RealModelHarness` embedding-slot one and the `BoundedWait` wall-clock one.
    - `swift build --package-path IntegrationTests --build-tests` — Build complete.

    No new warning. The one warning in each build log is the pre-existing build-system message about the `mlx-swift_Cmlx.bundle` node.
  timestamp: 2026-08-28T16:06:33.355987+00:00
- actor: claude-code
  id: 01m14hz1j1qebkbezbga1ab4mb
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift. `swift build` complete; `swift test` 1086 tests in 112 suites passed with 2 known issues, plus 83 eval tests (same as the baseline); `swift build --package-path IntegrationTests --build-tests` complete. Both `## Review Findings` items are now `- [x]`.
    - next: /review
  timestamp: 2026-08-28T16:06:37.889354+00:00
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
position_column: doing
position_ordinal: '80'
title: Open one span for each compaction fold
---
## What

Wrap each compaction fold in one span, for the caller-driven path and the automatic path.

- Instrument `compact(prompt:budget:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:76) and `performAutoCompaction(prompt:budget:)` (same file, line 107). Prefer one span around the shared `fold(...)` body (line 198), with the trigger as an attribute.
- Span name: `FoundationModelsRouter.compact` from `RouterTracing`. Kind: `.internal`.
- Attributes: `session.id`, `model.ref`, the trigger (`caller` or `auto`), `tokens.before`, `tokens.after`, and the summarizer tier that ran (deterministic only, model-assisted, or the degraded fallback; see `FoldSummarizerTier`).
- A fold that throws must record the error on the span and throw again. The automatic path's degrade to the deterministic tier must show as the tier attribute, not as a failed span.
- Do not put transcript text or the summary text in an attribute.

## Acceptance Criteria
- [x] One caller-driven `compact()` makes one span with the trigger `caller`.
- [x] One automatic fold makes one span with the trigger `auto`.
- [x] The token attributes show the fold's before and after estimates.
- [x] A summarizer failure on the caller path keeps the span, with the error recorded.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/CompactionTracingTests.swift`. Use `InMemoryTracer` with the fold fixtures (`Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift`) and the auto-compaction fixtures from `AutoCompactionTests.swift`.
- [x] Assert the span name, attributes, tier attribute on a degraded automatic fold, and the error record.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router #compaction

## Review Findings (2026-08-28 10:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift:136` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift:182` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.

### Notes on the two findings

Both lines come from the earlier file `AutoCompactionTests.swift` (line 142 and
line 189 at HEAD~1). This change moved them into the new fixtures file without a
change to the text. Only the access level changed, from `private static` to
`static`. The diff scope thus shows them as new lines.

- Line 136 is the repeat count `60` in `cannedText`.
- Line 182 is the trigger fraction `0.8` in `fixedBudget`.

The neighbour constants in the same file (`turnCount`, `warmUpContextTokens`,
`warmUpUsageStepTokens`, `belowRecencyFloorDivisor`) show the pattern this file
already follows. Give each of the two numbers a name in the same way.

Both findings are corrected. The repeat count is now
`private static let cannedTextRepeatCount = 60` and the trigger fraction is now
`private static let fixedBudgetTriggerFraction = 0.8`. Each has a doc comment
that tells what the number is for, in the same shape as the neighbour
constants.

### Two design points, examined and correct

- The span sits at the two entry points, not inside `fold(...)`. The card gave
  the `fold(...)` site as a preference, not as a rule. The card also requires
  that one automatic fold makes one span, and that a degrade shows as the tier
  attribute and not as a failed span. `performAutoCompaction` calls `fold(...)`
  up to three times as it degrades, so a span inside `fold(...)` would break
  both of those requirements. The chosen site is correct.
- The tier is `result.summarizerModel == nil ? .deterministic : tier`. On the
  automatic path, `foldThroughTiers` catches each model-assisted tier failure
  and degrades. The last tier calls `fold(summarizer: nil, ...)`, which does not
  throw. The span body thus completes, and the span records no error. On the
  caller path, `compact` puts `fold(...)` in the span body with no catch, so a
  summarizer failure leaves the body and `withSpan` records the error and raises
  it again. Both claims hold. The one error the automatic span records is the
  `CancellationError` from `abandonFoldIfCancelled`, which is a stop and not a
  degrade.
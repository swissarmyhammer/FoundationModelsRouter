---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37frrntnbtjq6jf10hpy5cs
  text: |-
    ### Design choices (made without the owner; record for review)

    1. The whole trio grows with the window, not only the standard slot: every slot is sized at the one working context, and a flash slot on the same container pays a second KV cache. So the computation uses the charge of the whole trio, not only the standard KV cache.
    2. The computation: try the native window with `attemptTrio`. If it does not fit, try a window of one token. If that does not fit, the candidate does not fit (the slot that blocked it gives the verdict). Else take the trio that fit at one token as the plan, measure the bytes the plan charges at one token and at the failed window (one `attemptTrio` with an unlimited budget, so the reservation rule for a shared container stays the same), divide the difference by the tokens between them to get the bytes for each token, and compute `1 + floor((budget − charge at one token) / bytes per token)`, capped below the failed window. Confirm with one `attemptTrio`. When the confirmation does not fit (margin rounding, or a slot picks another candidate), the same computation runs again with that window as the failed window. Each step is smaller, so the search ends; the window of one token is already confirmed.
    3. When a charge cannot be sized at the failed window, or the charge does not grow with the window, the result is the confirmed window of one token. No new number enters the code: `smallestWindow = 1` is the lower end of the range `1...nativeMaxContext` that the card names.
    4. The report: `LadderAttempt` is now `WindowFit { nativeContextTokens, outcome }` with `outcome` = `.fits(contextTokens:estimatedFootprintBytes:)` or `.blocked(by:estimatedFootprintBytes:)`. `CandidateReport.ladderAttempts` is now `CandidateReport.windowFit: WindowFit?`. `ResolutionFailure.description` renders `native window N tokens, fitted window W tokens` or `native window N tokens, no window fits`.
    5. The `× 1.2` margin stays (^3scx5rz removes it). `ProfileDefinition.defaultContext` stays in the two fallback paths (^24hrxdj removes it). `UPSTREAM_ASKS.md` and `compaction_plan.md` keep the word "ladder": they are records of past answers and plans, not current docs.

    ### implement — changed
    - evidence: `Sources/FoundationModelsRouter/Resolution/JointFit.swift`, `Resolution/SlotResolution.swift`, `LanguageModelProfile.swift`, `Core/ProfileDefinition.swift`; tests `JointFitTests.swift` (new: native fits, computed window, window + 1 does not fit, not fitting at one token, multitool window 51_761 and + 1), `ResolveTests.swift`, `TranscriptNestingTests.swift`, `SessionTreeRestorationTests.swift`, `TokenBudgetTests.swift`, `TokenUsageMeteringTests.swift` (words only).
    - `swift test`: Test run with 1325 tests in 149 suites passed (2 known issues); Test run with 1 test in 1 suite passed; Test run with 19 tests in 3 suites passed. `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - `rg 'ladderStepDowns|contextLadder|walkLadder|LadderAttempt|ladderAttempts'` finds nothing.
    - next: commit, review.
  timestamp: 2026-09-23T15:57:21.978201+00:00
- actor: claude-code
  id: 01m37g4jqhd4dmzdgjxr3svg9x
  text: |-
    ### review — findings
    - evidence: review sha e8d7601 (HEAD~1..HEAD): 1 finding — `SlotResolution.swift:50` `code-hygiene/idioms-swift` UseSynthesizedInitializer.
    - fix: removed the explicit `WindowFit` initializer, and removed the same cause from the whole file: the `ResolutionFailure` initializer was also identical to the synthesized one. The finding box is checked.
    - next: test, commit, review HEAD~1..HEAD again.
  timestamp: 2026-09-23T16:03:49.105809+00:00
depends_on:
- 01M34PDQHD1WEJ2QBYPJ0P7ZN0
position_column: review
position_ordinal: '80'
title: Replace the context ladder with the largest window that fits
---
## Decision (from the owner, 2026-09-22)

`JointFit.ladderStepDowns` (131,072 / 65,536 / 32,768 / 16,384 / 8,192 / 4,096, `Resolution/JointFit.swift:57`) is an invented list and must go. When a model's KV cache at its native window does not fit in memory, the router computes the largest window that fits and reports it. The number comes from the model and the machine, not from a list.

## What exists

- `Footprint.kvBytes(context:)` (`Sizing/Footprint.swift:72`) is linear in `context`: `2 × layers × context × kvHeads × headDim × 2`. So bytes per token is a known constant for a model, and the largest context under a byte budget is one division.
- `JointFit.walkLadder` (`JointFit.swift:409`) tries `attemptTrio` at each rung, largest first, and stops at the first rung where the whole trio (standard, flash, embedding) co-fits `budgetBytes`. `contextLadder` (`:383`) builds the rung list.
- `LadderAttempt` records each rung tried, with its footprint and the blocked slot. `CandidateReport.ladderAttempts` carries them into the resolution report.
- `JointFit.withMargin` applies × 1.2 to every footprint. This card keeps the margin as it is. It is an open question for the owner, in the limits inventory of 2026-09-22.

## Do this

1. Delete `ladderStepDowns` and `contextLadder`.
2. Replace `walkLadder` with one computation for a standard candidate: the largest `context` in `1...nativeMaxContext` at which `attemptTrio` succeeds. Because the KV bytes are linear in `context` and every other charge in the trio is fixed at that point, derive it directly: the bytes left for the standard slot's KV cache after the weights, the margin and the other slots' charges, divided by the bytes per token, floored, then capped at `nativeMaxContext`. Confirm the result with one `attemptTrio` call at that context. When the result is below 1, the candidate does not fit.
3. Keep the report. Replace the list of rung attempts with one record that states the native window, the computed window, and the blocked slot when nothing fits. Rename `LadderAttempt` and `CandidateReport.ladderAttempts` to names that say "fit" and not "ladder", so the words match the mechanism.
4. A profile with an explicit `context` still uses that context and skips the computation, as today (`JointFit.swift:144`).
5. Update the tests in `JointFitTests.swift` that assert rung sequences. Add tests: a model that fits at its native window gets the native window; a model that does not fit at native gets the computed window, and `attemptTrio` at that window plus one fails; a model that does not fit at 1 token is reported as not fitting.

## Acceptance

- `rg 'ladderStepDowns|contextLadder|walkLadder|LadderAttempt|ladderAttempts'` finds nothing.
- The tests above pass. All tests pass.
- The resolution report for a model that did not fit at native states the native window and the computed window.

## Order

After ^j0p7zn0 (it edits the `contextLadder` cap line this card deletes). Before ^24hrxdj (Make the model's window the default context of a profile). All three edit `JointFit.swift`. #compaction #limits

## Review Findings (2026-09-23 10:57)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:50` `code-hygiene/idioms-swift` — UseSynthesizedInitializer: remove this explicit initializer, which is identical to the compiler-synthesized initializer.
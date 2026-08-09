---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Two gated compaction suites are flaky at HEAD — CompactionRoundTripIntegrationTests and the continuity eval fail intermittently with no code change
---
Discovered by `^5m97h14` iteration 5 while verifying that a `CompactionPrompt.default` change had not regressed the other gated suites. It had not — but the verification uncovered that two gated suites do not give the same answer twice on the same code.

## The measurement

Five gated runs of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionRoundTripIntegrationTests`, one shell command each, on 2026-08-09:

| run | `CompactionPrompt.default` | result |
|---|---|---|
| 1 | candidate v2 (verbose) | FAIL `:380` `fillAfterCompaction < fillBeforeCompaction` — 0.95068 vs 0.89453 |
| 2 | **v1, i.e. `git checkout` of HEAD** | **PASS — all four assertions** |
| 3 | candidate v2 (dense) | FAIL `:392` `recall.contains("CRIMSON-77")`, FAIL `:412` `checkpointedWindow.count < fullHistory.count` (19 vs 19) |
| 4 | candidate v2 (dense) | FAIL — identical to run 3 |
| 5 | **v1, i.e. `git checkout` of HEAD** | **FAIL — identical to runs 3 and 4** |

Run 5 is the decisive one: **the same two assertions fail on HEAD's own unmodified code that passed in run 2.** No prompt change is required to reproduce, so this is the suite, not any candidate change.

Note the failure *mode* also moves between runs — a fill-ordering failure in run 1, a recall + checkpoint failure in runs 3-5 — so a single red run cannot be read as evidence about whatever change is in the tree.

`CompactionContinuityEvaluationIntegrationTests` shows the same character on its own assertion: `mean(answersCorrect) >= 0.8` measured `0.5` and `0.8` on 2026-08-08 (recorded on `^5m97h14`, where it was called "flaky, not a fixed regression") and `0.7` on 2026-08-09. Its sibling `mean(foldOccurred) == 1.0` passes consistently.

## Why this matters more than one red run

Every gated criterion on `^5m97h14` and its successors is read off single runs. While these two suites answer differently on identical code, a red run cannot be attributed to the change under test and a green run cannot clear it. That makes the gated suites unusable as a decision procedure, which is exactly what they exist to be.

## The two leads, neither confirmed

1. **`checkpointedWindow.count == fullHistory.count == 19` is a structural fact, not model randomness.** It means the restore view found no compaction checkpoint in `transcript.jsonl`, i.e. no summary entry was recorded — while `#expect(!result.stagesApplied.isEmpty)` and `#expect(result.tokensAfter < result.tokensBefore)` both passed in the same run. One reading: the deterministic stages (`ToolOutputElision` + `TurnTruncation`) landed under target on their own that run, so `Summarization` never ran and no summary entry was synthesized; whether they do depends on how long the tiny model's own scripted replies happened to be. That would make the suite's reaching of stage 3 a coin flip rather than a property. Confirm by asserting/printing `result.stagesApplied` — the suite currently only asserts it is non-empty, which cannot tell "folded" from "truncated".
2. **The measured/estimated mixture in the fill comparison.** `fillBeforeCompaction` comes from genuinely measured usage (`TokenUsage.measured` from the backend); `fillAfterCompaction` reads `usageState = .measured(input: result.tokensAfter, output: 0)` set by the fold (`RoutedSessionActorCompaction.swift`), and `tokensAfter` is the character-ratio *estimate*. The assertion therefore compares a measured number against an estimated one, and only holds while the estimator's overcount stays smaller than the fold's real saving. That is a latent accounting fragility of the same family as `^5m97h14`'s original findings.

## Acceptance Criteria
- [ ] The cause of the run-to-run difference is identified and stated, with the numbers that prove it — for lead 1, which stages actually applied on a passing run versus a failing one
- [ ] The suites answer the same way on repeated runs of unchanged code — demonstrated by running each at least 3 times consecutively, all with the same result
- [ ] No assertion is loosened or deleted to achieve that. If an assertion is comparing incommensurable numbers (lead 2), fixing what it compares is a correction; lowering a bound is not
- [ ] `CompactionContinuityEvaluationIntegrationTests`' `mean(answersCorrect) >= 0.8` is covered by the same standard
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Repeated gated runs are the proof. Gated runs: one at a time, one shell command per run
- [ ] Add ungated coverage pinning whatever determinism defect is found, so it cannot silently return #phase-1
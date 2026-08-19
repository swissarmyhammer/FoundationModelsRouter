---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
title: Every integration test must run in under 2 minutes — boot from a recording, or make the test smarter
---
From the user, 2026-08-19:

> yeah your integration tests need to target < 2 min each -- do this by starting from a pre-record, or just being smarter about the test

## The budget

**Under 2 minutes per test.** Not per suite, not per tier — per test.

## Where things stand against it

Measured, not estimated:

| suite | measured | over budget |
|---|---|---|
| `CompactionContinuityEvaluationIntegrationTests` | 1 sample of 10 used the whole 1200 s limit; single steps up to 280.7 s | ~10x on ONE sample; ~100x for the tier |
| `CompactionEvaluationIntegrationTests` subset | 271.0 s mean per sample, dearest 352.0 s | ~3x per sample |
| `CompactionSmokeIntegrationTests` | 4.1 s | under |
| `AutoCompactionTriggerIntegrationTests` | 5.0 s | under |
| `RecordedTranscriptCompactionIntegrationTests` | 10.2 s | under |

The three that pass the budget are the three built on 2026-08-18/19. The technique is already proven in this repository; the slow tiers simply predate it.

## The three techniques that already work here

1. **Boot from a recorded transcript.** `^pfdrppj` folds real 30B traffic in 10.2 s by loading `Fixtures/CompactionRecording/` with `TranscriptTree.load(under:)` and folding it. No session, no turn, no driving.
2. **A synthetic trigger threshold.** `^d02ryqj` trips auto-compaction in 5.0 s by passing a small `TokenBudget` through the public `makeSession(budget:)`. No fixture has to be grown to reach a real threshold.
3. **A small model.** `mlx-community/Llama-3.2-1B-Instruct-4bit` loads in about 2 s where the 30B takes 3.4 s and generates far slower. `RealModelContainer.load(ref:context:samplingMode:)` already takes the reference.

## What is actually slow, and why

The continuity tier drives 13 real generation steps per task to push a live session past its trigger, then asks a final instruction. The steps exist only to consume context. That is paying a 30B model for filler.

The same continuity property is reachable inside the budget: boot a recorded transcript already near the trigger, drive ONE real turn, and assert the fold happened and the answer still carries the planted fact. That is techniques 1 and 2 together, which is what the two fast tests already do separately.

## This supersedes two cards' direction

`^6ssbakk` raised the fact-retention subset limit to 42 minutes, and `^mmrzhe0` was about to do the same for the continuity tier's 20. Both were correct as measurements of the tests as written. Both become unnecessary if the tests fit 2 minutes. Do NOT spend more effort deriving larger limits — state on each card that the budget replaces that direction, and leave the derived constants in place until the tests are fast, so nothing regresses in the meantime.

## Acceptance Criteria

- [ ] Every test in the integration and eval targets runs in under 2 minutes, measured and recorded
- [ ] The measurement is printed by the test itself, as the three fast suites already do, so a regression is visible without a stopwatch
- [ ] A test that exceeds the budget fails rather than merely being slow
- [ ] What each converted test proves, and what it no longer proves, is stated in its doc comment — a faster test that measures less must say so
- [ ] `^6ssbakk` and `^mmrzhe0` record that this budget replaces their limit-raising direction

## Care needed

A cheaper test that quietly measures less is a worse test, not a better one. `^pfdrppj`'s doc comment is the standard to match: it states plainly that booting from a recording proves the fold applies to real traffic and does NOT prove the automatic path fires. Every conversion here owes the same sentence.

#test-debt #compaction #eval
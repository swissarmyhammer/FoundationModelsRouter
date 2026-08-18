---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Test auto-compaction with a synthetic trigger threshold, so no fixture has to be grown to trip it
---
From the user, 2026-08-18:

> a better way to test auto compaction would be to do so with a synthetic limit on the triggering threshold of the context window

Auto-compaction has no fast test at all. `^w1cz46m` covers `Compactor.compact` called directly, which is the manual path. The automatic path — context fill climbs, the trigger fires, a fold happens inside a turn — is measured only by `CompactionRoundTripIntegrationTests` against the 30B model, at 425 seconds.

## Why this is the right shape

`^vjf3mdm` grew all 24 eval seeds so their transcripts would be large enough to trip the 0.80 trigger against a real context window. That was solving the wrong problem. The trigger is a number. If a test can set it low, a small transcript trips it, and the whole fixture-sizing arithmetic disappears:

- No seed needs to be grown to reach a threshold.
- `CompactionEvalSeedSizingTests` exists to prove the fixtures still clear their bound. A synthetic threshold makes that bound a test input rather than a property of the fixture.
- The measured 4.81 bytes-per-token constant, and the estimate-versus-tokenizer gap that broke `CompactionRoundTripIntegrationTests` twice, stop mattering for the trigger question.

## What to build

A test that sets the trigger threshold (and, if needed, the context window it is a fraction of) to a synthetic value small enough that a short transcript crosses it, then drives ONE turn and asserts the fold happened automatically:

- `contextFill` crosses the trigger.
- Compaction ran without the caller asking for it.
- The turn still returned an answer.
- The transcript after is smaller than before.

Use the smallest model that can do the job, as `^w1cz46m` does.

## First question to answer

Whether the trigger and the window are already injectable. `TokenBudget` carries the trigger; check whether a test can supply its own value through the public or `@testable` surface without changing production code. If it cannot, say so before changing anything — making a production knob test-settable is a design decision worth stating rather than assuming.

## Acceptance Criteria

- [ ] The trigger threshold is a test input, not a property the fixture has to be sized against
- [ ] One test drives a real turn, trips the trigger synthetically, and asserts the fold happened without the caller asking
- [ ] It runs in seconds against a small model, and prints its own wall clock the way `^w1cz46m` does
- [ ] It states in its doc comment what it proves and what it does not
- [ ] If a production surface had to change to allow injection, that change is stated and justified rather than slipped in #compaction #eval #real-model
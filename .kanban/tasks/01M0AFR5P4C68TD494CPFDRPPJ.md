---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Boot compaction tests from a recorded transcript rather than a hand-built fixture
---
From the user, 2026-08-18:

> one 'better' way to test compaction is to use a transcript recording to boot it and then just compact rather than drive a full session along

## Why

`^w1cz46m` folds one transcript in 4.1 seconds, and it was right to stop driving a full session. But it hand-builds its transcript in Swift, and a hand-built fixture is one more thing that has to be kept true. This week proved that twice:

- `^vjf3mdm` — 24 seeds were too small for a real summary to shrink them, and nobody knew until a gated run said so.
- `^wnj3ka3` — the round-trip fixture sat below its own trigger, because it was sized against an estimate rather than the tokenizer.

A recorded transcript has neither failure mode. It has the shape real traffic has, including the entry kinds a hand-written fixture forgets — reasoning entries, tool calls, tool outputs, an instructions header.

## What to build

Load a recorded transcript from the recordings root, fold it, and assert. No session, no turn, no generation beyond the summarizer call itself.

Points to settle while building it:

- Where recordings live and what format they carry. The router records `response` entries with `ms`, `tokensIn` and `tokensOut`, so the recording plane already exists.
- Whether a recording can be checked in as a fixture, or whether the test should read whatever is on the box and skip when absent. A checked-in recording is reproducible; a live one is honest about drift. State the choice.
- Redaction. A recording is real traffic. Anything checked in must be reviewed for content that should not be in the repository.

## Acceptance Criteria

- [ ] A compaction test boots from a recorded transcript rather than a fixture built in Swift
- [ ] It states where the recording came from and whether it is checked in or read live
- [ ] Any checked-in recording is reviewed for content that should not be committed
- [ ] The test still runs in seconds against a small model
- [ ] What it proves, and what it does not, is written in its doc comment #compaction #eval #test-debt
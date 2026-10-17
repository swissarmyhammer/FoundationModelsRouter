---
assignees:
- claude-code
depends_on:
- 01M53FFQY3H68Q9M4ZWQQNYTXA
position_column: todo
position_ordinal: '8480'
title: 'T1: each test wait also ends on the failure event; fixtures close when the body throws'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 4, new test rule T1.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.

Known cases:
- SubagentQuestionRelayTests.swift ~444-449: the test waits for the answer before it opens `closeGate`.
- SubagentQuestionRelayTests.swift ~319: `changes.wait(until:)`.

- [ ] Search the whole test target for waits that do not end on a failure event (gates, `wait(until:)`, continuations, stream reads, `for await` loops), and for fixtures that do not close when the body throws.
- [ ] Correct each one. Use no `.timeLimit`, no sleep, no poll and no retry.
- [ ] Run the full suite one time.
#elicitation-fixes
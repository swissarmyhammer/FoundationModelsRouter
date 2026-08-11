---
assignees:
- claude-code
position_column: todo
position_ordinal: '9e80'
title: 'Flaky test: cancelCurrentTurn on a streamEvents turn drops the first streamed chunk about 3 runs in 8'
---
`TurnCancellationTests.cancellingAStreamingTurnFinishesTheStreamWithCancellationError` fails intermittently.

The failing assertion is at `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift:1187` — the expectation that the delivered events contain `.textDelta(HookedSessionBackend.firstStreamedChunk)`.

## Measurement

Found while working `^zn8n9md`, and measured on both trees to prove it is not that change:

- With the `^zn8n9md` changes applied: `swift test --filter TurnCancellationTests`, 8 runs, 3 failures.
- With the same changes stashed (`git stash -u`): the same command, 8 runs, 3 failures.

The same test alone (`--filter cancellingAStreamingTurnFinishesTheStreamWithCancellationError`) passed 8 of 8 on the clean tree, so the flake needs the rest of the suite running beside it.

## What to establish

- Whether the race is in the test's own delivery observation or in the ordering between `cancelCurrentTurn()` and the first `.textDelta` the stream yields.
- A deterministic fix, not a retry and not a raised timeout.

## Acceptance Criteria

- [ ] The cause is named, in the product code or in the test
- [ ] `swift test --filter TurnCancellationTests` passes 20 runs in a row
- [ ] Ungated `swift test` green #phase-1
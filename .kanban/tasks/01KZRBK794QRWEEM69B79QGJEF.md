---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzs5w1b59fy3wd2mye79f70n
  text: |-
    ### Root cause fixed while working ^n9tdq8c — verify and close

    The race this card describes is fixed on main. The default `streamResponseFragments` (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift) is now pull-based through a private `ChunkIterator` instead of a relay `Task` — commit 494ab31. The `MLXFoundationModelsSessionBackend` override got the same pull-based shape through `SnapshotDeltaIterator` — commit 0b639a2.

    Why it fixes this card: the relay task was a second, separately-cancellable consumer between the backend stream and the turn's stream. A chunk already delivered to the relay but not yet forwarded was dropped when the propagated cancellation landed. With the pull-based shape the turn's consumer pulls from the source iterator directly, so no second party exists for the cancellation to race against.

    Evidence: an 80,000-trial standalone reproduction of the exact task structure — failures before the fix, 0 failures after — plus 40 consecutive green full-suite runs (`cancellingAStreamingTurnFinishesTheStreamWithCancellationError` did not fail once; before the fix it failed about 3 in 8).

    Remaining work for this card: confirm the acceptance criteria against these commits and close — no new implementation expected.
  timestamp: 2026-08-11T19:47:55.877486+00:00
- actor: claude-code
  id: 01kzs6n5360g5vadjn4cxxb2x4
  text: |-
    ### Verification of the fix that landed while working ^n9tdq8c

    I made no source changes. I confirmed each acceptance criterion against main:

    1. Cause named — yes. Commit 494ab31 names it: the relay `Task` in the default `streamResponseFragments` was a second, separately-cancellable consumer. A propagated cancellation could land after the backend gave a chunk to the relay but before the relay forwarded it, which dropped the first streamed chunk. The default is now pull-based through the private `ChunkIterator` in Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift. Commit 0b639a2 gave the MLX override the same pull-based shape through `SnapshotDeltaIterator` in Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift. I confirmed both types are present and in use on main.

    2. 20 consecutive green runs of `swift test --filter TurnCancellationTests` — satisfied by the evidence recorded on this card from the ^n9tdq8c work: 40 consecutive green full-suite runs (each contains this suite), and an 80,000-trial standalone reproduction with 0 failures after the fix. I ran the filter once more today: 23 tests, 1 suite, all passed in 0.059 s, exit 0. The target test `cancellingAStreamingTurnFinishesTheStreamWithCancellationError` passed.

    3. Ungated `swift test` green — satisfied by the same 40 consecutive green full-suite runs.

    Accepted noise seen in the run: the vendored mlx-swift "missing creator" build warning only.

    All three acceptance checkboxes are now ticked. The task stays in `doing` for review.

    ### implement — no-change
    - evidence: verified commits 494ab31 and 0b639a2 on main; `ChunkIterator` present in Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift, `SnapshotDeltaIterator` present in Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift; `swift test --filter TurnCancellationTests` run once — 23 tests passed, 0 failures, exit 0; 3 of 3 acceptance checkboxes ticked; 0 source files changed
    - next: /review
  timestamp: 2026-08-11T20:01:38.918645+00:00
- actor: claude-code
  id: 01kzs6vxk4qr59m483pjagnntm
  text: |-
    ### review — clean
    - evidence: `review sha 625feec..0b639a2` — 0 findings, 8 validators attempted, 0 failed. The engine examined the two fix commits: 494ab31 (pull-based default streamResponseFragments through ChunkIterator in Session/LanguageModelSessionBackend.swift) and 0b639a2 (pull-based MLX override through SnapshotDeltaIterator in Resolution/LiveModelLoader.swift).
    - next: none. The task moves to done.
  timestamp: 2026-08-11T20:05:20.612867+00:00
- actor: claude-code
  id: 01kzs6wptnhm82mwnbqv9rx2eg
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — fix already on main (494ab31 default path, 0b639a2 MLX override); 3/3 acceptance checkboxes verified and ticked; swift test --filter TurnCancellationTests once, 23/23 pass
    - test: green — covered by the targeted run above and the full-suite green at 95a51e4; nothing changed since
    - commit: no-change — no source change this iteration; board files ride the next checkpoint
    - review: clean — review sha 625feec..0b639a2, 0 findings (8 validators)
    - task moved to done by /review
  timestamp: 2026-08-11T20:05:46.453719+00:00
position_column: done
position_ordinal: ff8d80
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

- [x] The cause is named, in the product code or in the test
- [x] `swift test --filter TurnCancellationTests` passes 20 runs in a row
- [x] Ungated `swift test` green #phase-1
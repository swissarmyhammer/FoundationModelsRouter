---
position_column: todo
position_ordinal: '8480'
title: Delete the unused RoutedSession.fork
---
## What

Delete the unused session fork. Nothing in any package's `Sources/` calls `RoutedSession.fork(workingDirectory:)` (checked 2026-10-24 across every package in `swissarmyhammer/`), and the ACP agent does not implement ACP's unstable `session/fork`. If fork comes back later, build it from the parent's current rendered context as the start message of the new session (the user's design, 2026-10-24).

- [ ] Delete `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift`, and the requirement `fork(workingDirectory:)` in `Sources/FoundationModelsRouter/Session/RoutedSession.swift:580`, with each conformer and stub.
- [ ] `Sources/FoundationModelsRouter/Session/SessionHooks.swift:22, 96, 279`: remove the `.fork` case and its `SessionStart` source, if nothing else makes it. If the case is a public type of FoundationModelsHooks, keep it there and remove only Router's use. Say which in the commit.
- [ ] **Keep** `settledTranscript` (compaction uses it, `RoutedSessionActorCompaction.swift:575`) and `TranscriptTree.forkPrefix` (the recording reader `TranscriptTree.effectiveEvents` uses it, `:321`). Remove only helpers that no other code reads; check each with `rg`.
- [ ] Remove the Router fork tests (`ForkConcurrencyTests` and the others that `rg -n fork Tests` finds).
- [ ] **The ACP agent's tests call fork:** `SessionLifecycleTests.swift:143`, `TranscriptStoreTests.swift:219`, `SessionListTests.swift:283`, and the test double `CloseCountingRoutedSession.swift:97-99`. Tell the FoundationModelsACPAgent session before you push. It has a card for this.

## Acceptance Criteria

- [ ] `rg -n 'func fork|\.fork\(' Sources` finds nothing in Router.
- [ ] No Router test names a fork.

## Tests

- [ ] `swift test` in FoundationModelsRouter: all tests pass, with no new warnings.
- [ ] `swift test` in FoundationModelsACPAgent against this Router, after its update: all pass.

## Workflow

- A delete: the build and the present tests are the proof. Commit it on its own.
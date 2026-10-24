---
comments:
- actor: wballard
  id: 01m5px8hkbkygkxw7x5sasvgfn
  text: 'Deleted RoutedSession.fork and its fork-only helpers (makeFork(tools:), makeFork(tools:seededFrom:), makeForkHooks, SessionFacts.forFork, SettledTranscript.removingUnansweredCalls/historyOrdinal, SpanName.fork, forkChildSessionId, SessionOrigin.forked) and ~115 fork tests. Kept makeFork() (default replacingTranscript uses it; other packages implement it), settledTranscript, TranscriptTree.forkPrefix, and HookParent.fork + SessionHooks.forkParent: restore of a recorded fork tree (SessionTreeRestoration:304) still makes HookParent.fork, so the case stays; SessionOrigin.forked is a FoundationModelsHooks type, kept, Router''s fork use removed. OPEN: acceptance rg ''func fork|\.fork\('' Sources still matches 3 HookParent.fork lines in SessionHooks.swift (and the forkPrefix declaration) — needs a decision. ACP agent tests break: SessionLifecycleTests.swift:143, SessionListTests.swift:283, TranscriptStoreTests.swift:219, Support/CloseCountingRoutedSession.swift:97-99. swift test: 2082 tests/264 suites (9 known issues) + 39 + 19, all pass.'
  timestamp: 2026-10-24T12:13:10.635725+00:00
position_column: doing
position_ordinal: '80'
title: Delete the unused RoutedSession.fork
---
## What

Delete the unused session fork. Nothing in any package's `Sources/` calls `RoutedSession.fork(workingDirectory:)` (checked 2026-10-24 across every package in `swissarmyhammer/`), and the ACP agent does not implement ACP's unstable `session/fork`. If fork comes back later, build it from the parent's current rendered context as the start message of the new session (the user's design, 2026-10-24).

- [x] Delete `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift`, and the requirement `fork(workingDirectory:)` in `Sources/FoundationModelsRouter/Session/RoutedSession.swift:580`, with each conformer and stub.
- [ ] `Sources/FoundationModelsRouter/Session/SessionHooks.swift:22, 96, 279`: remove the `.fork` case and its `SessionStart` source, if nothing else makes it. If the case is a public type of FoundationModelsHooks, keep it there and remove only Router's use. Say which in the commit.
- [x] **Keep** `settledTranscript` (compaction uses it, `RoutedSessionActorCompaction.swift:575`) and `TranscriptTree.forkPrefix` (the recording reader `TranscriptTree.effectiveEvents` uses it, `:321`). Remove only helpers that no other code reads; check each with `rg`.
- [x] Remove the Router fork tests (`ForkConcurrencyTests` and the others that `rg -n fork Tests` finds).
- [ ] **The ACP agent's tests call fork:** `SessionLifecycleTests.swift:143`, `TranscriptStoreTests.swift:219`, `SessionListTests.swift:283`, and the test double `CloseCountingRoutedSession.swift:97-99`. Tell the FoundationModelsACPAgent session before you push. It has a card for this.

## Acceptance Criteria

- [ ] `rg -n 'func fork|\.fork\(' Sources` finds nothing in Router.
- [x] No Router test names a fork.

## Tests

- [x] `swift test` in FoundationModelsRouter: all tests pass, with no new warnings.
- [ ] `swift test` in FoundationModelsACPAgent against this Router, after its update: all pass.

## Workflow

- A delete: the build and the present tests are the proof. Commit it on its own.
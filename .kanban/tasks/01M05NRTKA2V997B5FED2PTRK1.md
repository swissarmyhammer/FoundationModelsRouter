---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m065ep6qdfnbmck9p7d25czj
  text: |
    Research and decision.

    Read both sites, `GenerationReentry.swift`, `DetachingTool.swift`, and `LanguageModelSessionBackend.transcriptEntries()`'s precondition doc.

    Two findings shaped the answer:

    1. The detachment layer starts its work with `Task { }`, not `Task.detached`, so a detached run DOES inherit `GenerationPermitLoan.current`. `GenerationPermitLoan.close()` exists for exactly that. So `loan.sessionID == id` alone — the check `beginTurn()` makes — can also be true long after the turn ended. That is safe for a refusal (an unnecessary refusal costs a caller a readable error) but NOT safe for a check that drops a lock. The new `isInsideOwnTurnToolCall` therefore also asks `toolCallDepth > 0` through the new `GenerationPermitLoan.isSuspendedInToolCall(ofSession:)`. `beginTurn()`'s own check is left exactly as `^1zt7vyg` wrote it.

    2. `RoutedSession.transcript` is `get async`, NOT `get async throws`. Refusing there would have needed a public protocol break plus a `try` at every call site, for a read that has no concurrent writer to protect against. So `fork` refuses and `transcript` is served — the two answers differ, as the card allowed.

    `LanguageModelSessionBackend.transcriptEntries()` says "Only safe to call while holding the owning session's turn lock". That doc now states the one bounded exemption rather than being silently violated.

    Rejected: serving the fork unlocked. The turn's mid-turn state ends in a tool call whose output has not landed, and `historyOrdinalAtFork` would name a position the parent goes on writing past, so the child would diverge from what a restore replays. That is a semantics problem, not a lock problem, and no lock trick fixes it.
  timestamp: 2026-08-16T20:50:46.103955+00:00
- actor: claude-code
  id: 01m065exw2fvtmc41y14y1gd53
  text: |
    RED was observed, not assumed. With the two source files stashed (`RoutedSessionActorForking.swift`, `RoutedSessionActor.swift`) and the tests in place, both new same-session tests ran the full 30-second bound and failed:

    - "a tool body that forks its own session is refused" — did not finish within 30.0 seconds; gate.availablePermits was 0.
    - "a tool body reads its own session's transcript mid-turn" — did not finish within 30.0 seconds; gate.availablePermits was 0.

    "a tool body forks a second session over the same resident container" passed with the fix stashed, which is correct: it holds the unchanged different-session path.

    After `git stash pop`, all 7 tests of the suite pass in 0.012 seconds.

    Public API change, stated plainly: `SessionReentryError` gains the case `forkDuringSameSessionTurn(sessionID:)`. The enum is public, so any client `switch` over it that was exhaustive is now non-exhaustive and must add an arm. No existing case, signature, or message changed.

    New tests carry no `@MainActor`, so they do not queue behind the main-actor suites.
  timestamp: 2026-08-16T20:50:53.954785+00:00
- actor: claude-code
  id: 01m065f3hh5ya0fq95bwvdd43m
  text: |
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Session/GenerationReentry.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift, Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift. `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `swift test` 966 + 27 + 24 pass, 0 failures, 1 pre-existing known issue in BoundedWait's own suite.
    - next: ready for /review
  timestamp: 2026-08-16T20:50:59.761559+00:00
- actor: claude-code
  id: 01m0663ga02r57q140swk7dmvq
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 1944077) — 9 validators attempted, 0 failed, 0 skipped; counts findings 0 / confirmed 0 / refuted 0. 7 files reviewed, 2 `.kanban/` files excluded by `.reviewignore`.
    - checked by hand, as the caller asked:
      - `RoutedSessionActorTurnGating.swift` `isInsideOwnTurnToolCall` -> `GenerationPermitLoan.isSuspendedInToolCall(ofSession:)` needs session identity AND `toolCallDepth > 0`. Depth is raised only in `withGenerationSuspendedForToolCall(_:)`, which the tool wrappers put around the await the SDK itself is suspended on, and it is lowered by `defer` and zeroed by `close()`. The read and the write both go through the loan `Mutex`, so the model call's appends before the tool call are published to the reader. A detached run keeps the task local but sees depth 0, so it takes the lock.
      - `RoutedSessionActorForking.swift` `fork(workingDirectory:)` — the `guard` is the first statement of the body, before the fork-admission gate and before `turnLock.wait()`. Nothing is acquired on the refusal path, so nothing leaks.
      - `SessionReentryError` — no `switch` over this type anywhere holds a `default`. The only one is the enum's own `errorDescription`, which lists both cases. A future case breaks that build instead of being swallowed.
    - next: none — task moves to done.
  timestamp: 2026-08-16T21:02:08.192181+00:00
- actor: claude-code
  id: 01m0664krj2kjv889qj5fb8g49
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files. `fork()` on the session's own turn is refused with `SessionReentryError.forkDuringSameSessionTurn`; the `transcript` getter is served without the lock in that one case. Both ask one shared question, `isInsideOwnTurnToolCall`.
    - test: green — swift test, 1017 tests, 0 failures; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; the three new tests run in 0.030s each under a 30-second bound, so they fail rather than hang
    - commit: 1944077 (breaking — `SessionReentryError` gains a case)
    - review: clean — zero new findings over 9 validators; task moved to done

    The review pressed the risky part hardest — the lock-free transcript read — and could not manufacture a case where the guard is true while this session's model call is appending. The guard needs the loan to name this session AND a tool-call depth above zero, depth is raised in one place only and lowered by `defer`, and both the write and the read go through the loan's `Mutex`, so the reader gets a publication edge.

    One residual the reviewer stated as an observation rather than a finding, and it is worth carrying: if the SDK ever ran two tool calls of one turn concurrently AND appended as each returned, a sibling tool still holding depth could read during that append. Confirming that needs the vendored SDK's internals. It is the same window `GenerationPermitLoan`'s own documentation already records as the one it does not close.
  timestamp: 2026-08-16T21:02:44.498853+00:00
position_column: done
position_ordinal: ffae80
title: fork() and transcript park forever when called from inside the session's own tool body
---
Found while fixing `^1zt7vyg`. The generation gate no longer deadlocks a tool body that generates on another session (a turn now lends its permit), and a tool body that generates on **its own** session is now refused with `SessionReentryError`. Two neighbours of that shape are still silent parks.

## The two sites

Both take the session's own `turnLock`, which the turn that invoked the tool still holds for its whole length:

- `RoutedSessionActorForking.swift`, `fork(workingDirectory:)` — `await turnLock.wait()`
- `RoutedSessionActor.swift`, the `transcript` getter — `await turnLock.wait()`, released as soon as the entries are captured

A tool body that calls `session.fork(...)` or reads `session.transcript` on the session whose turn invoked it parks until that turn ends, and that turn cannot end until the tool returns. The same circular wait `^1zt7vyg` describes, on the other gate.

`fork` from a tool body is a shape a host would reach for: a tool that spawns a sub-agent from the conversation it is running inside. `transcript` is worse, because reading history from a tool looks harmless.

## What already exists to build on

`GenerationPermitLoan.current` is published for the whole of a turn's model call and names the lending session. `RoutedSessionActor.refuseReentryOntoThisSession()` reads exactly that to refuse a same-session turn. Either site can ask the same question.

## Decide, then do

- Refuse, the way `beginTurn()` now refuses, so the call fails with a message instead of parking. Cheapest, and honest.
- Or serve the read without the lock where that is sound. A `transcript` read from inside the turn that holds the lock is reading its own backend mid-turn, which is what the lock exists to prevent — so a refusal may be the only correct answer there too.

Whichever is chosen, the parked-forever behaviour must not stay.

## The decision made

`fork(workingDirectory:)` **refuses**, with the new `SessionReentryError.forkDuringSameSessionTurn(sessionID:)`. Two reasons hold together: the turn holds `turnLock` until the tool returns, and the state a fork reads is half-written mid-turn (the tool call has landed, its output and the answer that follows it have not), so a child seeded from it would carry a conversation the model never finished, at a history position the parent goes on writing past. The refusal lands before the fork-admission gate, so nothing is acquired.

The `transcript` getter **is served without the lock**. What the lock buys is the absence of a *concurrent* writer, and this caller has that already: the only writer is this session's own model call, suspended in the tool that is asking. The read reports the history as it stands mid-turn, and unlike a fork nothing durable is seeded from it. The getter is also non-throwing in the public protocol, so a refusal there would have meant a wider API break for no correctness gain.

Both sites ask one new shared question, `RoutedSessionActor.isInsideOwnTurnToolCall`. It is narrower than the check `beginTurn()` makes: it also asks the loan whether the lending turn is suspended in a tool call right now, because a check that makes a caller *drop* a lock has to be exact where a check that only refuses may be conservative.

`turnLock` is neither lent nor weakened. A nested call on a different session is untouched, and two tests hold that.

## Acceptance Criteria

- [x] `fork(workingDirectory:)` called from inside the session's own tool body fails clearly, or is served safely — never parks
- [x] The `transcript` getter read from inside the session's own tool body fails clearly, or is served safely — never parks
- [x] A test covers each shape, bounded so it fails instead of hanging
- [x] The chosen behaviour is documented on both declarations #bug #bug-nested-generation #nested-generation
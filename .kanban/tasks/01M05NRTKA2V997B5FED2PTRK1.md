---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
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

## Acceptance Criteria

- [ ] `fork(workingDirectory:)` called from inside the session's own tool body fails clearly, or is served safely — never parks
- [ ] The `transcript` getter read from inside the session's own tool body fails clearly, or is served safely — never parks
- [ ] A test covers each shape, bounded so it fails instead of hanging
- [ ] The chosen behaviour is documented on both declarations #bug #nested-generation #bug-nested-generation
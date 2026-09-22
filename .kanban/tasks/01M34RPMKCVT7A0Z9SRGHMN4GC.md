---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: Delete the fork admission gate and maxConcurrentForks
---
## Decision (from the owner, 2026-09-22)

`defaultMaxConcurrentForks` (4, `Router.swift:7`), the `maxConcurrentForks` parameter of `Router.init` (`Router.swift:109`), and the fork-admission gate in `ResidentModelGates` (`Concurrency/ResidentModelGates.swift:18, 25`) are an invented bound and must go. Forks are not counted. The generation gate (value 1) stays: it serializes generation over one container.

## Why

- The number arrived with the semaphore in commit 5190a49 (2026-06-30). No reason was given.
- The gate is silent: the fifth fork over one model suspends, FIFO, until an earlier fork's `deinit` releases a slot. No error, no event, no log line.
- Generation is already serialized by the generation gate, so the count protects no GPU. The real cost of an idle fork is memory, and a count says nothing about memory.

## Sites

- `Router.swift:5-7`: the constant. `:45-46`: the property. `:87, :109, :124`: the `init` parameter, doc and assignment. `:447`: passes it to the pool.
- `Resolution/ModelPool.swift:224, 235, 250`: the parameter threaded to `ResidentModelGates`.
- `Concurrency/ResidentModelGates.swift`: `forkAdmission`, its doc, and the `init` parameter. After this card the gates hold `generation` only; keep the struct if other code reads it as a set.
- `Session/RoutedSessionActorForking.swift:93-97`: the `forkAdmissionGate.wait()` and its comment. Find the matching release in the child's `deinit` and remove it.
- `Session/RoutedSession.swift:271` and `LanguageModelProfile.swift:115`: doc comments that describe the ceiling. Rewrite.
- Tests: every `maxConcurrentForks:` argument, and any test that asserts the fifth fork waits. Replace the latter with a test that N forks over one model all exist at once, for an N larger than 4.

## Do this

1. Delete the constant, the parameter, the property and the gate. Delete the wait and the release.
2. Rewrite the docs above.
3. Update the tests as above.
4. Do not add a count anywhere else.

## Not in this card, to check next

Whether a fork's KV cache is charged to the pool's byte budget. The forking path shows no charge. If none exists, memory is unmeasured for forks, and that is a separate card for the owner.

## Acceptance

- `rg 'maxConcurrentForks|MaxConcurrentForks|forkAdmission'` finds nothing.
- A test makes 8 forks over one model and all 8 exist at once.
- All tests pass. #compaction #limits
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34txqbr1pwa568z2a4hpyxe
  text: |-
    ### research — iteration 1

    Sites found with `rg 'maxConcurrentForks|MaxConcurrentForks|forkAdmission|holdsAdmissionPermit'`:

    - Sources: `Router.swift` (constant, property, init parameter, pool call), `Resolution/ModelPool.swift` (acquire parameter), `Concurrency/ResidentModelGates.swift` (`forkAdmission`, init parameter), `LanguageModelProfile.swift` (`forkAdmissionGate` property), `Session/RoutedSessionActor.swift` (`forkAdmissionGate`, `holdsAdmissionPermit`, the `deinit` release, the factory parameters), `Session/RoutedSessionActorForking.swift` (the wait, the docs, the child arguments), `RoutedLLM.swift` (root session arguments), `Recording/SessionTreeRestoration.swift` (restored session arguments and a doc line), `Session/RoutedSession.swift` (protocol doc), `Session/OperationEventJournal.swift` (a doc line names the permit), `Concurrency/AsyncSemaphore.swift` (a doc line names fork admission).
    - The `deinit` of `RoutedSessionActor` only releases the permit. After the change it does nothing, so it goes.
    - Tests that assert the wait: `ForkConcurrencyTests.forkAdmissionBoundsConcurrentForks`, `ForkTracingTests.forkWaitingOnTheCeilingHasTheWaitInsideItsSpan`, `CrossRouterResidencyTests.forkCeilingComesFromTheRouterThatLoadedTheKey`. These go. One new test in `ForkConcurrencyTests` makes 8 forks over one model and asserts that all 8 exist at once.
    - Test helpers that pass `maxConcurrentForks:`: `RouterTestFixtures`, `ResidencyStubs`, `HandBuiltProfileFixtures`, `RealModelHarness`, and the local `makeRouter` in 9 test files. Two integration tests build a `RoutedSessionActor` by hand.
    - `model-pool.md` §2.7 and §3 describe the ceiling. Rewrite.
  timestamp: 2026-09-22T15:14:35.512302+00:00
- actor: claude-code
  id: 01m34vaf259ppewgtr661jbbhg
  text: |-
    ### implement — changed
    - evidence: 31 files. Sources: Router.swift, Resolution/ModelPool.swift, Concurrency/ResidentModelGates.swift, Concurrency/AsyncSemaphore.swift, LanguageModelProfile.swift, RoutedLLM.swift, Recording/SessionTreeRestoration.swift, Session/RoutedSession.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorForking.swift, Session/OperationEventJournal.swift. Docs: model-pool.md, README.md. Tests: ForkConcurrencyTests (deleted the fifth-fork wait test; added `forksOverOneModelAreNotCounted`, 8 forks), ForkTracingTests (deleted the wait-in-span test and the `openForkSpans` helper), CrossRouterResidencyTests (deleted the fork-ceiling test and its two constants), AsyncSemaphoreTests (doc), the helpers RouterTestFixtures, ResidencyStubs, HandBuiltProfileFixtures, RealModelHarness, and 11 test files that passed `maxConcurrentForks:` or built a `RoutedSessionActor` by hand; two IntegrationTests files.
    - The `deinit` of `RoutedSessionActor` only released the permit, so it is deleted.
    - `rg 'maxConcurrentForks|MaxConcurrentForks|forkAdmission'` finds nothing outside `.kanban`.
    - `swift build --build-tests` and `swift build --package-path IntegrationTests --build-tests` both complete with no error.
    - next: test
  timestamp: 2026-09-22T15:21:32.997975+00:00
- actor: claude-code
  id: 01m34vbs5y183dnvb89y9yee1d
  text: |-
    ### test — green
    - evidence: `swift test` — 1349 tests in 145 suites passed (main bundle), 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failures, 0 skipped. The 2 known issues are the pre-existing `withKnownIssue` blocks in RealModelHarnessTests and BoundedWaitTests. `forksOverOneModelAreNotCounted` passed. `swift build --package-path IntegrationTests --build-tests` completes with no error. The one build line `warning: missing creator for mutated node` names the `mlx-swift_Cmlx.bundle` product and is a SwiftPM artifact warning that predates this change.
    - next: commit
  timestamp: 2026-09-22T15:22:16.126133+00:00
- actor: claude-code
  id: 01m34vccfk4tzeh39y2mp58sk4
  text: |-
    ### commit — changed
    - evidence: 35f41fe refactor(fork): delete the fork admission gate and maxConcurrentForks
    - next: review
  timestamp: 2026-09-22T15:22:35.891544+00:00
- actor: claude-code
  id: 01m34vzbhhrn61y5dyd9j1me7d
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 2 refuted; 32 files reviewed. `README.md` and `model-pool.md` match no validator. No prior findings section on the card.
    - next: done
  timestamp: 2026-09-22T15:32:57.521070+00:00
- actor: claude-code
  id: 01m34vzxh84n2zkeerths4es87
  text: |-
    ### finish iteration 1 — review clean, task in done
    - implement: changed — 31 files; the gate, the constant, the parameter, the property, the wait and the `deinit` release are deleted; docs rewritten; the fifth-fork tests replaced by `ForkConcurrencyTests.forksOverOneModelAreNotCounted` (8 forks)
    - test: green — `swift test`: 1349 + 1 + 83 tests passed, 0 failures, 0 skipped; `swift build --package-path IntegrationTests --build-tests` compiles
    - commit: 35f41fe
    - review: clean — `review sha HEAD~1..HEAD`: 0 findings; `rg 'maxConcurrentForks|MaxConcurrentForks|forkAdmission'` finds nothing outside `.kanban`
  timestamp: 2026-09-22T15:33:15.944295+00:00
position_column: done
position_ordinal: ffffe080
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
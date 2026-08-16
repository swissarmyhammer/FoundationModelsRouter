---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m05mf88k7g0rd01tk1f1cv3a
  text: |-
    ### Research done — the design I will build

    Confirmed the mechanism on the current tree. `beginTurn()` takes `turnLock`, then `generationGate`, and `endTurn()` runs in a `defer` that spans the whole turn, tool calls included. `Router` mints one gate for each `PoolEntry` and hands the same instance to every `RoutedModel` over that entry, so two resolver-built handles over one resident container contend on one semaphore.

    **The anchor I found.** `runCancellableModelCall` already binds a task local (`ToolContext.$current`) around the turn's model call, and every tool the SDK invokes runs inside that call. That is the place to publish who holds the gate.

    **The fix.** A new internal `GenerationPermitLoan`, published as a task local for the model call only:

    - It carries the gate instance, the lending session id, whether the lender holds a permit right now, and how deep it is in a tool call it awaits.
    - `beginTurn()` reads the ambient loan. When the loan names the same gate, holds a permit, and is inside a tool call, the new turn is admitted with **no** `wait()` and **no** permit of its own. `endTurn()` signals only when the turn really holds one, so the count never inflates. This is the `humanWaitDepth` / `humanWaitLenderTurnId` precedent, not a bare extra `signal()`.
    - `awaitingUser(_:)` is NOT reused. Its machinery is untouched; the loan simply follows the permit through `acquireGenerationPermit()` / `releaseGenerationPermit()`, so a turn parked on a person lends nothing.
    - The tool wrappers (`DetachingTool`, `ContextBindingTool`) mark the tool-call window around the **inline** await only. A run that detaches leaves the window, so background work started by a tool cannot borrow and overlap the outer generation.
    - `turnLock` is untouched. A nested `respond` on the **same** session is refused before the lock is taken, with a typed `SessionReentryError`, instead of parking without a sound.
    - `beginTurn()` sets `currentTurnId` **after** it is admitted to the gate, so `cancelCurrentTurn()` on a session still waiting for a permit answers `noTurnInFlight` rather than `requested` with nothing to cancel.

    **Residual limit, recorded honestly.** A `.detaching` tool that starts generating inside the wait window and then detaches keeps its borrow until that generation ends, so the two generations can overlap for that stretch. The count stays exact. This is the same class of limit `awaitingUser(_:)` already records for a wait that overlaps a turn it is not part of.

    **Test route.** `RouterTestFixtures.makeRouter` + `StubModelLoader` + `router.resolve(profile:reporting:)`, then two root sessions off `profile.standard` — resolver-built handles over one pool entry, one gate. A stub backend calls the session's own composed `DetachingTool` from inside `respond`, exactly as `RespondRunPlaneDrainTests` does, and the tool body generates on the other session.
  timestamp: 2026-08-16T15:53:58.803581+00:00
- actor: claude-code
  id: 01m05nttwsrmz079bbzgmg0rme
  text: |-
    ### Landed — the mechanism, and how each acceptance criterion is met

    **New file** `Sources/FoundationModelsRouter/Session/GenerationReentry.swift`:

    - `GenerationPermitLoan` (internal, `Sendable`, `Mutex`-guarded) — a task local published for exactly one turn's model call. It carries the gate instance, the lending session id, whether that turn holds a permit right now, and how deep it is in a tool call it awaits.
    - `withGenerationSuspendedForToolCall(_:)` — the tool-call window the wrapping layers mark.
    - `SessionReentryError.sameSessionTurnInFlight(sessionID:)` (public, `LocalizedError`) — the refusal.

    **Where it is wired:**

    - `runCancellableModelCall` builds the loan, stores it on the actor, binds it as a task local around the model call, and **closes** it in the same `defer` that clears it — so a run that detached and outlived the call cannot borrow on a stale loan.
    - `beginTurn()` is now `throws`. It refuses a same-session re-entry **before** either gate is touched, then admits through `turnLock` and `admitToGenerationGate()`.
    - `admitToGenerationGate()` takes no permit at all when the ambient loan covers this gate, holds one, and is inside a tool call. `endTurn()` signals only for a turn that really holds one, so the count is untouched by a whole nested turn.
    - `acquireGenerationPermit()` / `releaseGenerationPermit()` keep the loan honest, so a turn parked in `awaitingUser(_:)` lends nothing and picks lending up again when the wait ends.
    - `DetachingTool` marks the window around the **inline** awaits only (`workTask.value` for `runToCompletion`, `raceSettlement` for `detaching`), never around `detach(...)`. `ContextBindingTool` marks its one always-inline call.

    **Acceptance criteria, each with its evidence:**

    - Nested `respond` on a different session completes — `aToolBodyGeneratesOnASecondSessionOverTheSameContainer`. Verified red first: without the borrow the turn parked, the run detached at its 20 s clock, and the turn answered with a pending envelope.
    - Nested `respond` on the same session fails clearly — `aToolBodyThatGeneratesOnItsOwnSessionIsRefused` asserts the typed `SessionReentryError` naming that session. Verified red first: without the refusal the turn parked on its own turn lock and reached the 30 s bound.
    - The permit count stays correct — every test in the suite ends with `expectGateUntouched`, which asserts one permit and no waiter.
    - `cancelCurrentTurn()` on a child that cannot be freed reports that it cannot — `beginTurn()` now mints `currentTurnId` **after** the gate, so a session still waiting for a permit answers `noTurnInFlight` instead of `requested` followed by `inFlightModelCall?.cancel()` on a `nil`. Covered by `cancelOnASessionWaitingForAPermitReportsItCannot`; verified red first.
    - Router-level regression test — `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift`, four tests, all through `router.resolve(profile:reporting:)`. No handle is hand-built, so every session shares the pool entry's one gate. A fourth test drives a three-deep chain and proves a **borrowed** permit can be lent on again.
    - The stale comment is corrected in `LanguageModelProfile.swift` and in `plan.md`. Both now say the gate is a throughput decision and that the resident container gives exclusive access on its own. `RoutedSession.swift`'s type doc carried the same claim and is corrected too.
    - The `awaitingUser(_:)` contract — the fix does **not** use its machinery, and the contract now says so in its own words: the wait is still for a person and for nothing else, a wait on the model has its own route, and the two never overlap.

    ### What did not work, and was not attempted

    Releasing the permit around every tool call was the first shape considered and rejected. It cannot satisfy the same-session criterion (that call would still park on `turnLock` without a sound), and it makes every tool call pay a gate re-acquire.

    Marking the window at the model call rather than at the tool wrappers was the second shape considered and rejected. A `.detaching` tool's background run inherits the task local, so it would have borrowed a permit and generated **beside** the turn that started it — a new hazard, not a fix.

    ### The one window this does not close, recorded honestly

    A detaching tool whose body starts generating inside the wait window and then detaches keeps its borrow until that generation ends, so the two can overlap for that stretch. The count stays exact; only the serialization is forfeited. This is the same class of limit `awaitingUser(_:)` already records, and it is written on `GenerationPermitLoan`.

    ### Discovered along the way — filed as `^d2ptrk1`

    `fork(workingDirectory:)` and the `transcript` getter both take the session's own `turnLock`. Called from inside that session's tool body they park forever, exactly as a same-session `respond` used to. Out of scope here; the card carries the shape and the two ways to answer it.
  timestamp: 2026-08-16T16:17:46.905024+00:00
- actor: claude-code
  id: 01m05nv2e0tfjyvj13y8fsx1jf
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean, zero warnings; `swift test` 941 + 27 + 24 tests pass, 0 failures, 1 pre-existing known issue (`BoundedWait.swift:114`, a deliberate `withKnownIssue`). 10 files — Sources/FoundationModelsRouter/Session/GenerationReentry.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, plan.md, Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift (new)
    - next: `/review`
  timestamp: 2026-08-16T16:17:54.624445+00:00
- actor: claude-code
  id: 01m05p00kg39wzxkwdfdkym9t4
  text: |-
    ### test — green
    - evidence: `swift build` clean (Build complete, no source warnings, only a pre-existing unrelated SwiftPM bundle-node warning from mlx-swift_Cmlx). `swift test` — 3 targets, all pass: 941 tests/89 suites (1 known issue, from the pre-existing `withKnownIssue` assertion in `BoundedWaitTests.swift`, unrelated to this change), 27 tests/11 suites, 24 tests/5 suites. Total 992 tests, 0 failures, 0 warnings, 0 unexplained skips (all skipped suites are the pre-existing hardware-gated "Gated real-model" integration suites).
    - checked the callout suites specifically: `ForkConcurrencyTests` ("Fork cuts in append-only history coordinates"), `PooledResidencyTests` ("Pooled model residency"), `HumanWaitGateTests` ("Human waits release the per-model generation gate..."), and `TurnCancellationTests` all pass with no permit-count drift.
    - the `cancelCurrentTurn()` test was already reconciled in the working tree: "cancelCurrentTurn() on a session still waiting for a generation permit reports that it cannot cancel" now asserts the new `noTurnInFlight` answer, and it passes. No further edit needed.
    - next: ready for review.
  timestamp: 2026-08-16T16:20:36.592672+00:00
- actor: claude-code
  id: 01m05pmp4ezermymzf6mdq1k5p
  text: |-
    ### review — findings
    - evidence: 2 findings (2 confirmed, 1 refuted) — Sources/FoundationModelsRouter/Session/GenerationReentry.swift:132, Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift:45
    - scope: review sha HEAD~1..HEAD (commit 14dd016), 9 files reviewed
    - next: label both method parameters per swift/fluent-usage, then re-review. Sweep each file for the same cause, not only the two lines named.
  timestamp: 2026-08-16T16:31:53.998388+00:00
- actor: claude-code
  id: 01m05pnt5wzh7vnt7j642f5cf5
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files; permit loan (`GenerationPermitLoan` task local), typed `SessionReentryError.sameSessionTurnInFlight`, stale "not safe to interleave" claim corrected, 4 new tests through `router.resolve(...)`
    - test: green — swift test, 992 tests (941 + 27 + 24), 0 failures; permit-leak assertions in ForkConcurrencyTests / HumanWaitGateTests / TurnCancellationTests all pass
    - commit: 14dd016
    - review: findings — Sources/FoundationModelsRouter/Session/GenerationReentry.swift:132, Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift:45 (both `swift/fluent-usage`)
    - note: the review engine confirmed nothing on the three flagged concerns — the tool-call window, the `cancelCurrentTurn()` behaviour change, and the loan lifetime / permit leak question. One candidate was refuted.
  timestamp: 2026-08-16T16:32:30.908573+00:00
- actor: claude-code
  id: 01m05q27hdbqfrc53w2jhs4kw1
  text: |
    ### Both `swift/fluent-usage` findings closed, and the cause swept

    I read the `swift/fluent-usage` rule text before I edited, then swept every unlabeled method parameter that commit `14dd016` added, not only the two lines named. The commit adds six such signatures. Four read as a phrase at the call site and are correct; two named by the findings, plus two more of the same cause, are corrected.

    **The two findings, word for word:**

    - `Sources/FoundationModelsRouter/Session/GenerationReentry.swift:132` — `setHoldsPermit(_:)` is now `func setHoldsPermit(to holdsPermit: Bool)`. Both call sites in `RoutedSessionActorTurnGating.swift` read `setHoldsPermit(to: true)` and `setHoldsPermit(to: false)`.
    - `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift:45` — `set(_:)` is now `func set(session: any RoutedSession)`. All four call sites read `target.set(session: nested)` and so on.

    **The same cause, at two sites the findings did not name:**

    - `GenerationReentry.swift` — `lends(_ gate:)` read aloud as "the loan lends the gate", which states the wrong thing: a loan lends a *permit*, and the gate is what the asking turn would wait on. The argument is not the direct object of the verb, so the preposition belongs on the label. It is now `func lends(over gate: AsyncSemaphore)`, and the call reads `loan.lends(over: generationGate)` — the same "a turn over `gate`" wording the doc comment already used.
    - `NestedGenerationReentryTests.swift` — `expectGateUntouched(_ gate:)` repeated the noun: the base name is already a whole clause, and the argument said "gate" a second time. This is the rule's `allViews.removeElement(button)` shape, whose stated fix is to drop the needless word from the base name. It is now `expectUntouched(_ gate:)`, so the call reads `Self.expectUntouched(gate)`. That matches the sibling helper `expectFinished(_ outcome:is:describing:)` in the same file.

    **The four left as they are, and why each reads as a phrase:**

    - `lends`'s sibling `withGenerationSuspendedForToolCall(_ body:)` — every call site passes a trailing closure, so no label is ever written.
    - `expectFinished(_ outcome:, is:, describing:)` — the first argument is the direct object: "expect finished outcome is expected, describing the outer turn".
    - `init(gate:sessionID:holdsPermit:)`, and the protocol conformances `respond(to:maxTokens:)` / `makeSession(instructions:tools:)` — already fully labeled.

    `Tests/FoundationModelsRouterTests/HuggingFaceMetadataSourceTests.swift:208` holds one more `handlerBox.set(handler)`. It is not in commit `14dd016` and is not in scope here.

    **Nothing about the concurrency moved.** The diff is argument labels plus one private test-helper name. The permit loan, the borrow decision in `admitToGenerationGate()`, the gate accounting in `endTurn()`, and every assertion in the suite are byte-for-byte the same behaviour. `git diff` on the source is six lines, all of them a label.
  timestamp: 2026-08-16T16:39:17.805712+00:00
- actor: claude-code
  id: 01m05q2e33kraw1n63hbfbsv78
  text: |
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/GenerationReentry.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift, Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift. `swift build --build-tests` complete, zero source warnings (only the pre-existing unrelated SwiftPM bundle-node warning from mlx-swift_Cmlx). `swift test` — 3 targets, 992 tests (941 + 27 + 24), 0 failures, 1 known issue (the pre-existing `withKnownIssue` at BoundedWait.swift:114). All four tests of "Nested generation from inside a tool body" pass.
    - both `## Review Findings` items are now `- [x]`; two more sites of the same cause were swept (`lends(over:)`, `expectUntouched(_:)`)
    - next: `/review`
  timestamp: 2026-08-16T16:39:24.515684+00:00
position_column: doing
position_ordinal: '80'
title: A nested respond on a shared resident container deadlocks on generationGate
---
A tool body that generates on the same resident container as its own turn parks for the full life of that turn. The `FoundationModelsMultitool` session measured this on real hardware.

## The mechanism

`beginTurn()` takes `turnLock` (for each session), then `generationGate` (for each resident container). `endTurn()` releases both, and it runs in a `defer` at the end of the whole turn bracket (`Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:104-105`).

`generationGate` is minted one time for each `PoolEntry` (`Router.swift:115`, `:480`) and given to every handle over that entry (`:953`). `ResidencyKey` is `(ref, role)` with `role = .llm(context:)` — there is no slot axis. Two slots that name the same reference at the same context are one entry with one `AsyncSemaphore(value: 1)`. `Router.swift:383-384` names this case.

So a nested `respond` on a different session over that container waits for a permit that only becomes free when the outer turn ends. The outer turn cannot end until the tool call returns. The tool call cannot return until the nested `respond` completes. This is a circular wait.

## Measured evidence

The peer stripped the case to one tool, both slots on one `ModelRef`, and **no grammar**. The tool body calls `slot.makeSession().respond(to:maxTokens:)`. It hangs. They reproduced it two times, and they read our gate with `@testable import`:

```
GATE permits=1 waiters=0     <- before the turn
GATE permits=0 waiters=0     <- beginTurn() took the permit
GATE permits=0 waiters=1     <- x33 samples, to the end of the run
```

Each run ended at approximately 165 seconds with `CancellationError`.

## Correct severity

The wait is **unresolvable while the turn lives**. It is not unkillable. `AsyncSemaphore.wait()` has no cancellation handler (`Concurrency/AsyncSemaphore.swift:57-71`), but a cancellation of the outer turn still runs `endTurn()`, which signals the gate. The waiter then observes its own cancellation and throws.

Two more problems make it silent:

- `cancelCurrentTurn()` on the parked child returns `.requested`, because `beginTurn()` sets `currentTurnId` before it waits on the gate. It then calls `inFlightModelCall?.cancel()` on a `nil`. The caller sees a cancellation that did nothing.
- There is no log, no event, and no diagnostic. CPU use is 0.0%.

## The gate is throughput, not safety

Do not treat the gate as a safety invariant:

- Commit `97b5aab` split it from `turnLock` and says `turnLock` gives transcript integrity while the gate gives throughput.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:575-580` says "Correctness does not rest on the generation gate anyway".
- The comment "MLX generation runs a single GPU stream and is not safe to interleave" (`LanguageModelProfile.swift:121-122`, `plan.md:706-709`) is stale. `git log -S` traces it to `6b79b1e`, a plan document written before the MLX integration existed. It has no citation and no test.
- Apple's `ModelContainer` in the vendored `mlx-swift-lm` gives exclusive access on its own. `mlx-swift-lm` also has `ToolBodyContainerReentryTests`, which makes its executor release the container across a tool call for this exact reason.

A nested generation is not a concurrent generation. The outer turn is suspended in the tool, so only one generation runs at a time. This is the same argument that `awaitingUser` already uses.

## Constraints on the fix

- `turnLock` must stay. A nested `respond` on the **same** session must continue to deadlock, because `turnLock` is the correctness gate. Only a nested `respond` on a **different** session over the same container can be admitted.
- `AsyncSemaphore` has no `tryWait` and no ceiling. `RoutedSessionActorTurnGating.swift:107-109` says a bare extra `signal()` would inflate the gate. Use bookkeeping like the `humanWaitDepth` / `humanWaitLenderTurnId` scheme.
- Do not silently re-use `awaitingUser(_:)`. `RoutedSession.swift:565` says it is "for a wait on a human, never on the model". If the fix uses that machinery, rewrite the contract honestly.

## Acceptance Criteria

- [x] A nested `respond` on a different session over the same resident container completes instead of parking
- [x] A nested `respond` on the same session still fails, and it fails with a clear error rather than a silent park
- [x] The gate permit count stays correct after a nested generation; it does not inflate
- [x] `cancelCurrentTurn()` on a parked child either frees it or reports that it cannot
- [x] A Router-level regression test covers the shape, like `mlx-swift-lm`'s `ToolBodyContainerReentryTests`
- [x] The stale "not safe to interleave" comment is corrected or removed
- [x] The `awaitingUser(_:)` contract is corrected if the fix uses its machinery

Reported by the `FoundationModelsMultitool` session. They hold `NestedGenerationProbeTests`, a gated suite that fails today by design, and they can confirm the fix in one run.

## Review Findings (2026-08-16 11:22)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 18 not reviewed.

> 18 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 18 file(s)

- [x] `Sources/FoundationModelsRouter/Session/GenerationReentry.swift:132` `swift/fluent-usage` — Method parameter should be labeled to form a grammatical phrase. `setHoldsPermit(_:)` reads as a sentence fragment, but should read as 'setHoldsPermit(to: value)' at the call site. Change signature to `func setHoldsPermit(to holdsPermit: Bool)` so call sites read as `setHoldsPermit(to: true)`.
- [x] `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift:45` `swift/fluent-usage` — Method parameter should be labeled to form a grammatical phrase. `set(_:)` reads as a sentence fragment, but should read as 'set(session: value)' at the call site. Change signature to `func set(session: any RoutedSession)` so call sites read as `set(session: session)`. #bug #nested-generation
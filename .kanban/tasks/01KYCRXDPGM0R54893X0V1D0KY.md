---
comments:
- actor: claude-code
  id: 01kyda7z252j78caanwsty8sa4
  text: |-
    Implemented. The single per-model gate is split in two:

    - `RoutedModel.serialGate` renamed to `RoutedModel.generationGate` (per-model, throughput). Rename swept Sources + Tests + doc comments; `RecordingLanguageModel`'s use of it is genuinely the generation gate and is unchanged.
    - New `RoutedSessionActor.turnLock` (`AsyncSemaphore(value: 1)`, minted per session, internal-not-private only so tests can read `waiterCount`). Taken first by every turn; `fork()` now takes *this* instead of the per-model gate for its `transcriptEntries()`/`makeFork(tools:)` window.
    - `generate`/`dispatchNextPrompt`/`compact` now bracket with `beginTurn()`/`endTurn()` (turn lock, then generation permit; released innermost-first).
    - `awaitingUser` added as a `RoutedSession` protocol requirement, implemented on the actor.

    Design notes worth keeping:
    - Signature had to become `awaitingUser<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T` (plan.md showed it unconstrained). It is an actor-isolated method, so under Swift 6 the closure and result must cross the actor boundary. `rethrows` in a protocol requirement compiles fine.
    - Release is guarded by `holdsGenerationPermit`: calling `awaitingUser` with no turn in flight must release nothing, else `signal()` mints a permit the session never acquired and two real generations could overlap.
    - Overlapping waits (two tools of one turn) are handled with `humanWaitDepth`; the re-acquire in `endHumanWait()` deliberately runs *before* the depth drops to 0, so a nested wait arriving during the re-acquire can't mistake itself for the outermost one.
    - Acquisition order is always turn lock then generation gate, and `fork()` only ever wants the turn lock — that is what keeps the pair deadlock-free.
    - Cancellation needs no special handling: `AsyncSemaphore.wait()` is non-throwing and completes even for a cancelled task, so the re-acquire on the throwing path always balances.
  timestamp: 2026-07-25T18:57:46.053523+00:00
- actor: claude-code
  id: 01kyda8fqcbxkf4s7jx8vgs6s6
  text: |-
    TDD record (red watched for every new test, twice over with two different mutations):

    New suite `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift`, 7 tests. Verified red by mutating the source, not by trusting the tests:
    - Mutation 1 (old world: one gate, no release at all) — the 3 gate-release tests fail: `humanWaitLetsAnotherSessionOnTheSameModelGenerate` (permits == 0, session B never runs), `overlappingHumanWaitsReleaseExactlyOnce`, `cancellingInsideAHumanWaitLeavesGatesBalanced`. The two turn-lock tests correctly still pass here — the old single gate satisfied that invariant by other means.
    - Mutation 2 (half-done split: gate released, but no per-session lock) — `secondTurnOnOneSessionStillBlocksDuringAHumanWait` fails (`maxActive == 2`, two turns overlap) and `forkRacingAHumanWaitReadsAConsistentTranscript` fails on all three assertions, including reading a transcript that ends on `.prompt` with no `.response` — the actual torn-transcript bug.
    Restored, then green: 7/7 in 0.007s.

    Dead ends / gotchas for the next agent:
    - First attempt at the cancellation test used `while !Task.isCancelled { await Task.yield() }` inside the wait. That hung the whole suite for reasons that had nothing to do with cancellation: the test's mid-turn hook had no prompt guard, so the *follow-up* "after" turn (the one that proves the gates rebalanced) also entered `awaitingUser` and parked forever on a semaphore nobody would signal again. Every hook in the suite now guards on its own prompt. Replaced the poll loop with `withTaskCancellationHandler` + a parked semaphore, which is both faster and closer to what a real elicitation does.
    - Debugging that hang: `swift test`'s stdout is block-buffered when redirected, so a hanging run shows nothing. `fputs(..., stderr)` traces do appear immediately; `sample <pid>` on the `swiftpm-testing-helper` process is what localized it.
    - The `Fixture` struct must retain the `LanguageModelProfile`: `RoutedLLM` holds its owning profile weakly, so returning only `profile.standard` traps with "makeSession requires a live owning LanguageModelProfile".

    Existing tests adapted (behavior claim moved from the per-model gate to the turn lock, same invariant): `MultiTurnSessionTests.forkHoldsSerialGateDuringMakeFork` renamed to `forkHoldsTurnLockDuringMakeFork` and now observes `turnLock`. `ForkConcurrencyTests.generationGateSerializesAndIsFIFO` is unchanged apart from the rename and is the standing evidence for "ordering unchanged when nobody calls awaitingUser".
  timestamp: 2026-07-25T18:58:03.116204+00:00
- actor: claude-code
  id: 01kyda8t7evvt4waz7zvj3g34v
  text: |-
    Two environment findings that cost time and will bite the next agent:

    1. **Do not run `swift format -i -r Sources Tests` on this repo.** With no `.swift-format` config present, swift-format's defaults (2-space indent, ordered imports) disagree with the entire codebase (4-space, unsorted imports). Running it rewrote ~100 files with a 44-insertions/44-deletions-per-file churn. `.github/workflows/ci.yml` has no format or lint step, so nothing in CI requires it. I reverted the whole reformat and re-applied my edits by hand; new code follows the repo's existing 4-space style.

    2. **A concurrent commit landed mid-task.** Commit `26d6d9d` ("docs: drop references to the never-implemented harness package", 12:15:45) was made by another worker in this same checkout and swept up my then-uncommitted `serialGate` -> `generationGate` rename in the files it touched. So HEAD already contains part of this task's rename. My working tree is HEAD + the split, verified with `git diff` (no committed content reverted; the only harness-related removals in the diff are that other worker's own still-uncommitted plan.md edits, which my plan.md edit preserved). Worth being aware of if the diff looks smaller than expected.

    Verification (fresh, this tree): `swift build` -> "Build complete!"; `swift test` -> 555 tests / 57 suites passed, 18 / 7 passed, 12 / 4 passed, exit 0. Baseline before the change was 548 + 18 + 12, so +7 = exactly the new suite, with no existing test lost or newly skipped.
  timestamp: 2026-07-25T18:58:13.870086+00:00
- actor: claude-code
  id: 01kydbecqbdqwr3w751mv6kqfd
  text: |-
    Adversarial double-check returned REVISE with one real defect. All findings resolved.

    **HIGH (real bug, fixed) — `endTurn()` signalled a generation permit it might not hold.** `beginHumanWait()` guarded its release on `holdsGenerationPermit`; `endTurn()` did not guard its own. So if a wait released the turn's permit and was still outstanding when the turn ended, the gate got two signals for one acquisition. `AsyncSemaphore.signal()` has no ceiling, so `permits` went to 2 — two concurrent generations on a single GPU stream — and `holdsGenerationPermit` was left `true` with no turn in flight, so every later out-of-turn wait inflated it again. Permanent corruption, not a transient. Reachable without any misuse of internals: an upstream coordinator calling `awaitingUser` cannot see whether a turn-loop `dispatchNextPrompt()` is mid-turn, and my own doc comment invited exactly that by advertising the no-turn case as fine.

    I had considered and *dismissed* this case during implementation, reasoning it "only weakens serialization temporarily, doesn't corrupt counts". That was wrong — I traced only as far as the wait's own re-acquire and missed the stale flag. Fix: `endTurn()` releases only if `holdsGenerationPermit`, and otherwise clears `humanWaitReleasedPermit` so the orphaned wait does not re-acquire from a lender that is gone. Counts now stay exact in every ordering.

    Regression test written first and verified red before the fix: `waitOverlappingAnotherTurnDoesNotInflateTheGate` — a turn parks in the backend *without* calling `awaitingUser`, an out-of-turn wait overlaps it, and the gate is asserted at one permit after the turn ends and again from inside a further wait (the stale-flag probe). Both assertions read 2 pre-fix. Reverted the fix again afterwards to confirm only this test fails and the other 7 stay green, then restored.

    Considered and rejected the reviewer's optional turn-epoch suggestion: an epoch would make the *re-acquire* turn-scoped, which the flag fix already achieves, and it cannot prevent the out-of-turn *release* (nothing at that point can tell an in-turn caller from an out-of-turn one without threading an explicit token through the tool). Not worth the extra state.

    Other findings, all addressed:
    - MEDIUM — `awaitingUser`'s soundness precondition was argued in prose but never stated as a caller obligation. Added a `- Precondition:` (call from inside a tool the SDK invoked for *this* session's in-flight turn; do not let the wait outlive that tool call) and rewrote the misuse paragraph so it reads as a safety net rather than an invitation. Also documented that sibling waits re-acquiring only on the last one is correct, not sloppy: the SDK resumes a turn's parallel tool calls together, so no model work runs until the last returns.
    - LOW — `AsyncSemaphore`'s own type doc still said "both router gates" / "per-model serial generation gate". There are three gates now and value 1 gives two of them; reworded to match plan.md.
    - LOW — plan.md's "Serialization is structural" bullet still claimed strict submission order across a model's whole family. The split genuinely changes that: order is strict submission order *within* a session (turn-lock FIFO) and FIFO arrival order at the generation gate across sessions, so a turn on an idle session can overtake one queued on a busy session's turn lock. Scoped the claim and named the trade as the throughput the split buys. Worth flagging for review: acceptance criterion 6 holds for the FIFO test and for single-session ordering, but this cross-session nuance is a real (and unavoidable) consequence of splitting the gate.
    - LOW / declined with reasoning — no default implementation for the new public protocol requirement. Adding `extension RoutedSession { func awaitingUser(...) { try await body() } }` would keep it source-compatible for out-of-module conformers, but the plausible out-of-module conformer is a *decorator* wrapping a real session, and a default would silently not forward to the wrapped session's gates — a worse failure than a compile error. Left as a requirement so the compiler forces every conformer to decide. Only `RoutedSessionActor` conforms in-repo.

    Reviewer explicitly cleared: no deadlock (single acquisition order; `fork()` takes only the turn lock and never wants the gate; `performAutoCompaction`/`fold` correctly take neither), `endHumanWait()`'s re-acquire-before-decrement ordering, the nested/sibling depth accounting, criteria 1/3/4/6, the rename's completeness, and that the adapted existing tests are faithful re-labelings rather than weakenings.

    Final verification after all fixes: `swift build` exit 0 "Build complete!"; `swift test` 556 tests / 57 suites passed, 18 / 7 passed, 12 / 4 passed, exit 0. (556 = 548 baseline + 8 new.)
  timestamp: 2026-07-25T19:18:45.227338+00:00
- actor: claude-code
  id: 01kydcm9daqdbxtrj9ccw7n1x9
  text: |-
    Second adversarial pass returned REVISE again, and it was right: my first fix traded a transient count inflation for a permanent model-wide deadlock. Fixed at the root this time.

    **HIGH (real, worse than the first) — orphaned re-acquire stranded the only permit.** `endHumanWait()` cleared `humanWaitReleasedPermit` *before* `await acquireGenerationPermit()`, so the flag structurally could not represent "my lender went away while I was suspended". `generationGate.wait()` is a nonisolated async call, so the actor is reentrant across it — and that window is not exotic, it is the gate's normal contended state. Trace: turn T holds the permit; an out-of-turn wait borrows it; the wait ends and suspends re-acquiring; T's model call returns and `endTurn()` runs seeing `holdsGenerationPermit == false`, so it correctly signals nothing; the wait then resumes holding a permit that no turn will ever release. Final state: `availablePermits == 0`, `waiterCount == 0`, no turn in flight. Every later turn on every session and fork over that model parks in `beginTurn()` forever. My previous fix's `else { humanWaitReleasedPermit = false }` is exactly what made T signal nothing, so the fix caused it.

    Root fix — re-validate the lender **after** the acquire, keyed on turn identity rather than a boolean:
    - `currentTurnID` (monotonic, stamped in `beginTurn()`, cleared in `endTurn()`) plus `humanWaitLenderTurnID` replace `humanWaitReleasedPermit`. Monotonic ids so a later turn can never be mistaken for the lender (no ABA).
    - `endHumanWait()` re-acquires, then hands the permit straight back if `currentTurnID != lender`. `endTurn()` keeps its `if holdsGenerationPermit` guard (still needed, or the turn-ends-first ordering double-signals) and now also clears `currentTurnID`, which is the signal the suspended wait reads.
    - The `else` branch is gone: post-acquire re-validation subsumes it, so there is one mechanism for one invariant — *a wait keeps a re-acquired permit only while its lending turn is still in flight*.

    I traced all orderings against the new code before running anything: in-turn wait; out-of-turn wait ending after the turn; out-of-turn wait ending during the turn (the re-acquire race); a *new* turn starting during the re-acquire (its parked acquire receives the handed-back permit); nested and sibling waits; wait with no turn in flight; cancellation. Count exact in all of them.

    **Reversing my earlier judgement:** I declined the reviewer's turn-epoch suggestion last round as redundant with the flag. That was wrong for a reason I want recorded — I compared the two only for the orderings I had already thought of, and the epoch's whole value is the ordering I had not (re-validation across a suspension). The lesson is that a flag set before an `await` cannot answer a question about the state after it.

    New test, red before the fix: `turnEndingDuringAReAcquireStrandsNoPermit` — session A's turn parks holding the permit, an out-of-turn wait borrows it, session B's turn takes the freed permit and parks so the re-acquire *must* suspend (spun on `waiterCount == 1` to prove it is in flight), then A's turn ends inside that window. Pre-fix: `availablePermits == 0` and the follow-up turn never runs. Post-fix green. Re-verified by removing only the post-acquire re-validation: exactly the two out-of-turn tests fail (6 issues), the other 7 pass.

    **Test-infrastructure defect found while doing that (my bug, not the reviewer's finding).** Four tests ended with `#expect(try await session.respond(to: "after") == "ok-after")` to show the session still works. Under a stranded-permit regression that call parks forever, so a regression *hung the whole suite* instead of failing — the worst possible failure mode for the very bug being guarded. Extracted `followUpTurnCompletes(on:observer:)`: launch the turn, spin bounded on the observer's exit record, and only then await it. First cut of that helper returned at the observer's exit, which is *inside* `backend.respond` and therefore before `endTurn()` releases the permit — that made the following permit assertions racy and produced two unexplained failures under mutation. Now it awaits the task once completion is observed (safe: past the model call, nothing left in the turn waits on a gate), which removed both spurious failures.

    LOW findings applied:
    - The sibling-wait design rests on FoundationModels resuming a turn's parallel tool calls together. Now labelled **empirical status unverified in this environment**, following `MLXFoundationModelsSessionBackend.usageTokenCounts()`'s existing convention, with a note on what would change if it is wrong (per-tool rather than per-turn release) and that the count does not depend on it.
    - Corrected the "count stays exact" sentence to name the re-acquire ordering explicitly, now that it is true again.
    - Documented the degradation the reviewer spotted: an outstanding out-of-turn wait inflates the wait depth, so a *legitimate* in-turn wait arriving during it is not the outermost and releases nothing — that turn silently goes back to blocking the model. Accounting survives misuse; the optimization does not.
    - Skipped the detached-`Task` case as agreed: same `endTurn()`-with-no-permit branch, no new coverage.

    Verification: `swift build` exit 0; full `swift test` 557 / 57 suites, 18 / 7, 12 / 4, exit 0. The new suite also run 3x back-to-back in parallel mode, 9/9 each time, to check the concurrency tests for flakiness.

    Not done, deliberately: `swift format -i -r Sources Tests`. Re-confirmed it rewrites ~100 unrelated files (2-space vs the repo's 4-space, plus import reordering), there is no `.swift-format` config, and `.github/workflows/ci.yml` has no format step. Running it would bury this change in unrelated churn. New code follows the repo's existing style. Flagging rather than silently skipping.
  timestamp: 2026-07-25T19:39:27.018323+00:00
- actor: claude-code
  id: 01kydcpn7qa655rxzs56tdgtev
  text: |-
    Orchestrator (/finish) iteration 1 — implement landed green, left in `doing`.

    Implementation reported: 557/57 + 18/7 + 12/4 suites, exit 0 (baseline 548+18+12, +9 = the new `HumanWaitGateTests.swift` suite). Now running independent /test verification before checkpoint commit + /review.

    Two things carried forward for the reviewer's eye:

    1. **Formatter deliberately skipped.** `swift format -i -r Sources Tests` reformats ~100 unrelated files (swift-format defaults to 2-space, repo is 4-space; no `.swift-format` config in the repo; `.github/workflows/ci.yml` has no format step). Running it would bury this change in churn. Skipped and flagged rather than silently applied.

    2. **Cross-session ordering nuance is a real, intended consequence of the split** (documented in plan.md): ordering is strict submission order *within* a session, FIFO arrival at the generation gate *across* sessions — so a turn on an idle session can overtake one queued behind a busy session's turn lock. Worth a reviewer's judgment on whether that trade is acceptable.

    **Dead ends / what not to repeat:** two successive permit-accounting defects were found by adversarial review, and the second was *introduced by the fix for the first* — a transient gate-count inflation became a permanent model-wide deadlock via an orphaned re-acquire across a suspension point in `endHumanWait()`. Root cause both times: treating state read *before* an `await` as if it still held *after* it. The working fix is turn-identity re-validation *after* the re-acquire (a pre-check alone is structurally insufficient — it cannot represent "the lending turn went away while I was re-acquiring"). Regression tests cover both orderings. Do not "simplify" that post-acquire re-validation away.

    **Hygiene note:** the implementing agent ran `git checkout -- Sources Tests` to undo the unwanted formatter run, and a concurrent commit (26d6d9d) landed mid-task sweeping part of this task's `serialGate`→`generationGate` rename into HEAD. /test is verifying nothing was lost.
  timestamp: 2026-07-25T19:40:44.663934+00:00
- actor: claude-code
  id: 01kydhvwbegx0beys03qj8n46c
  text: |-
    Review findings (2026-07-25 14:49) worked. All four boxes now `- [x]`; task left in `doing`.

    **Finding 1 — `ID` -> `Id` rename.** All 13 references renamed in `Sources/FoundationModelsRouter/Session/RoutedSession.swift`, including the DocC `` ``currentTurnId`` `` link in `endTurn()`'s doc comment: `currentTurnID` (6) -> `currentTurnId`, `lastTurnID` (3) -> `lastTurnId`, `humanWaitLenderTurnID` (4) -> `humanWaitLenderTurnId`. All three are `private` and nothing in Tests referenced them, so the rename is confined to one file. (Finding cited lines 554/557/561; they are at 754/757/761 — the file grew after the review snapshot.)

    **Zero-recurrence sweep, as the finding demanded.** Swept every `ID`/`IDs`-suffixed identifier across all 19 Sources/Tests files that commit `97b5aab` touched. What remains is `assetIDs` (Apple's `Transcript.Response(assetIDs:)`), `SessionOutbox.ItemID`, `ULID`, `UUID` — all external APIs or pre-existing public types, none introduced by this task (`git show 97b5aab -- Sources Tests | grep -c ItemID` == 0; `ItemID` is declared in `SessionOutbox.swift`, which this task never touched, and renaming a public type would be a breaking API change and out of scope). The repo-wide `ID` users `correlationID`, `taskID`, `seedID`, `tasksByID`, `seedsByID`, `firstID` all live exclusively in files this task never touched. So: no other identifier introduced by this task carries the inconsistency.

    **Load-bearing logic untouched, proved mechanically rather than by eye.** The double-check agent reverse-applied the three renames to the working-tree file and diffed against `git show HEAD:...RoutedSession.swift` — **empty diff**. The change is provably a pure identifier substitution: `endHumanWait()`'s acquire-then-revalidate ordering (`await acquireGenerationPermit()` *then* `if currentTurnId != lender { releaseGenerationPermit() }`), `endTurn()`'s `currentTurnId = nil` ahead of its `if holdsGenerationPermit` guard, and `beginTurn()`'s stamp-then-acquire order are byte-for-byte unchanged. The post-acquire re-validation was not weakened.

    **Finding 2 — named cap.** The `100_000` cap was already centralized in the single `spin(until:)` helper, so one extraction covers all ten spin call sites: `private static let spinYieldLimit = 100_000`, with a doc comment explaining it as a timeout in scheduler hops rather than wall clock. **Deviation from the finding's literal suggestion, deliberate:** it suggested `SPIN_TIMEOUT_ITERATIONS`; SCREAMING_SNAKE is neither Swift convention nor this repo's — the file's own sibling constant is `private static let stubDimension = 8`, so `spinYieldLimit` matches. Noted in the checklist item rather than silently changed.

    Swept the rest of the added code for bare caps: no multi-digit literal was added to `Sources` by `97b5aab` at all (its Sources diff is code + doc comments only). Inside `HumanWaitGateTests.swift` the remaining literals are fixture data replicated verbatim from the prevailing pattern — `maxConcurrentForks: 4` (also in `TranscriptReconstructionTests`, `TranscriptTreeTests`), `totalRAM: 64 << 30` (a dozen suites), the model-config JSON, `stubDimension` (already named) — plus `AsyncSemaphore(value: 0/1)` rendezvous counts and `#expect(... == 1)` exact-state assertions. None is an unnamed cap. The ten pre-existing test files were not touched; note for the record that `RecordingLanguageModelTests`, `MultiTurnSessionTests` and `ForkConcurrencyTests` each still carry their own bare `100_000` spin cap, explicitly out of scope here.

    **Worth keeping — the "well under a second" doc claim was checked, and my first check was too weak.** I benchmarked an exhausted 100_000-yield spin at ~30 ms, but in an *optimized standalone* binary, which is the wrong configuration (`swift test` builds debug, and every test in this suite is `@MainActor`). The verifier re-measured: MainActor-isolated top-level code takes **0.897 s**, and **1.66 s** with an actor-hopping condition — which would have falsified the claim. But that shape does not match the code: `spin(until:)` is *nonisolated* async, so under Swift 6 language mode (tools-version 6.1, no `NonisolatedNonsendingByDefault`) its loop does not inherit the caller's MainActor. Reproducing the exact shape at `-Onone -swift-version 6` gives **0.046–0.060 s**, with either a lock-read or an actor-isolated condition. Claim holds by ~20x. Lesson for the next agent: benchmark in the configuration the tests actually run in, and check the isolation the loop really has, not the caller's.

    `swift format` again deliberately not run, for the reasons already on this card.

    Verification (fresh, both edits in place): `swift build` exit 0 "Build complete!" with no new warnings; full `swift test` exit 0 at **587 tests / 68 suites** (557/57 + 18/7 + 12/4), zero issues — identical to the pre-change baseline, nothing lost or newly skipped. `swift test --filter HumanWaitGateTests` run 3x: 9/9 each time. Adversarial double-check: **PASS**, no findings, having independently reproduced the build, the full suite, and the filtered suite. Working tree is exactly two files, 23 insertions / 14 deletions, every line attributable to one of the two findings.

    Non-defect for any later re-review: `currentTurnID` still appears in this card's `.md` and `.jsonl`. That is the verbatim finding text and the append-only audit log, which must name the old identifier to make sense; not rewritten.
  timestamp: 2026-07-25T21:10:58.670067+00:00
- actor: claude-code
  id: 01kydjycp74bg4nqyqb92xy3yc
  text: |-
    Orchestrator (/finish) — task complete in 2 iterations.

    **Iteration 1** — implement landed the split gate green; checkpoint `97b5aab` (24 files, +1470/-125, new `HumanWaitGateTests.swift` tracked). Review of that delta: 4 findings recorded (62 confirmed / 91 refuted by the engine; 58 dropped as pre-existing test-code refactors).

    **Iteration 2** — the 4 findings fixed (`*TurnID` → `*TurnId` intra-file consistency, `100_000` spin cap → `spinYieldLimit`); checkpoint `3f3f58f` (4 files, +60/-14). Review of that delta: **clean, 0 in-scope findings** → `done`.

    Final test status: `swift build --build-tests` exit 0, zero Swift compiler warnings verified on a forced full recompile of all 131 files (not a cache hit); full `swift test` exit 0 at **587 tests / 68 suites** (557/57 + 18/7 + 12/4). Affected concurrency suites run 10× consecutively with no flakiness. Both checkpoints are local commits only — **nothing pushed**, branch is `ahead 2` of `origin/main`.

    **Follow-up work this task deliberately did not do** (needs its own card — out of scope here, not defects introduced by this change):
    - `RoutedSession.swift` — three-way near-verbatim duplication across `streamResponse` / `streamEvents` / `streamEventsGenerating`+`streamGenerating` (~lines 896/960/990). A real consolidation touching public streaming entry points.
    - `RoutedSession.swift:1270` — magic numbers in `max(target / 2, 0.1)` (retry-fold halving factor and minimum target).
    - The identical bare `for _ in 0..<100_000` spin cap persists in `RecordingLanguageModelTests.swift:337`, `MultiTurnSessionTests.swift:344`, `ForkConcurrencyTests.swift:299` — three occurrences of one magic bound in a single target is the rule-of-three case for a shared test helper rather than four private constants.
    - `SessionOutbox.ItemID` and `event.correlationID` still use the `ID` spelling. Aligning them with the repo's `Id` convention is a **breaking public-API change**, so it needs its own task.

    **Verification note worth keeping:** an initial `swift build` can be a full cache hit and therefore cannot surface compiler warnings — SwiftPM is content-hash based, so `touch` alone does not invalidate it. Warning claims need a forced recompile of the package's own targets to mean anything. The `missing creator for mutated node: mlx-swift_Cmlx.bundle` warning is pre-existing, comes from the vendored dependency's resource bundle rather than the Swift compiler, and is not actionable from this repo.
  timestamp: 2026-07-25T21:29:49.511128+00:00
position_column: done
position_ordinal: e080
title: Split the serial gate so human waits do not stall the model
---
## What

See `plan.md` -> Concurrency -> **Human waits must not stall the model: split the gate**, and Decisions -> **Human waits release the model gate**.

A tool call that awaits a **human** -- MCP elicitation, a permission prompt -- currently holds the model hostage for the whole wait.

`generate(...)` acquires the serial gate (`await serialGate.wait()` / `defer { serialGate.signal() }`, `RoutedSession.swift:1433-1434`) and holds it across `runTurn` (`:1488`) -> `runTurnAttempt` -> `try await body(composedPrompt)` (`:1575`). FoundationModels invokes tools *inside* that model call, so a tool's `await` runs with the gate held. That gate is the **per-model** one, documented as "shared with the owning model's other sessions and forks."

Consequence: one user taking a minute to answer blocks every other session and fork on that model, head-of-line, for the full minute.

## Work

One semaphore is doing two different jobs. Split them:

- **Per-session turn lock -- correctness.** One `LanguageModelSession` must never have two turns in flight; this also protects the `transcript` read that `makeFork(tools:)` races against (the reason the gate is taken in `makeFork`'s window today). **Never released early.**
- **Per-model generation gate -- throughput.** Serializes real model work across sessions and forks. **This** is the one released during a human wait.

Then expose the scoped release:

```swift
extension RoutedSession {
    /// Releases the per-model generation gate for the duration of `body`,
    /// re-acquiring before returning. For waits on a *human* -- never on the model.
    func awaitingUser<T>(_ body: () async throws -> T) async rethrows -> T
}
```

Sound because **no model work is in flight**: the SDK is suspended awaiting the tool call. Releasing the per-model gate lets other sessions generate; holding the per-session lock still prevents a second turn here and still blocks a concurrent fork's transcript read.

The re-acquire is itself a wait -- a tool resuming after a long pause may queue behind other sessions' turns. That is correct: it becomes an ordinary competitor for the model rather than its owner.

## Scope boundary

**Router does not implement elicitation.** It owns no user channel; `SessionOutbox`/`SessionEvent` is a one-way outbound projection, not a request/response with a human. The coordinator lives in **FoundationModelsACPAgent**, which depends on both Router and `FoundationModelsMCP` and is therefore the right caller for `awaitingUser`. Router's entire contribution is making the wait cheap -- and keeping `FoundationModelsMCP` free of any Router dependency.

## Acceptance Criteria

- [x] The single serial gate is split into a per-session turn lock and a per-model generation gate. (`RoutedSessionActor.turnLock`; `RoutedModel.serialGate` renamed `generationGate`.)
- [x] `awaitingUser` releases only the per-model gate and re-acquires before returning.
- [x] Two turns on one session still cannot interleave, including while a human wait is outstanding.
- [x] A concurrent `makeFork(tools:)` transcript read is still serialized against an in-flight turn. (`fork()` now takes the turn lock, so it stays serialized even against a turn parked in `awaitingUser`.)
- [x] Cancellation during a human wait propagates correctly and does not leak a gate permit.
- [x] Existing turn-loop ordering guarantees (submission-order serialization) are unchanged when nobody calls `awaitingUser`. (Strict submission order within a session; across sessions it is now FIFO arrival at the generation gate rather than one global queue -- an unavoidable consequence of the split, documented in plan.md. See review note in comments.)

## Tests

- [x] Session A inside `awaitingUser` does not block session B on the same model from generating -- the regression this task exists for.
- [x] A second turn on session A is still blocked while A is inside `awaitingUser`.
- [x] `makeFork` racing a turn that is inside `awaitingUser` still reads a consistent transcript. (Asserts the child never sees a `.prompt` with no `.response`.)
- [x] Throwing from `body` re-acquires the gate and propagates the error (no permit leak).
- [x] Cancelling the task inside `awaitingUser` leaves gate counts balanced.
- [x] Without `awaitingUser`, turn serialization and ordering match current behavior exactly. (`ForkConcurrencyTests.generationGateSerializesAndIsFIFO`, `MultiTurnSessionTests.forkHoldsTurnLockDuringMakeFork`.)
- [x] Extra, beyond the plan -- permit accounting under precondition violation, both defects found by adversarial review: overlapping waits release/re-acquire exactly once; a wait with no turn in flight releases nothing; a wait overlapping a turn it is not part of cannot inflate the gate; a turn ending while a wait's re-acquire is suspended strands no permit (the deadlock my own first fix introduced).

## Workflow

- Use `/tdd` -- write failing tests first, then implement to make them pass.

## Review Findings (2026-07-25 14:49)

Scope: `HEAD~1..HEAD` (commit `97b5aab`). 62 findings returned by the engine; 58 dropped under the review skill's standing exception against refactoring pre-existing test code (stub/fixture deduplication, named-constant extraction, and added doc comments in test files whose only change in this commit was the `serialGate` -> `generationGate` comment rename). The four below are the surviving items.

- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:554` — Property name `currentTurnID` uses uppercase `ID` suffix, inconsistent with codebase pattern of `Id`. Other identifiers in this file use `routerId`, `sessionId`, `parentId`, `toolCallIds` — all using `Id` or `Ids` not `ID` or `IDs`. Rename to `currentTurnId`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:557` — Property name `lastTurnID` uses uppercase `ID` suffix, inconsistent with codebase pattern of `Id`. Should match `routerId`, `sessionId`, `parentId` convention throughout the file. Rename to `lastTurnId`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:561` — Property name `humanWaitLenderTurnID` uses uppercase `ID` suffix, inconsistent with codebase pattern of `Id`. Should match `routerId`, `sessionId`, `parentId` convention throughout the file. Rename to `humanWaitLenderTurnId`.
- [x] `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:329` — Hardcoded literal 100_000 is a spin-loop iteration limit acting as a timeout; this configuration value should be a named constant. Extracted as `private static let spinYieldLimit = 100_000` (repo/Swift lowerCamelCase rather than the finding's `SPIN_TIMEOUT_ITERATIONS`, matching the file's existing `stubDimension`) and used as `for _ in 0..<spinYieldLimit`.

---
comments:
- actor: claude-code
  id: 01kydkh4avpbdtsfzf6dh18c9a
  text: |
    Picked up; moved to doing. Research done — design settled before touching code.

    Facts established:
    - No `StopReason` type exists anywhere in Sources/Tests/plan.md, so "a StopReason" in the card is the ACP-side concept, not an existing Router type. Router will express the observed outcome as `CancellationError` thrown from `respond`/`streamResponse`/`streamEvents`, and document that mapping it to an ACP stop reason is the caller's job (Router owns no ACP surface).
    - The turn chokepoint is `generate(grammar:prompt:onEvent:_:)` -> `runTurn(...)` -> `runTurnAttempt(...)`, where `let response = try await body(composedPrompt)` is the single point the model call (and therefore every SDK-invoked tool) runs at. That is where a cancellable boundary belongs, per the card ("cancelling the Task that owns body(composedPrompt)").
    - Deliberately NOT wrapping the whole turn in a Task: recording (`finishTurnAndRequeueIfUnattached`, the synthetic bodyless close, `append`) must stay outside the cancelled region so a cancelled turn is never half-written. Wrapping only `body` gives that for free — a cancelled body throws into the existing catch path, which already records exactly like any other failed turn.

    Plan:
    1. `RoutedSession.cancelCurrentTurn() async -> TurnCancellationResult` (`.requested` / `.noTurnInFlight`), new public enum modelled on `SessionOutbox.PromptQueueMutationResult`.
    2. Actor state: `inFlightTurnBody: Task<String, Error>?` + `cancelRequestedTurnId: UInt64?` keyed to the existing monotonic `currentTurnId`, so a cancel that lands before the body task exists (during the proactive fold, or between a failed attempt and its retry) still throws `CancellationError` at the next attempt instead of being lost, and a stale request can never bleed into a later turn.
    3. `body` becomes `@escaping @Sendable` so it can be sent into that Task (needs `wrapChunk` in `streamGeneratingBody` marked `@Sendable` too). `withTaskCancellationHandler` around `await task.value` so cancelling the CALLER's own Task still propagates — otherwise wrapping in an unstructured Task would silently break the existing "cancel your own enclosing Task" contract plan.md documents.
    4. Gate accounting untouched: no changes to beginTurn/endTurn/beginHumanWait/endHumanWait. A cancelled tool parked in `awaitingUser` throws out of `body()`, `endHumanWait()` re-acquires (AsyncSemaphore.wait() is cancellation-immune), `endTurn()` releases — the existing hard-won path, asserted by new tests rather than modified.
    5. Outbox rule: the existing attach-or-requeue rule applies unchanged (delivered if the SDK durably appended this turn's `.prompt`, re-queued if it appended nothing). Documented and asserted BOTH ways rather than a new mechanism.
  timestamp: 2026-07-25T21:40:03.547413+00:00
- actor: claude-code
  id: 01kydpac3788gf5x8ayq7scbax
  text: |
    Implementation landed, green. Files:

    - `Sources/FoundationModelsRouter/Session/RoutedSession.swift` — new public `TurnCancellationResult` (`.requested` / `.noTurnInFlight`), new `RoutedSession.cancelCurrentTurn()` requirement with the full contract documented (what the caller observes, transcript, outbox, gates, advisory-past-the-boundary), actor state `inFlightModelCall` + `cancelRequestedTurnId`, `runCancellableModelCall(composedPrompt:_:)` wrapping only `body(composedPrompt)`, `endTurn()` clears the request, `body` plumbed as `@escaping @Sendable` through `generate`/`runTurn`/`runTurnAttempt`/`respondBody` (+ `wrapChunk` `@Sendable`, two `self.` qualifications in the stream paths).
    - `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift` — new suite, 10 tests.
    - `plan.md` — the "Cancellation is queue-side" bullet became "two halves, queue-side and in-flight", stating the ACP->Router->MCP chain, the recording/outbox/gate consequences, and that propagation past the boundary is advisory.

    Test status: `swift build` exit 0, full `swift test` exit 0 at **597 tests / 69 suites** (567/58 + 18/7 + 12/4), run twice consecutively. Baseline was 587/68, so +10 tests / +1 suite. Zero compiler warnings verified on a *forced* recompile of both changed files (appended a probe comment, rebuilt, reverted) — a cache-hit build cannot prove that.

    Red-green verified by reverting the fix twice, not just by watching new tests pass:
    - Neutering `inFlightModelCall?.cancel()` makes `cancellingAnInFlightTurnReachesTheToolCall` and `cancellingATurnParkedInAwaitingUserKeepsGatesBalanced` fail (not hang — each has a bounded-spin escape hatch modelled on `HumanWaitGateTests.followUpTurnCompletes`).
    - Neutering the `cancelRequestedTurnId` pre-check makes `cancellationSurvivesIntoTheOverflowRetry` fail with `ProbeError.modelReenteredAfterCancellation`.

    Discoveries / dead ends worth knowing:
    1. **Two tests hung for 30 minutes on the first full run.** Cause was in the *tests*, not the implementation: a turn that drained outbox events hands the backend the *composed* prompt (preamble + blank line + own prompt), so the mid-turn hook's `turnPrompt == prompt` guard never fired, the tool never parked, and the test sat on its semaphore forever. Fixed by matching `hasSuffix(prompt)` and documenting why. Any future hook-based test that also stages outbox events must do the same.
    2. **`cancelling twice` was genuinely racy** as first written: with a tool that unwinds from its own cancellation handler, the whole turn can finish between the two `cancelCurrentTurn()` calls, so the second legitimately returned `.noTurnInFlight`. Rewritten to park on a semaphore the *test* releases, so "twice against one in-flight turn" is deterministic.
    3. **The `Sendable` plumbing was cheaper than expected** — `@escaping @Sendable` on `body` plus `@Sendable` on `streamGeneratingBody`'s `wrapChunk` and two `self.` qualifications; no other call site needed touching, and no `Element: Sendable` constraint was required.
    4. **`withTaskCancellationHandler` around `await modelCall.value` is load-bearing.** An unstructured `Task` is not a child, so without it, wrapping the model call would have silently broken the pre-existing contract that a caller can cancel a turn by cancelling its own enclosing `Task` (plan.md, Turn loop). `cancellingTheCallersOwnTaskStillReachesTheToolCall` pins it.
    5. **The pre-check is not defensive padding.** Without it, `cancelCurrentTurn()` on a budgeted session silently re-runs the entire model call, tool calls included, on the overflow retry — a stop that stops nothing. That is what test 3 above proves.
    6. Nothing in `Sources/.../Recording/` or `SessionOutbox` observes cancellation (no `checkCancellation`/`isCancelled`/`Task.sleep`), so a turn cancelled through the *caller's* task still records completely too — asserted in `cancellingTheCallersOwnTaskStillReachesTheToolCall`.
    7. Gate code was **not** modified: `beginTurn`/`endTurn`/`beginHumanWait`/`endHumanWait` are byte-identical apart from one added `cancelRequestedTurnId = nil` in `endTurn` (inert w.r.t. permits). `HumanWaitGateTests` still passes unchanged.
  timestamp: 2026-07-25T22:28:47.847660+00:00
- actor: claude-code
  id: 01kydqmb6zawk2r42azwgk4950
  text: |
    Adversarial review came back REVISE with 5 findings. All 5 addressed; two of them were real behavioral bugs, not just test/doc gaps. Corrected state: `swift build` exit 0, full `swift test` exit 0 at **599 tests / 69 suites** (569/58 + 18/7 + 12/4), three consecutive runs, zero warnings on a forced recompile.

    **Finding 1 (Medium) — three tests would HANG, not fail, on a propagation regression; my earlier red-verification note was scoped to the two tests I filtered on and should not have been read as suite-wide.** Fixed properly rather than patched per test: the escape hatch is now one shared helper, `awaitCancelledUnwind(_:observer:parked:)`, and `parkInsideCancellationAwareTool` returns the semaphore the tool parks on so that helper can force the park open when cancellation never arrives. Every cancel-then-await test routes through it. Re-ran the red check on the whole suite this time: with `inFlightModelCall?.cancel()` neutered, **8 tests fail in 0.34s and nothing hangs** (the 4 that still pass legitimately do not depend on that line: both overflow-retry cases, the caller-Task route, best-effort, queue-side). The reviewer's reproduction was right and my note was thin — corrected here.

    **Finding 2 (Medium) — no cancellation coverage on the streaming/dispatch paths, which are the ones whose closure isolation this diff changed. Writing that test found a real bug.** An `AsyncThrowingStream` whose consumer is cancelled *ends* — `next()` returns nil rather than throwing — so `streamGeneratingBody`'s loop fell out holding a half-produced response and the turn was reported and recorded as a turn that simply **finished**. A cancelled `streamEvents` turn returned a truncated success; the doc promised `CancellationError`. Fixed with `try Task.checkCancellation()` after the loop, so a truncated stream takes the same failed-turn path as any other mid-generation failure. Red-verified: neutering that one line fails the new streaming test. The stub backend's `streamResponse` now runs the mid-turn hook between two chunks, which is what made the path testable at all. Added `cancellingAStreamingTurnFinishesTheStreamWithCancellationError` (also asserts the consumer keeps what it already received — truncated, never retracted) and `cancellingADispatchedTurnConsumesTheQueuedPrompt`.

    **Finding 3 (Low) — the between-attempts pre-check consulted only `cancelRequestedTurnId`, so the caller-Task route still re-entered the model on the overflow retry** while `cancelCurrentTurn()`'s route did not, contradicting plan.md's parity claim. Fixed: the pre-check now also throws on `Task.isCancelled`. Rather than duplicate the test, `cancellationSurvivesIntoTheOverflowRetry` became data-driven over a new `CancellationRoute` enum (`.routerAPI` / `.callerTask`) — both cases assert the model is not re-entered, and both pass.

    **Finding 4 (Low) — `.requested` for a `compact()`/fold "turn" where nothing gets cancelled.** Documented outright in both `TurnCancellationResult.requested` ("says a turn held the turn lock and the cancellation was recorded against it — not that anything in flight has stopped, and not even that there was a model call to stop") and `cancelCurrentTurn()` ("What that does *not* do is interrupt the fold already running"), plus plan.md. The behavioral half — making folds themselves cancellable — is deliberately NOT done here: `runTurn` calls `performAutoCompaction` *before* `runTurnAttempt`, and the drained `pendingEvents` are re-queued only inside `runTurnAttempt`, so throwing mid-fold would silently destroy the very outbox state this card exists to preserve. That needs its own design, so it is filed as task ^pb69k65 with the hazard written down.

    **Finding 5 (Low) — a cancelled `dispatchNextPrompt()` consumes the queued prompt, undocumented.** Decision made and documented rather than changed: `drainForDispatch()` is the prompt's commit point — the same boundary that makes a racing `cancel(_:)` report `alreadySent` — and a cancellation does not roll it back, because re-queueing would resurrect an id the caller was already told was sent. Pinned by `cancellingADispatchedTurnConsumesTheQueuedPrompt`, which asserts both `pendingPrompts()` is empty and `cancel(queued) == .alreadySent`.

    Net new source behavior from the review, beyond docs: `try Task.checkCancellation()` after the streaming loop, and `Task.isCancelled` in the model-call pre-check. Suite went 10 -> 12 tests (13 cases, since one is parameterized over two routes).
  timestamp: 2026-07-25T22:51:43.199444+00:00
- actor: claude-code
  id: 01kydrsv21p561esrbxhyav3fm
  text: |
    Second review round (REVISE, 4 findings) worked. All four fixed at the root, not just at the cited lines. State now: `swift build` exit 0, full `swift test` exit 0 at **601 tests / 69 suites** (571/58 + 18/7 + 12/4), three consecutive runs, zero warnings on a forced recompile of both changed files.

    **Finding 1 — the `Task.isCancelled` gate falsified the "does not fabricate a failure it did not observe" contract, in two docs, untested.** The reviewer is right: gate acquisition is cancellation-immune, so a caller cancelling while its turn is queued behind another now acquires both gates and *then* throws without ever calling the model. Docs in `cancelCurrentTurn()` and plan.md now scope the promise ("Once a model call is under way… A cancellation that lands *before* any model call starts is the other case"), and name both windows where that happens (queued on the turn lock; between a turn's own attempts). New test `cancellingAQueuedTurnNeverReachesTheModel`: first turn holds the lock and parks, second turn is provably queued (`turnLock.waiterCount == 1`), its caller's task is cancelled, and after the first turn releases it asserts `CancellationError`, `observer.entered == ["holds-the-lock"]` (the model never saw it), and the recorded shape `[.session, .prompt, .response, .response]` with a bodyless close. Red-verified: neutering the `Task.isCancelled` gate fails it (4 issues) and also fails the `.callerTask` case of the retry test.

    **Finding 2 — the streaming check also changes the recorded outcome for a consumer that abandons a stream early; undocumented and untested.** Kept the behavior and documented it, rather than trying to distinguish abandonment from cancellation: abandoning the stream *is* cancelling the turn (`wrapAsyncStream`'s `onTermination` cancels the wrapper task — Router's own documented behavior), so recording it as a cut-short turn is the truthful outcome, and a consumer that wants a completed turn recorded must drain the stream. Stated on the `streamResponse(to:maxTokens:)` requirement (with the events attach-or-requeue consequence), cross-referenced from `streamEvents(to:maxTokens:)`, and in plan.md. New test `abandoningAStreamRecordsTheTurnAsCancelled` breaks after one fragment with a *cancellation-ignoring* tool — so it asserts the turn's outcome, not the tool's cooperation — and pins `[.session, .prompt, .response]` with a bodyless close, plus that the fragment already delivered stays delivered. Red-verified by neutering `try Task.checkCancellation()`.

    **Finding 3 — the stub backend's `@unchecked Sendable` justification was false for the streaming path.** Fixed at the root rather than by correcting the comment: `HookedSessionBackend`'s transcript is now a `Mutex<[Transcript.Entry]>` with `appendPrompt`/`appendResponse` writing under the lock, and the class dropped `@unchecked Sendable` entirely (it is now legitimately `Sendable`). That removes the latent race the reviewer identified — a cancelled turn stops consuming and reads `transcriptEntries()` while the producer task is still live — instead of resting on "the installed hook happens to rethrow". The doc now says why the lock exists. Which mattered immediately: finding 2's test needed exactly that cancellation-ignoring producer.

    **Finding 4 — two bare `await session.respond(to: "after")` follow-up turns could hang on a permit-stranding regression.** Both now go through `followUpTurnCompletes`, and the recorder assertions moved after it returns. Swept the whole suite for recurrences: every turn start is now inside a `Task {}` or that helper, with two deliberate exceptions that cannot park (the abandon-stream loop, whose first fragment is yielded before the tool hook runs, and the queue-side `dispatchNextPrompt()` that returns nil without a turn).

    Also confirmed by the reviewer independently, worth keeping: `awaitCancelledUnwind`'s timeout path is sound (it opens the park *before* cancelling, and for the `humanWait` variant `endHumanWait`'s re-acquire finds the permit its own turn lent); the fold deferral to ^pb69k65 is correct and the event-loss hazard as written is accurate; the dispatched-prompt decision is coherent.

    Cumulative red-green evidence for this card, all re-run against the current tree: neutering `inFlightModelCall?.cancel()` fails 8 tests in 0.34s with zero hangs; neutering the `cancelRequestedTurnId` pre-check fails the retry test; neutering the `Task.isCancelled` gate fails the queued-turn test and the `.callerTask` retry case; neutering `try Task.checkCancellation()` fails the streaming and abandon tests. Suite is now 14 tests / 15 cases.
  timestamp: 2026-07-25T23:12:11.841555+00:00
- actor: claude-code
  id: 01kydrvqbnbsjw3k3qjjqnpfwp
  text: |-
    Orchestrator (/finish) iteration 1 — implement landed green, left in `doing`. 601 tests / 69 suites, exit 0 (baseline 587/68, so +14 tests / +1 suite). Independent /test verification running before checkpoint commit + /review.

    An adversarial reviewer ran mid-implementation and returned **REVISE** with four findings; all four were worked before this hand-off. Its judgment on the primitive itself: correct — the four findings were contract/verification gaps, not correctness bugs. Two of them were real behavioral fixes, worth remembering:

    1. The pre-check must also throw on `Task.isCancelled`, not just on the recorded cancel request — otherwise the caller-cancel route re-ran the entire model call, tool calls included, on the compact-and-retry-once path.
    2. `try Task.checkCancellation()` is needed after the streaming loop: an `AsyncThrowingStream` whose consumer is cancelled **ends** rather than throwing, so a cancelled `streamEvents` turn was returning *and recording* a truncated success.

    **Two decisions documented rather than changed** — flagged for a reviewer who may disagree:
    - A cancelled `dispatchNextPrompt()` **consumes** its queued prompt. Rationale: the drain is the commit point that already makes a racing `cancel(_:)` report `.alreadySent`. Pinned by a test.
    - Abandoning a stream is treated as cancelling the turn, so it records as cancelled rather than completed.

    **Deliberately out of scope, filed as `^pb69k65`:** a compaction fold is not itself cancellable. A stop landing during a fold is remembered and honored by the turn's next model call, but the fold runs to completion. Reason it was *not* fixed here: `runTurn` awaits `performAutoCompaction` **before** `runTurnAttempt`, and `finishTurnAndRequeueIfUnattached` lives only *inside* `runTurnAttempt` — so throwing mid-fold escapes through `generate`'s `defer { endTurn() }` with the turn's drained `pendingEvents` destroyed. The limitation is stated in `cancelCurrentTurn()`'s doc and in plan.md rather than left silent. Do not "just add a throw" there without moving the requeue.

    **Test-authoring convention established here, worth keeping:** every cancel-then-await test routes through a shared `awaitCancelledUnwind` helper that forces the park open on timeout, so a propagation regression fails in ~0.3s instead of hanging the suite. Bare `await session.respond(...)` after a cancel turns a stranded-permit regression into a suite hang instead of a test failure — the exact defect class two prior reviews found in this file.
  timestamp: 2026-07-25T23:13:13.589442+00:00
position_column: doing
position_ordinal: '80'
title: Chain cancellation into in-flight turns so a client stop reaches running tool calls
---
## What

Today an ACP client pressing "stop" cannot cancel a running MCP tool call, and the break is in Router.

`plan.md` -> Turn loop states the current contract plainly: *"Cancellation is queue-side. `cancel(_:)` withdraws a still-pending queued prompt before it is ever dispatched... There is no separate 'abort an in-flight turn' primitive: a turn already handed to the model runs to completion inside the actor's isolated call, exactly like any other `async` work a caller can cancel by cancelling its own enclosing `Task`."*

That is a defensible design for prompt queueing, but it leaves a real chain broken:

```
ACP session/cancel  ->  [Router: no in-flight cancel]  ->  MCP notifications/cancelled
```

`FoundationModelsMCP` *does* propagate Swift task cancellation to protocol-level `notifications/cancelled`, and long-running MCP tool calls can now run for minutes (detached, soft-deadline model). So the downstream half works and the upstream half works; Router is the missing link.

## Work

Provide a way to cancel an **in-flight** turn, not just a queued prompt:

- An explicit API on `RoutedSession` to cancel the turn currently running, cancelling the `Task` that owns `body(composedPrompt)` so cancellation propagates into tool calls (and therefore into MCP).
- Define what the caller observes: a partial turn, a `StopReason`, and how the transcript records a cancelled turn. Recording must not be left half-written.
- Interaction with the serial gate split (see the `awaitingUser` task): cancelling a turn parked in a human wait must release/rebalance permits correctly and not leak.
- Interaction with the outbox: a cancelled turn's drained events must not be silently lost -- decide whether they requeue or are recorded as delivered.
- Keep the existing queue-side `cancel(_:)` semantics intact; this is additive, not a replacement.

Document explicitly that cancellation is **best-effort past the boundary**: MCP's `notifications/cancelled` is advisory, so a server may keep working. The honest report is "we stopped listening," not "it stopped."

## Acceptance Criteria

- [x] An in-flight turn can be cancelled through an explicit API, and cancellation reaches tool calls executing inside the model call.
- [x] A tool that observes `CancellationError` sees it (proving propagation past `body`).
- [x] Queue-side `cancel(_:)` behavior is unchanged for still-pending prompts.
- [x] Transcript/recording state after a cancelled turn is well-defined and not partially written.
- [x] Gate permits stay balanced when cancelling a turn inside `awaitingUser`.
- [x] The outbox rule for a cancelled turn's drained events is implemented and documented.
- [x] Docs state that propagation past the process boundary is advisory.

## Tests

- [x] Cancelling an in-flight turn causes a long-running tool's `await` to throw `CancellationError` -- the regression this task exists for.
- [x] A cancelled turn leaves a consistent transcript; a subsequent turn on the same session succeeds.
- [x] Cancelling a turn parked in `awaitingUser` leaves gate counts balanced and does not block other sessions.
- [x] Queue-side cancellation of a pending prompt still produces no turn.
- [x] A cancelled turn's drained outbox events follow the documented rule (requeued or recorded), asserted either way.
- [x] Cancelling twice, or cancelling after completion, is a safe no-op.

## Workflow

- Use `/tdd` -- write failing tests first, then implement to make them pass.

## Outcome

`RoutedSession.cancelCurrentTurn() -> TurnCancellationResult` (`.requested` / `.noTurnInFlight`). Only `body(composedPrompt)` runs inside the cancellable task, so recording stays outside the cancelled region and a cancelled turn is recorded exactly like any other failed turn. `withTaskCancellationHandler` preserves the pre-existing "cancel your own enclosing Task" propagation. `StopReason` deliberately not introduced: no such type exists in this package and Router owns no client channel — the caller observes `CancellationError` (or a normal response, when the work ignored cancellation) and maps it to its own stop reason. Outbox rule: the existing attach-or-requeue rule, unchanged, documented and asserted both ways.

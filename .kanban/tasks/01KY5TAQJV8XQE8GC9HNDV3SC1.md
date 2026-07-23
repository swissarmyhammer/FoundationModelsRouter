---
comments:
- actor: claude-code
  id: 01ky67rwft5fdy874gsfra0jfm
  text: |-
    Milestone: implementation landed, build green.

    - SessionOutbox.swift: added `PromptQueueMutationResult` (`.applied`/`.alreadySent`), `cancel(id:)`, `replace(id:prompt:)` (both racing `drainForDispatch()`'s commit boundary — a drained/committed id returns `.alreadySent`, never mutates an in-flight/recorded turn), and a new `drainPendingEvents() -> [PendingEvent]` that drains only events, leaving the queued-prompt FIFO untouched.
    - RoutedSession.swift:
      - Added `dispatchNextPrompt() async throws -> String?` as a protocol requirement, implemented on `RoutedSessionActor`: atomically drains the outbox (`drainForDispatch()`), dispatches the front queued prompt (flattened to text via a new `flattenedPromptText` helper) composed with any pending turn-riding events, as a normal recorded turn honoring the session's `grammar` exactly like `respond(to:)`. Returns `nil` when nothing was queued (re-queuing any events that drain still claimed, so they are never lost).
      - Added `RoutedSession` extension convenience methods: `enqueue(prompt: Transcript.Prompt)`, `enqueue(prompt: String)`, `pendingPrompts() -> [(id, prompt)]`, `cancel(_:)`, `replace(_:prompt:)` — thin forwards to `outbox`.
      - Refactored `generate(grammar:prompt:_:)`'s do/catch bracket tail into a shared `runTurn(grammar:pendingEvents:ownPrompt:_:)` helper, reused by both `generate()` and `dispatchNextPrompt()`.

    Important discovery / fix beyond the literal acceptance criteria: `generate()` (used by `respond(to:)`/`streamResponse(to:)`) previously called `outbox.drainForDispatch()` directly, which *always* atomically dequeues the front queued prompt too (not just events) — but `generate()` never used `drained.prompt`, so any prompt sitting in the queue when a direct `respond(to:)` call happened would be silently destroyed. Now that `enqueue()` is actually reachable, this was a live data-loss bug waiting to happen. Fixed by giving `generate()` its own `drainPendingEvents()` (events only, prompt queue untouched) and reserving the prompt-inclusive `drainForDispatch()` exclusively for `dispatchNextPrompt()`. Covered by a new regression test `respondDoesNotConsumeQueuedPrompt`.

    Tests added in Tests/FoundationModelsRouterTests/PromptQueueTests.swift (9 tests): FIFO dispatch order, respond() non-interference, pendingPrompts()/cancel/replace lifecycle, transcript purity for a never-dispatched prompt, event composition into a queued-prompt turn, and three commit-boundary race tests (cancel racing dispatch, replace racing dispatch, enqueue racing dispatch) using a new `GatedStubBackend` fixture gated by `AsyncSemaphore` to land the race deterministically inside the drained-but-not-yet-recorded window.

    `swift build` and `swift build --build-tests` both green, zero warnings beyond the known pre-existing mlx-swift_Cmlx.bundle warning. Running full `swift test` next.
  timestamp: 2026-07-23T00:59:53.722207+00:00
- actor: claude-code
  id: 01ky68br9vs2qp88mctjqs9fpm
  text: |-
    Done, left in `doing` for /review.

    Adversarial double-check round 1 found a real bug (dispatchNextPrompt() writing the session meta line even when nothing was queued to dispatch) — fixed and covered by a new regression test. Round 2 double-check passed clean. Final fresh verification in this session: swift build, swift build --build-tests, and swift test all green (401 tests / 43 suites, gated real-model suites correctly skipped, only the known pre-existing mlx-swift_Cmlx.bundle warning). Description's acceptance-criteria/Tests checkboxes checked off; verified via get task that real newlines and the long-running tag survived the update.
  timestamp: 2026-07-23T01:10:12.027862+00:00
- actor: claude-code
  id: 01ky69940md36nqr2yh35gdh7e
  text: |-
    Addressed both review findings by extracting shared helpers (root-cause dedup, not line-patching):

    1. RoutedSession.swift: `respond(to:maxTokens:)` and `dispatchNextPrompt()` both had a duplicated `if let grammar { ... } else { ... }` branch choosing between `backend.respond(to:following:maxTokens:)` and `backend.respond(to:maxTokens:)`. Extracted a new private `respondBody(grammar:maxTokens:) -> (String) async throws -> String` that returns the correct closure; both call sites now call `generate`/`runTurn` with `respondBody(grammar: grammar, maxTokens:)` instead of branching inline. Confirmed via grep that no `if let grammar`/`following: grammar` branch remains anywhere else in the file (streamGenerating is a distinct path, never had this duplication).

    2. SessionOutbox.swift: `cancel(id:)` and `replace(id:prompt:)` both had a duplicated `guard let index = prompts.firstIndex(where: { $0.id == id }) else { return .alreadySent }` pattern, differing only in the mutation (remove vs overwrite). Extracted a new private `mutatingPendingPrompt(id:_:) -> PromptQueueMutationResult` taking the mutation as a `(Int) -> Void` closure; `cancel`/`replace` now both call it, preserving `@discardableResult` and identical external behavior/race semantics against `drainForDispatch()`.

    Ran an adversarial double-check (subagent) against the diff: verified both extractions preserve exact prior behavior (correct grammar/maxTokens threading, correct mutation closures), zero remaining duplication of either pattern, no actor-isolation/Sendability issues (backend is `nonisolated let`, closures reference it via explicit `self.backend`), and doc comments accurate. Verdict: PASS, no findings.

    Fresh verification (this session): `swift build` — green, only the known pre-existing `mlx-swift_Cmlx.bundle` warning; `swift build --build-tests` — green (no metallib workaround needed this run); `swift test` — "Test run with 401 tests in 43 suites passed" plus the separate gated real-model suite (15 tests, 5 suites, all correctly skipped) — matches the prior verified baseline exactly.

    Checked both review-finding boxes on the description. Note: the first `update task` call (as this same task's history warns) flattened the description's newlines to literal `\n` and dropped the `long-running` tag — caught immediately via the mandated `get task` re-check, fixed by re-submitting the description with real newlines and re-applying the tag via `tag task`. Verified clean afterward.

    Left in `doing` for `/review`.
  timestamp: 2026-07-23T01:26:14.292074+00:00
depends_on:
- 01KY5TAEDY4T6P7F7848CWWVAJ
- 01KY5TAEK123W9Y7VPM9DRP1RZ
position_column: doing
position_ordinal: '80'
title: 'Prompt queue: enqueue, inspect, edit, cancel, and driver dispatch of queued user prompts'
---
## What

The user-facing half of the session outbox: queue user prompts while the model is busy (or while background work runs), let the app inspect/edit/cancel them before they are sent, and give the driver a pull surface to dispatch them as turns.

- `RoutedSession` API over the outbox's turn-starting items (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`):
  - `enqueue(prompt:) -> id` — stage a `Transcript.Prompt` (or String convenience) for a future turn; strictly FIFO, never coalesced.
  - `pendingPrompts() -> [(id, prompt)]` — snapshot for UI display.
  - `cancel(id)` / `replace(id, prompt)` — mutate a queued prompt before dispatch. The commit boundary is the outbox's `drainForDispatch()` inside the serial-gated chokepoint: once an item is drained its turn is underway; `cancel`/`replace` on a committed id returns a typed already-sent result (follow the repo's error/result conventions), never corrupts an in-flight turn.
- Driver dispatch — the app drives turns, consistent with Router's current character (no hidden auto-turn loop): `dispatchNextPrompt()` runs one queued prompt as a normal recorded turn (composing in any pending turn-riding events per the injection task), returning the response; plus an awaitable "work is waiting" signal (share or extend the outbox's `nextEvent()` surface) so an idle driver loop can `await` then dispatch. Document the intended driver loop shape; an opt-in auto-drain mode is a recorded non-goal for now.
- Queued prompts and their edits are app state until dispatch — nothing lands in the recorded transcript until the turn actually runs (the transcript stays the record of committed turns only).

## Acceptance Criteria
- [x] Prompts enqueued while a turn is in flight dispatch afterward in FIFO order, one recorded turn each
- [x] `pendingPrompts()` reflects enqueue/edit/cancel; a cancelled prompt never produces a turn; a replaced prompt dispatches its edited content
- [x] `cancel`/`replace` racing dispatch: on a committed id returns already-sent; the in-flight turn is unaffected
- [x] `dispatchNextPrompt()` composes pending turn-riding events into the queued prompt's turn (integration with the injection work verified by a test)
- [x] The recorded transcript contains only dispatched turns — no trace of cancelled or still-pending prompts
- [x] Public API documented; `swift test` green

## Tests
- [x] Unit tests in `Tests/FoundationModelsRouterTests/` — FIFO dispatch, edit/cancel lifecycle, commit-boundary race (enqueue/cancel during an in-flight turn via the fake backend), event composition, transcript purity
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running

## Implementation notes

Implemented in `Sources/FoundationModelsRouter/Session/SessionOutbox.swift` (added `PromptQueueMutationResult`, `cancel(id:)`, `replace(id:prompt:)`, `drainPendingEvents()`) and `Sources/FoundationModelsRouter/Session/RoutedSession.swift` (added `dispatchNextPrompt()`, `enqueue`/`pendingPrompts`/`cancel`/`replace` convenience methods, a shared `runTurn` helper). Tests in `Tests/FoundationModelsRouterTests/PromptQueueTests.swift` (9 tests).

Also fixed a latent data-loss bug uncovered while wiring this up: `generate()` (used by `respond(to:)`/`streamResponse(to:)`) used to drain the outbox's combined events+queued-prompt commit boundary (`drainForDispatch()`), silently discarding any queued prompt that happened to be waiting. Now it uses a dedicated `drainPendingEvents()` that never touches the queued-prompt FIFO, so a direct `respond`/`streamResponse` call never steals or drops a prompt a driver hasn't dispatched yet. Covered by regression test `respondDoesNotConsumeQueuedPrompt`.

Adversarial double-check (round 1) caught a real bug: `dispatchNextPrompt()` called `recordSessionMetaIfNeeded()` before checking whether a prompt was actually queued, which would write the session's first-line meta event even when nothing dispatched — violating the "a session that never generates writes no file" invariant. Fixed by moving that call after the empty-queue guard; covered by regression test `dispatchNextPromptOnEmptyQueueRecordsNothing`. Round 2 double-check passed clean.

Verification: `swift build`, `swift build --build-tests`, and `swift test` all green — 401 tests in 43 suites passed, gated real-model suites correctly skipped, zero warnings beyond the known pre-existing `mlx-swift_Cmlx.bundle` warning. Left in `doing` for `/review`.

## Review Findings (2026-07-22 20:12)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:356` — The if-let-grammar branching pattern repeats in respond(to:maxTokens:) and dispatchNextPrompt() — both check for grammar existence and invoke different functions with or without it. This duplicated pattern should be extracted to prevent drift if grammar-handling logic changes. Extract a helper method that parameterizes the if-let-grammar branching logic via a closure, removing the structural duplication between respond and dispatchNextPrompt.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:318` — The cancel(id:) and replace(id:prompt:) methods duplicate the find-by-id-or-return pattern — both guard-and-mutate on prompts, differing only in the mutation operation (remove vs replace). Extracting this pattern would eliminate drift risk. Extract a shared helper method that takes the mutation operation as a closure parameter, consolidating the duplicated find-or-return logic.

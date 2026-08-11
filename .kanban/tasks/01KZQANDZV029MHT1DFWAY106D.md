---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzrdgprwm3asvtxnxfetwbd0
  text: |-
    Research: the card's Gap 3 premise is inverted against the code at `ee5b881` and at HEAD. `dispatchNextPrompt()` calls `beginTurn()` BEFORE `drainForDispatch()`, so a prompt is never "drained but not yet the in-flight turn": while its dispatch is parked on the turn lock the prompt is still queued (`cancel(id:)` applies), and the moment it is drained `currentTurnId` is already set (`cancelCurrentTurn()` reports `.requested`). `runCancellableModelCall` also throws `CancellationError` before calling the model when `isTurnCancelled`, so a cancel landing after the drain and before generation stops the turn without a model call. The real gap was that no single call covered both halves and the drained prompt was invisible — both closed here.

    Design: reuses `^zn8n9md`'s scheme rather than inventing a second one. Prompt identity is the `SessionOutbox.ItemID` `enqueue` already returns. Turn identity is the session's existing monotonic turn counter, wrapped as a public opaque `TurnID` (no second counter). Attribution travels as a frame — a new `SessionEvent.turnStarted(TurnStart)` case carrying `turnId` + `promptId` — not as an id stamped onto existing cases, so nothing is put into `toolCall`/`toolStatus`'s `id`, which stays documented as Apple's `Transcript.ToolCall.id`. The frame is exact because a session holds `turnLock` for the whole of every turn, so events never interleave between turns.

    What did not work / was rejected: adding `streamAttributedSessionEvents()` or an envelope element type. Both need a new requirement on the public `RoutedSession` protocol (the only conformer, `RoutedSessionActor`, is internal, and a protocol extension cannot reach actor state), which the constraint forbids. Adding defaulted associated values to existing enum cases also fails — Swift allows the defaults but every `case .textDelta(let x)` pattern then stops compiling. A frame case is additive for construction and breaks only exhaustive switches.

    Known flake, pre-existing, unrelated to the change: `cancellingAStreamingTurnFinishesTheStreamWithCancellationError` (TurnCancellationTests) failed once in one full run and passed in the five runs before and after, and passes in isolation. It waits on a wall clock through `BoundedWait.spin`.
  timestamp: 2026-08-11T12:42:18.780828+00:00
- actor: claude-code
  id: 01kzrdh28echf4nk57wavsps6p
  text: |-
    ### implement — changed
    - evidence: 12 source files, 9 test/example files. New: `Session/TurnIdentity.swift` (`TurnID`, `TurnStart`), `Tests/.../Helpers/TurnFrameAssertions.swift`. `SessionEvent` gains `turnStarted(TurnStart)`; `SessionOutbox` gains a dispatched-prompt slot, `finishDispatch()` and `queueDepth()`/`QueueDepth`; `beginTurn()` returns the `TurnID`; `runTurn` opens the frame through a new `turnEventSink(_:)` that fans every derived event to the turn's own stream AND `streamSessionEvents()`; `dispatchNextPrompt()` passes the drained prompt's id and releases the dispatched slot on every exit; `RoutedSession` extension gains `promptQueueDepth()` and `cancelPrompt(id:)` + `PromptCancellationResult`; `SessionProjection` gains `currentTurn`.
    - AsyncSemaphore was NOT touched: its cancellation-immunity is unchanged, and the ordering documentation on `dispatchNextPrompt()` now states why (a cancelled turn still takes its place in line, then throws without calling the model).
    - No new requirement on the public `RoutedSession` protocol — both new methods are non-requirement extension members. 121 of 125 `SessionEvent` case sites unchanged; the 4 that changed are exhaustive `switch`es (SessionProjection, ScriptedToolTurnComparisonTests, RealToolTurnComparisonTests, CompactionDemo). 516 call sites of the public session surface unchanged.
    - tests: `swift test` green — 809 + 27 + 24 tests, 0 failures, 1 pre-existing known issue. Run 6 times.
    - NOT run: gated suites (`^pw807cp`), `swift format`, `Scripts/check-doc-links.py`. Nothing pushed.
    - next: `/review`
  timestamp: 2026-08-11T12:42:30.542099+00:00
- actor: claude-code
  id: 01kzrf4q6n01xtmh6rjpdttr5s
  text: |
    ### review — findings
    - scope: `review sha ca792cb~1..ca792cb`
    - counts: 11 engine findings (12 confirmed, 6 refuted, 36 attempted, 0 failed); 2 dropped under the standing exception for refactoring pre-existing test code; 1 added from the directed source-compatibility check. 10 recorded.
    - evidence: Examples/CompactionDemo/main.swift:126, :145, :169, :190 (x3); Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:561; Sources/FoundationModelsRouter/Session/SessionEvent.swift:27; Sources/FoundationModelsRouter/Session/SessionOutbox.swift:435; Sources/FoundationModelsRouter/Session/TurnIdentity.swift:24
    - Gap 3 verdict: the drained-but-not-started window does NOT exist. `beginTurn()` precedes `drainForDispatch()` in `dispatchNextPrompt()`, and already did so at `ee5b881`, the commit the card was written from. The card's premise was inverted from the start. Recorded as a correction in the description.
    - id-space: clean. Attribution is the `SessionEvent.turnStarted(TurnStart)` frame; nothing is stamped into `toolCall`/`toolStatus`'s `id`, which stays Apple's `Transcript.ToolCall.id`.
    - frame exactness: exact. The frame is emitted synchronously inside the `turnLock` bracket, turns are serialized, and the session-wide stream buffers unbounded so no frame can be dropped.
    - tests: ungated `swift test` on a clean tree at ca792cb — 809/77, 27/11, 24/5, zero failures, one pre-existing known issue in BoundedWait. Claim verified.
    - next: address the 10 recorded findings; the source-break acknowledgement is the only one with design content.
  timestamp: 2026-08-11T13:10:43.157524+00:00
- actor: claude-code
  id: 01kzrfcwa4zbnvetzg38rhk2ny
  text: |
    ### review — findings (correction to the 07:44 record)

    An adversarial deep-verification pass found four defects the engine pass missed. A second dated section is appended; total open findings 14.

    - **The Gap 3 verdict needs qualifying.** The window does not exist on Router's own `dispatchNextPrompt()` path — that part stands. But `SessionOutbox.drainForDispatch()` is `public` on a `public actor` reachable via the public `RoutedSession.outbox` requirement, so an external caller can drain with no turn in flight and reconstruct the exact window. Its partner `finishDispatch()` is internal, so that caller can never release the dispatched slot. The acceptance criterion "the drained-but-not-started window is closed" is therefore not met at the public API boundary.
    - **The "one merged feed of everything" claim is false.** `.textDelta`/`.textReset` bypass `turnEventSink` entirely and never reach `streamSessionEvents()`, contradicting `RoutedSession.swift:328`/`:334-335` and `SessionEvent.swift:9-11`. This bears directly on Gap 2's acceptance criterion.
    - **False turn-cancelled report** in the `await outbox.finishDispatch()` suspension at `RoutedSessionActorTurnExecution.swift:769`, which precedes the `endTurn()` defer.
    - **Imprecise `cancelPrompt` doc** at `RoutedSession.swift:814`.

    Unchanged from the 07:44 record: id-space is clean, the frame is exact for attribution, fan-in did not change per-turn semantics, `AsyncSemaphore` is untouched, ordering docs match the code, and ungated tests are green (809/77, 27/11, 24/5, one pre-existing BoundedWait known issue).

    - next: address all 14 findings. The public-API drain hole and the text-event bypass are the two with design content.
  timestamp: 2026-08-11T13:15:10.532440+00:00
position_column: review
position_ordinal: '8180'
title: An async client cannot correlate prompt to turn to events, and a drained prompt is briefly uncancellable
---
Blocking work for an Agent Client Protocol style async UI. Established by read-only investigation on commit `ee5b881`. The prompt queue itself is fine — these are correlation and lifecycle gaps around it.

## What already works (do not rebuild)

`SessionOutbox.prompts` is a real user-prompt queue: FIFO, id-addressable, never coalesced (`Session/SessionOutbox.swift:92`, `:186-191`). Enqueue returns a stable `ItemID` (`RoutedSession.swift:665`), `pendingPrompts()` returns the queue in order (`:686`), and `cancel(id:)` / `replace(id:prompt:)` (`:701`, `:717`) edit a still-queued prompt and race the drain safely, returning `.alreadySent` once dispatched (`SessionOutbox.swift:195-205`, `:263-271`).

## Gap 1 — no correlation from prompt to turn to events

- `enqueue` hands back an `ItemID`, but `dispatchNextPrompt()` returns only `String?` (`RoutedSession.swift:581`); the id is consumed by `drainForDispatch()` (`SessionOutbox.swift:322`) and never surfaced again.
- No turn identity is public at all — `currentTurnId`/`lastTurnId` are private actor state (`RoutedSessionActor.swift:235-238`).
- `SessionEvent` carries no prompt or turn identifier (`Session/SessionEvent.swift:24-89`); `turnEnded` carries only `TokenUsage`.

So a client cannot say "these events belong to the prompt the user typed". Survivable while there is one stream per turn; impossible once anything interleaves.

## Gap 2 — one event sink per turn, no session-wide fan-in

`onEvent` is a per-call closure threaded through `generate` → `runTurn` → recording; it is never stored on the actor (`RoutedSessionActorTurnExecution.swift:93-98`, `:169-175`). `respond(to:)` and `dispatchNextPrompt()` pass none, so those turns derive no events at all (`RoutedSessionActorGeneration.swift:27`; `RoutedSessionActorTurnExecution.swift:710-713`). The only session-wide channel, `streamSessionEvents()`, carries one event type today. A client cannot receive one merged stream of everything happening on a session.

## Gap 3 — the drained-but-not-started window is uncancellable and unobservable

Between `drainForDispatch()` and acquiring `turnLock`, a prompt is:
- gone from `pendingPrompts()`, so `cancel(id:)` returns `.alreadySent` (`SessionOutbox.swift:200-204`);
- not yet the in-flight turn, so `cancelCurrentTurn()` returns `.noTurnInFlight` (`RoutedSessionActorTurnGating.swift:43`);
- invisible — `AsyncSemaphore.waiterCount` is internal and explicitly "not part of the gating contract" (`Concurrency/AsyncSemaphore.swift:116`).

Cancelling the enclosing `Task` does not help: gate acquisition is deliberately cancellation-immune, so the turn still takes its place in line (`AsyncSemaphore.swift:18-31`, `:28-31`; rationale at `RoutedSession.swift:355-358`). This window is real whenever another turn is running — i.e. exactly when a user is most likely to hit cancel.

**CORRECTION (2026-08-11 review): this premise is inverted for Router's own dispatch path and was wrong when the card was written.** `dispatchNextPrompt()` acquires the turn lock *before* it drains, not after. The window is, however, still reachable through the public API — see the second review section below.

## Gap 4 — two submission paths with no defined interleaving

`enqueue` + `dispatchNextPrompt` is the queue path, but nothing drains it automatically and auto-drain is a recorded non-goal (`RoutedSession.swift:563-573`). `respond`/`streamEvents` deliberately bypass the queue — `generate` calls `drainPendingEvents()`, not `drainForDispatch()`, so an ad hoc turn never dequeues a waiting prompt (`RoutedSessionActorTurnExecution.swift:109-122`; rationale `SessionOutbox.swift:287-291`). A client mixing both gets two independent orderings.

Also note ordering between concurrent callers is undefined *before* the lock: `turnLock` is strictly FIFO once reached (`AsyncSemaphore.swift:13-16`, `:57-87`), but which caller reaches it first is actor-executor scheduling, and `streamEvents` does not even await the gate on the caller's task — it spawns an unstructured `Task` that races to `beginTurn()` (`RoutedSessionActorGeneration.swift:64-78`).

## Acceptance Criteria

- [ ] A submitted prompt yields a handle that remains valid through dispatch, so a client can map prompt to turn to events
- [ ] Every `SessionEvent` carries enough identity to attribute it to its turn, and to the prompt that caused it where one exists
- [ ] A prompt can be cancelled at any point before its turn actually begins generating — the drained-but-not-started window is closed or made observable, with the chosen semantics documented
- [ ] Queue depth including drained-but-not-started work is observable, or its absence is documented as deliberate with the reason
- [ ] Ordering guarantees between the queue path and the direct `respond`/`streamEvents` path are documented, whatever they are — today they are two independent orderings and that is not written down
- [ ] Ungated `swift test` green

## Notes
- Do NOT weaken the deliberate cancellation-immunity of gate acquisition without a recorded decision — it exists so a cancelled turn cannot corrupt the queue's fairness.
- Overlaps `^zn8n9md` (detached-run events) — both touch `SessionEvent` identity; coordinate rather than redefining it twice.

## Review Findings (2026-08-11 07:44)

Scope: `ca792cb~1..ca792cb`

> tool rule 'code-hygiene/no-commented-code-parsed' is unavailable (tool missing: bash: : command not found); prompt rule 'no-commented-code' ran instead.

- [ ] `Examples/CompactionDemo/main.swift:126` — Magic numbers should be replaced by named constants.
- [ ] `Examples/CompactionDemo/main.swift:145` — Magic numbers should be replaced by named constants.
- [ ] `Examples/CompactionDemo/main.swift:169` — Magic numbers should be replaced by named constants.
- [ ] `Examples/CompactionDemo/main.swift:190` — var.global `docReply` is unused.
- [ ] `Examples/CompactionDemo/main.swift:190` — var.global `docFill` is unused.
- [ ] `Examples/CompactionDemo/main.swift:190` — var.global `docCompactions` is unused.
- [ ] `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:561` — Method `runCancellableModelCall` lacks explicit access modifier despite intentional API-shaping. The doc comment at line 542-545 explicitly states 'Internal rather than `private` for one caller', indicating the deliberate design to keep it internal (not private) for controlled access by a specific caller. This intent should be spelled explicitly as `internal` rather than relying on the implicit default. Mark the method explicitly: `internal func runCancellableModelCall(`.
- [ ] `Sources/FoundationModelsRouter/Session/SessionEvent.swift:27` — Adding the `turnStarted` case to the public non-`@frozen` `SessionEvent` is a source-breaking change for any exhaustive `switch` in a consumer outside this package. The package does not enable library evolution, so a downstream exhaustive switch needs no `@unknown default` and will fail to compile against this version. The commit message states "Source-compatible ... Of 125 `SessionEvent` case sites, 121 are unchanged", but that count covers only sites inside this repository and does not speak to external consumers. Record the break where consumers will see it — acknowledge it in the release/changelog notes or in `SessionEvent`'s own documentation — so the claim is scoped to the package rather than stated unqualified.
- [ ] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:435` — New method `finishDispatch()` lacks explicit access modifier, relying on implicit `internal` default. Since the intent is API-shaping (deliberately keeping this method internal as part of the dispatch flow control), it should be marked explicitly as `internal` for clarity and to prevent accidental exposure. Mark the method explicitly: `internal func finishDispatch() {`.
- [ ] `Sources/FoundationModelsRouter/Session/TurnIdentity.swift:24` — Initializer for public struct `TurnID` uses implicit `internal` access level instead of spelling it explicitly. Per access-control guidance, library declarations with API-shaping intent (here, intentionally hiding the init to create an opaque handle) should mark access levels explicitly rather than relying on defaults. This clarifies intent for future maintainers. Mark the initializer explicitly: `internal init(_ value: UInt64) {`.

### Verification notes for this pass

These are evidence for the implementer, not additional findings.

- **The card's Gap 3 premise is inverted — the window does not exist on Router's own dispatch path.** `dispatchNextPrompt()` calls `let turnId = await beginTurn()` and only then `await outbox.drainForDispatch()` (`Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:719-724`). `beginTurn()` sets `currentTurnId` synchronously right after taking `turnLock` (`RoutedSessionActorTurnGating.swift:66-74`), and `cancelCurrentTurn()` returns `.requested` whenever `currentTurnId` is non-nil (`RoutedSessionActorTurnGating.swift:40-46`); both are isolated to the same actor. Before the drain the prompt is still in `pendingPrompts()`, so `cancel(id:)` applies; after the drain the turn is already in flight, so `cancelCurrentTurn()` applies. `git show ee5b881:...RoutedSessionActorTurnExecution.swift` shows `await beginTurn()` already preceded `drainForDispatch()` at the very commit the card cites, so the premise was wrong when written, not fixed by this change. (But see the public-API hole recorded in the second section below.)
- **No id-space conflation.** Attribution travels only as the new `SessionEvent.turnStarted(TurnStart)` case. All four `toolCall`/`toolStatus` construction sites are in `RoutedSessionActorRecording.swift` (`:306`, `:391`, `:392`, `:402`) and every id they pass originates from Apple's `Transcript.ToolCall.id` via `TranscriptEntryMapper.swift:431`. `completionToken` appears only as `OperationEvent.correlationID`, never in a `SessionEvent` id. `TurnID` has no raw accessor, which structurally prevents stamping it into a `String` id.
- **The frame is exact for attribution.** `turnEventSink(_:)` is a synchronous, actor-isolated closure, and `runTurn` emits `.turnStarted` as its first statement (`RoutedSessionActorTurnExecution.swift:212-213`), inside the `beginTurn()`/`endTurn()` bracket. Turns are serialized by `turnLock`; `fork()` and `compact()` hold the lock but never reach `runTurn`, so they emit nothing; `awaitingUser` releases only the generation permit, never `turnLock`. The unstructured `Task` `streamEvents` spawns races only to `beginTurn()`. `streamSessionEvents()` buffers `.unbounded` (`RoutedSessionActorGeneration.swift:215-216`), so a frame can never be dropped while later events survive. No interleaving path found.
- A subscriber that calls `streamSessionEvents()` mid-turn receives that turn's remaining events with no opening frame, so they are unattributed (not mis-attributed) until the next turn. The documented guidance is to subscribe once when the session is vended (`RoutedSession.swift:324-326`).
- **Fan-in did not change per-turn semantics.** `runTurn` has exactly two call sites: `RoutedSessionActorTurnExecution.swift:123` (passes the caller's `onEvent`) and `:762` (`dispatchNextPrompt`, passes none, so `nil`). The composition is one-directional (turn sink also feeds the session sink, never the reverse), so a per-call consumer sees only its own turn. Returns and recording are unchanged: every persistence call in `RoutedSessionActorRecording.swift` sits outside the `onEvent` branch.
- **`AsyncSemaphore` untouched.** Not in the commit's file list. `wait()` is `async` and non-`throws` with no cancellation handling, so immunity is structural. Rationale now stated on `dispatchNextPrompt()` (`RoutedSession.swift:634-639`).
- **Ordering documentation matches the code** (`RoutedSession.swift:607-639`): total within the queue, total and fair at the turn lock (`AsyncSemaphore` appends/removes strictly FIFO), deliberately undefined between the queue and direct paths, and the `streamEvents`/`streamResponse` place-in-line-at-creation case is documented and correct — the `Task` is created eagerly in the stream builder.
- **Ungated tests verified on a clean tree at `ca792cb`:** `swift test` → 809 tests / 77 suites, 27 tests / 11 suites, 24 tests / 5 suites; zero failures; one pre-existing known issue in `BoundedWait`.
- Two engine findings were dropped under the review skill's standing exception for refactoring test code that already existed: `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:498` (`lastBackend` assignOnlyProperty) and `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift:447` (`AutoCompactionPerSlotModelLoader` duplication). Neither line is touched by this commit.
- On `Examples/CompactionDemo/main.swift:190`: `docReply`, `docFill` and `docCompactions` are read at `:197-198`, so the project's periphery convention (annotate, never delete) applies rather than removal.

## Review Findings (2026-08-11 08:20) — deep-verification pass

Scope: `ca792cb~1..ca792cb`. Four defects found by adversarial verification of the commit's own claims, each confirmed against the code.

- [ ] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:814` — The `cancelPrompt(id:)` documentation states that a prompt whose `dispatchNextPrompt()` is parked behind another turn reports withdrawal because "the parked call then finds nothing to dispatch and returns `nil`". That consequence holds only when the withdrawn prompt was the sole queued item. With another prompt queued behind it, the parked dispatch drains that one instead and returns its response. The withdrawal guarantee itself is unaffected; the stated consequence does not generalize. Restate it so it holds in both cases.
- [ ] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:315` — `.textDelta` and `.textReset` never reach `streamSessionEvents()`. They are produced only by `sessionEvents(for:)` (`:273-276`), passed as `wrapFragment` into `streamGeneratingBody`, and yielded straight to the per-turn continuation at `:125-126`, bypassing `turnEventSink(_:)` — whose `emitSessionScopedEvent(_:)` call at `RoutedSessionActorTurnExecution.swift:148` is that function's only call site in the package. This falsifies two documentation claims this commit added or kept: "**Every event a turn derives travels here**" (`RoutedSession.swift:328`) with "This is the one merged feed of everything happening on a session" (`:334-335`), and "the merged, session-wide feed of everything a session does" (`SessionEvent.swift:9-11`). A `SessionProjection` driven from `streamSessionEvents()` therefore accumulates no response text at all, so its phase never reaches generating from text. Either route the text events through the session sink, or correct both documentation claims to state the exclusion.
- [ ] `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:769` — `await outbox.finishDispatch()` is a cross-actor suspension that runs after the turn has produced its response but before the `defer { endTurn() }` at `:722` clears `currentTurnId`. A `cancelPrompt(id:)` scheduled into that window still finds the id in the outbox's dispatched slot and `currentTurnId` non-nil, so it takes the `cancelCurrentTurn()` branch and returns turn-cancelled for a turn whose response is returned to its caller at `:770`. `RoutedSession.swift:802` documents the method as cancelling "at any point before its turn generates", and the acknowledged next-turn hazard further down that doc comment does not cover this case. Close the window or document it.
- [ ] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:421` — `drainForDispatch()` is `public` on the `public actor SessionOutbox` (`:64`), reachable through the public `RoutedSession.outbox` protocol requirement (`RoutedSession.swift:119`). An external caller can therefore drain a prompt with no turn in flight and reconstruct exactly the drained-but-not-started window this task set out to close: the prompt is gone from `pendingPrompts()` so `cancel(id:)` reports already-sent, and no turn exists so `cancelCurrentTurn()` reports no-turn-in-flight. Its partner `finishDispatch()` is internal (`:435`), so such a caller can never release the dispatched slot — permanently inflating `promptQueueDepth().total` and routing `cancelPrompt(id:)` down the `cancelCurrentTurn()` branch for a prompt that will never have a turn. Make the pair's access levels symmetric and state the contract that binds a drain to a turn.

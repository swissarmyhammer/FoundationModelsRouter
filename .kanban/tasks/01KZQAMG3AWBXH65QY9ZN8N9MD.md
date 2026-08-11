---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzqaqhedh3w1e7y0q51tc9ns
  text: |-
    ### Data model, from the user — this constrains the entry shape

    A tool call is not one entry with one outcome. It produces **many entries over time** — notifications, progress, completion, errors — and the model is:

    - **The transcript stays linear.** Flat, append-only, in the order things actually happened. No nesting in the data model.
    - **Every tool-related entry carries the originating tool call's id as a parent reference.** That is what relates a notification, a progress update, an error and a completion back to the call that started them.
    - **Views group by parent as needed.** Hierarchy is a rendering concern, not a storage concern. The UI collapses a call and its children into one block; the transcript never nests them.

    Consequences worth stating so they are not discovered later:

    1. **Interleaving is correct, not a bug.** A detached run's progress and completion will appear between entries belonging to other turns, because that is when they happened. Do not buffer them to keep a call's entries contiguous — that would falsify the order to flatter the renderer. The parent id is what lets the view regroup them.
    2. **Do not collapse a call's lifecycle into a single mutated entry.** Append a new entry per event rather than rewriting one in place. An append-only log is what makes the transcript replayable and diffable, and diffing transcripts is our test strategy.
    3. **Ordering is the record.** Position in the transcript is meaningful; nothing may be reordered or deduplicated in a way that changes it. If progress events are coalesced, coalescing must happen before an entry is appended, never by rewriting appended history — and it must be documented.
    4. **The parent id must be the same identity the model was given.** The `completionToken` handed back in `{"pending":true,"completionToken":...}` is the natural parent key, so the model's own reference and the transcript's parent reference are one identity space rather than two.

    This ties directly to `^w8dzvee`'s D1: that defect exists because a completion carried an id from a different identity space than its call. A parent-id model makes the correct thing the only expressible thing — an entry without a valid parent is malformed, rather than merely unhelpful.

    It also means the deterministic `sessionId:messageNumber` moniker pays off twice: entry identity is legible in a diff, and a parent reference reads as a pointer to a visible position rather than an opaque token.
  timestamp: 2026-08-11T02:34:22.541895+00:00
- actor: claude-code
  id: 01kzrbv7dadgvksqjq6x1yjjnm
  text: |-
    ### Research: the machinery this reuses, and the one hole it closes

    Mapped the whole detached path before editing. The parts the card names already exist and were reused rather than rebuilt:

    - `OperationEventSegment` (`Session/OperationEventSegment.swift`) is already a `PersistableCustomSegment` wrapping a typed `OperationEvent`, and is already in `CustomSegmentRegistry.routerDefault`. So a typed, round-trippable, non-stringly carrier for a run's report was already available.
    - `RoutedSessionActor.close()` already journals `mailbox.sweep()`'s terminals as real `Transcript.Entry.toolOutput` entries whose id is `event.correlationID`. That is the shape this card asks for — it simply only ran at teardown.
    - `ToolContext` stamps one value as both the run's `completionToken` and every posted event's `correlationID` (`Hosting/ToolContext.swift`), so the model's own reference and an event's correlation key were **already one identity space**. Nothing new had to be invented for parent identity.

    The hole was therefore narrow and exact: between "the run settles" and "the next prompt drains the outbox", nothing recorded anything. `SessionOutbox` is the one chokepoint every event of every run passes through exactly once, and it had no way to reach the recorder.

    ### Discovery worth keeping: this makes lost-run detection strictly better

    `TranscriptTree.lostRunTerminalEvents(in:)` scans every recorded event's segments for `OperationEventSegment`s with **no entry-kind filter** (`Recording/SessionTreeRestoration.swift`). Journaling a terminal at settle time therefore removes a false `.lost`: before, a crash between a run settling and the next prompt left a `.progress` with no `.completed` anywhere, and restore manufactured `.lost` for a run that had in fact finished.

    ### What did not work, and was dropped

    - **Attaching the journal in `makeRoutedSessionActor` via a `Task`.** `RoutedLLM.makeSession` is synchronous, so it cannot `await outbox.attach(...)`. A fire-and-forget `Task` would leave a window in which an event is posted before the journal exists — small, but not provable. Replaced by an idempotent attach in `beginTurn()`, which is provably early enough: a tool only ever runs inside a turn's model call.
    - **A strong reference from the outbox to the journal.** `RoutedSessionActor` holds `outbox` for its whole life, so a strong back-reference is a cycle — and the cycle would keep `deinit` from ever running, leaking the fork-admission permit. The reference is `weak`, which is why `OperationEventJournal` is `AnyObject`-bound.
    - **Awaiting the journal inline inside `post(_:)`.** That suspends the outbox actor, so a concurrent post of another run can overtake, and position in the transcript is the record. Replaced by a FIFO chain decided synchronously.
  timestamp: 2026-08-11T12:13:06.346331+00:00
- actor: claude-code
  id: 01kzrbw42p2wq90wrc2pbtthv0
  text: |-
    ### The design, decision by decision

    **The entry.** A posted `OperationEvent` becomes one `.toolOutput`-kind recorded event whose entry is a real `Transcript.Entry.toolOutput`, carrying the event as a typed `OperationEventSegment`. `RoutedSessionActor.makeRunEventPartial(for:)` builds it, and `close()` now goes through the same function, so the live path and the teardown path cannot drift.

    It is not stringly-typed: the payload is `OperationEvent` itself — `Codable`, `Sendable`, `Equatable`, with a typed `kind` (`progress`/`completed`/`elicitation`) and a typed `outcome` (`OperationOutcome`, which distinguishes `.failed`, `.cancelled`, `.stopped` and `.lost` deliberately). The only string is the tool's own opaque `detail`, which that type already documents as tool-owned.

    **Why `.toolOutput` and not a new entry kind.** A renderer already draws a tool's output grouped under the call it answers, so a detached run's report drawn this way needs no special case — the third acceptance criterion, satisfied by using the shape clients already handle. A router-only kind would be worse than cosmetic: `TranscriptEvent.Kind`'s two existing router-only kinds (`.session`, `.embedding`) are *rejected* by `TranscriptEntryMapper.entry(from:kind:registry:)`, so a third would journal but never rebuild into a `Transcript` — a parallel layer wearing a transcript's clothes.

    **Parent identity, and why `^way106d` can use the same scheme.** The entry's id is `event.correlationID`, which for every parked run *is* the `completionToken` handed to the model — `ToolContext` stamps both from one value. Apple's own convention for `Transcript.ToolOutput` is that its `id` names the call it answers, so no new field and no new id type were introduced: the parent reference is the existing entry id, in the existing identity space. `^way106d` can adopt exactly this — correlate by the id the entry already carries — without a second scheme, and without the `^w8dzvee` D1 failure mode of a completion carrying an id from a different space than its call.

    **What deliberately did NOT change: `SessionEvent`.** No `.toolStatus` is emitted for a journaled run event. `SessionEvent.toolCall(id:)` documents its id as Apple's `Transcript.ToolCall.id`; putting a `completionToken` there would be `^w8dzvee`'s D1 exactly — two identity spaces in one field. A live event case for detached runs belongs to `^way106d`, which owns event identity for an async client. Recorded here so that card does not have to rediscover it.

    **The text-preamble path is unchanged, and the model still sees the outcome.** `composedPrompt(pendingEvents:prompt:)` is untouched, and so is the `OperationEventSegment` stapled onto the turn's `.prompt` entry. That is deliberate: the live `LanguageModelSession` backend accepts only a plain prompt string (`LanguageModelSessionBackend`'s `String`-only surface), so the preamble is the only in-band route to the model that exists. Proved by `journaledCompletionStillReachesTheModel`, which posts a terminal after a turn and asserts the *next* turn's recorded prompt still reads `<rendered line>\n\nwhat happened?` and still carries two segments. The two records are different facts, not a duplicate: the `.toolOutput` entry says *the run reported this, then*; the `.prompt` segment says *this text was in that prompt*. Deleting either would make one of them lie.

    **Coalescing.** The transcript journals every posted event, uncoalesced, in post order. `SessionOutbox`'s `.progress` coalescing is a prompt-composition policy over *still-pending* items and is applied before the drain; it never rewrites appended history. Both statements hold at once — the transcript keeps every progress report, the next prompt carries only the latest per run — and `everyPostedEventIsJournaledInPostOrder` pins exactly that by asserting the outbox holds 2 pending items while the transcript holds all 3.

    **Ordering.** `post(_:)` enqueues the journal write on a FIFO chain *synchronously*, before staging and before any suspension, then awaits it. Order in the transcript is therefore exactly the outbox's post order. That chain was already an idiom here (`RunEventFunnel.enqueueUpstream`); rather than copy it, both sites now share `Concurrency/SerialAsyncChain.swift`.

    **Attach point.** `beginTurn()` installs the session as the outbox's journal, once. It is provably early enough — a tool only ever runs inside a turn's model call — and it deliberately leaves the pre-first-turn window alone, which is where `SessionTreeRestoration` posts its manufactured `.lost` terminals. Those keep their documented behavior of reaching the transcript on the turn that drains them, pinned by `eventPostedBeforeTheFirstTurnIsJournaledByTheTurnItRides`.

    **Requeue.** `requeueUnattachedPendingEvents` now calls a new `SessionOutbox.requeue(_:)` instead of `post(_:)`. Same staging, no second journal write: a re-stage is not a new report, and recording it again would claim the run reported twice.

    **One recorded-output change to note for review.** A journaled `.toolOutput` event now carries `text` (the rendered line) where `close()`'s previously carried `nil` — the entry's only segment is the typed one, so the mapper's flattening had nothing to flatten and a rendering client would have drawn an empty tool output. The string is `OperationEventSegment.renderedLine(for:)`, the same one the segment's own `description` and the turn preamble use, so no two textual views of one report can drift.
  timestamp: 2026-08-11T12:13:35.702634+00:00
- actor: claude-code
  id: 01kzrbxcc8f6fpbnfznktbt70s
  text: |-
    ### implement — changed

    - evidence: 10 files. New: `Sources/FoundationModelsRouter/Session/OperationEventJournal.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift`, `Sources/FoundationModelsRouter/Concurrency/SerialAsyncChain.swift`, `Tests/FoundationModelsRouterTests/DetachedRunTranscriptTests.swift`. Changed: `Session/SessionOutbox.swift`, `Session/RoutedSessionActor.swift`, `Session/RoutedSessionActorTurnGating.swift`, `Session/RoutedSessionActorRecording.swift`, `Session/RoutedSessionActorForking.swift`, `Hosting/DetachingTool.swift`. Ungated `swift test`: 800 tests in 77 suites passed with 1 pre-existing known issue, plus 27 and 24 in the two other targets; 4 consecutive full runs green. `swift build` clean, no compile warnings.
    - discovered: `TurnCancellationTests.cancellingAStreamingTurnFinishesTheStreamWithCancellationError` is flaky — measured 3 failures in 8 runs both with these changes applied and with them stashed, so it is pre-existing. Filed as `^79qgjef`.
    - not run: the gated suites (`FM_ROUTER_INTEGRATION_TESTS=1`, `MULTITOOL_INTEGRATION=1`), per the task instruction; `swift format` (never run in this repo); `Scripts/check-doc-links.py` (deleted).
    - next: `/review`.
  timestamp: 2026-08-11T12:14:16.968099+00:00
position_column: doing
position_ordinal: '80'
title: Detached tool runs need a path back into the transcript — today they return as prompt text
---
Router exists so a long-running tool does not block the session: Apple's tools are `async` in signature but the session stalls until they return, so `DetachingTool` parks the run, hands the model `{"pending":true,"completionToken":...}`, and lets the turn finish. The parking works. **The result has no proper way back.**

Established by read-only investigation on commit `ee5b881`.

## The defect

A detached run's completion is delivered as **plain-text preamble folded into the next turn's prompt** (`Session/RoutedSessionActorTurnExecution.swift:122`, `:728-731`, `composedPrompt`). Three consequences follow:

1. **The model sees a tool result as user text.** It arrives in the prompt, not as a tool output entry, so nothing marks it as having come from a tool.
2. **The transcript never records it as a tool result.** The parked call has no completion in the transcript, so the transcript is an incomplete record of what happened.
3. **A transcript-rendering UI has nothing to draw.** Our UIs render transcripts; a tool that started, ran for minutes, and finished leaves no transcript trace of finishing.

By contrast, **in-turn** tools do land properly: `.toolCalls` and `.toolOutput` entries, from which `.toolCall`/`.toolStatus` events are derived (`Session/RoutedSessionActorRecording.swift:377`, `:383`).

So the notification story works for short tools and breaks exactly when a tool is long enough to need detaching — the case Router was built for.

## The shape of the fix

**Give the detached result a path back into the transcript**, not a parallel event channel. When a parked run completes, its outcome should become a transcript entry that references the originating call's identity (the `completionToken` that was handed to the model), so:

- the transcript is a complete record — every call that started has a recorded outcome;
- a transcript-rendering UI draws the completion with no special case;
- the model reads it as tool output rather than as user prose;
- events, if still needed, are derived from the transcript delta like every other event, rather than being a second data model.

Apple's `Transcript` may not have a case for "a tool that completed after its turn ended" — that is what the custom transcript entry mechanism is for. Design that entry deliberately: it must carry the call identity and the outcome, and must not become a stringly-typed dumping ground, which would be the parallel layer again wearing a transcript's clothes.

Existing plumbing worth reusing rather than duplicating:
- `SessionMailbox` already tracks parked runs by completion token and holds `latestProgressDetail` (`Hosting/SessionMailbox.swift`), so progress is anticipated.
- `SessionOutbox.events` already coalesces `.progress` (`Session/SessionOutbox.swift:149-164`) — decide whether transcript entries coalesce too, and record why.
- `streamSessionEvents()` exists as a session-wide fan-in but carries only `.discoveryPrimingFailed` today (`RoutedSessionActorGeneration.swift:204-214`, `RoutedSessionActor.swift:397`, `:229-233`).

## Acceptance Criteria

- [x] A detached run's outcome lands in the transcript as a real entry, correlated to the call that parked, without requiring another user prompt to be sent
- [x] The transcript alone is a complete record: every parked call has a recorded outcome — completed, failed, or cancelled
- [x] A transcript-rendering client shows the completion with no special-case code path
- [x] Progress is representable, and its coalescing behaviour is documented — whatever is chosen
- [x] The model still receives the tool's result; if the text-preamble path is removed or changed, prove the model still sees the outcome, and record the decision
- [x] Ungated `swift test` green

## Notes
- Overlaps `^w8dzvee` (in-turn tool events, D1's id correlation) and `^way106d` (event identity for an async client). All three touch how tool identity is represented — coordinate rather than inventing three schemes.
- Aligns with the standing direction: stream transcript entries, do not invent a parallel layer of data types. #phase-1
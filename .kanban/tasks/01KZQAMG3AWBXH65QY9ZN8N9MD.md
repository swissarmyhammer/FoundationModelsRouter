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
- actor: claude-code
  id: 01kzrd53dcgzqrk9ansv7n5yyn
  text: |-
    ### review — findings

    - scope: `review sha HEAD~1..HEAD`, which resolved to commit `a3c2e4c` (parent `81d5142`). Another session pushed a kanban-only commit `4c6c75c` on top during the run, so `a3c2e4c` is now `HEAD~1`; the engine reads committed state, so the scope was correct and is unaffected.
    - evidence: 13 findings, 0 refuted into the record — 10 from the engine, 3 from the card's binding data model. Engine: `Concurrency/SerialAsyncChain.swift:28`, `Hosting/DetachingTool.swift:230`, `:681`, `:918`, `:1044`, `Session/RoutedSessionActorRecording.swift:322`, `Session/SessionOutbox.swift:192`, `:208`, `:252`, `:265` — all one rule, first parameter label omitted without a value-preserving conversion. Data model: `Hosting/SessionMailbox.swift:549` (a run's ending can be journaled twice), `Session/RoutedSessionActorRunJournal.swift:83` (`completionToken` written into `Transcript.ToolOutput.id`, a field documented three times here as Apple's `Transcript.ToolCall.id`), `Session/RoutedSessionActorForking.swift:219` (`close()` bypasses the journal chain).

    ### Data model, criterion by criterion

    1. Linear, append-only, correct order — VERIFIED. `SessionOutbox.post` claims the chain slot synchronously: `enqueueJournalWrite` (`:252`), `stage` (`:208`) and `wakeUp` (`:433`) are all non-`async`, so `await journalWrite?.value` (`:176`) is genuinely the first suspension point. `SerialAsyncChain.enqueue` reads and writes `tail` with no suspension. Coalescing touches only the in-memory pending list and never rewrites an appended entry; `requeue(_:)` restages without a second journal write. Two qualifications: events posted before the first `beginTurn()` are not journaled by design (`:253` returns `nil`), and `close()` bypasses the chain — recorded as a finding.
    2. Extraction did not change `RunEventFunnel` — VERIFIED. Same synchronous tail read/write, same non-detached `Task`, same `await previous?.value`, same handle returned, same `nil` base case; all call sites unchanged. One non-observable difference: the `Task {}` literal moved out of an actor-isolated context, so the chained task no longer starts on the funnel's executor. Its body is two cross-actor calls touching no funnel state.
    3. Interleaving preserved, not buffered — VERIFIED. The chain is per-outbox, not per-run, so there is no grouping by `correlationID`, and no batching structure exists in the change.
    4. One identity space — VERIFIED between the model's reference and the event. The token is minted once (`Hosting/SessionMailbox.swift:185`, called at `Hosting/DetachingTool.swift:356`), spliced into the envelope the model reads (`:206`), stamped as `correlationID` by `ToolContext` (`:159`, `:177`, `:215`), and used as the entry id (`RoutedSessionActorRunJournal.swift:83`). Every other construction site preserves rather than re-mints: sweep terminals, restored `.lost`, detail bounding, requeue, forks. No divergence path found. The separate problem is which id space the entry id lands in — see the finding on `:83`.
    5. Not a stringly-typed dumping ground — VERIFIED. Payload is `OperationEvent` inside `OperationEventSegment`, typed `kind`, and `OperationOutcome` keeping `.succeeded`/`.failed`/`.timedOut`/`.stopped`/`.cancelled`/`.lost` distinct. The new `text` argument is `OperationEventSegment.renderedLine(for:)`, a lossy one-line rendering also used by `description` and the preamble; the structured data still travels only in the typed segment.
    6. The model still gets the result — VERIFIED, by blob hash rather than by an empty diff: `RoutedSessionActorTurnExecution.swift` is `e635cddf8e96fdb1a4c981b1026d287abda38212` at both `81d5142` and `a3c2e4c`, and is absent from the commit's file list. `journaledCompletionStillReachesTheModel` is load-bearing: the stub records the composed prompt verbatim, and the assertion is exact equality, so dropping the preamble, dropping the staple, or double-including would each fail it.
    7. The D1 trap — the decision not to emit `SessionEvent.toolStatus` is CORRECT and its premise checks out (`Session/SessionEvent.swift` documents `toolCall`'s id as Apple's `Transcript.ToolCall.id`), and no `.toolCall`/`.toolStatus` is emitted on the journal path. But the sweep for other sites found one, in this commit's own new code — see the finding on `RoutedSessionActorRunJournal.swift:83`. Not reachable as a live event today, because the journal never reaches `emitSessionEvents` and restore baselines entries at `Recording/SessionTreeRestoration.swift:407`; what is wrong is the stated invariant, which a new test pins.
    8. Completeness — VERIFIED, no holes. Fail, timeout, cancel and success all synthesize a distinct terminal (`Hosting/DetachingTool.swift:500-509`, `:580-595`); a parked run always has `wasDetached == true`, so `settleRun` always delivers. `close()` journals swept terminals directly, so it works even if `beginTurn()` never ran. A forked child gets its own outbox, mailbox and journal. The attach point holds: `attachOutboxJournalIfNeeded()` runs before `acquireGenerationPermit()`, the flag is set before the `await` so a reentrant turn cannot double-attach, and every tool-capable model call goes through `beginTurn()`. The defect is the inverse of a hole — a duplicate.

    ### Not established: the ungated test claim

    The `swift test` / `swift build` verification could NOT be performed cleanly. The working tree carries a concurrent card's in-progress implementation (`^way106d`) — modified `Session/SessionEvent.swift`, modified `Session/SessionOutbox.swift`, new untracked `Session/TurnIdentity.swift`, modified `Tests/FoundationModelsRouterTests/PromptQueueTests.swift` — so any run measures two cards mixed together. The implementer's "4 consecutive runs green, 800 tests / 77 suites + 27 + 24" is therefore NOT confirmed by this review, and the acceptance criterion "Ungated `swift test` green" stands unverified even though it is checked. It needs re-running once `^way106d` lands. One sub-agent reported a green run and argued from file mtimes that it finished before the contaminating edits were written; that is not relied on here. Per the coordinator, re-verification happens on the combined result.

    `^79qgjef` confirmed genuinely pre-existing: `TurnCancellationTests.swift` and `RoutedSessionActorTurnExecution.swift` are both absent from `a3c2e4c`; the only turn-path file it touches gains one statement in `beginTurn()`, before generation starts.

    - next: fix the 13 findings, then re-review. Card stays in `review`.
  timestamp: 2026-08-11T12:35:58.508869+00:00
- actor: claude-code
  id: 01kzrd7he5n1hcrc9ht9d53jrr
  text: |-
    ### Orchestrator note on the two data-model findings — read before fixing

    **Finding: `completionToken` written into `Transcript.ToolOutput.id` (`RoutedSessionActorRunJournal.swift:83`).**

    This is `^w8dzvee`'s D1 recreated, one field over. The implement pass correctly identified the trap — it declined to emit `SessionEvent.toolStatus` precisely because that id is documented as Apple's `Transcript.ToolCall.id` — and then wrote a `completionToken` into `Transcript.ToolOutput.id`, which this codebase documents as the same Apple id space in three places (`RoutedSessionActorRecording.swift:414`, `DiscoveryPriming.swift:216`, and the journal's own doc at `:57`).

    The instruction it was given was "never put one identity space's id into a field documented as another's". Explaining the rule is not applying it.

    **The fix direction matters.** Do not just swap in a different id. The parent reference belongs in the **typed payload** — `OperationEventSegment` already carries the event, and the card's data model says every tool-related entry carries the originating call's id as a *parent reference*, not as its own identity. An entry's `id` is its own identity; the parent link is a separate field. Putting the parent id in the identity slot is what collapses two spaces into one. `DetachedRunTranscriptTests.swift:110` currently pins the wrong invariant and must be corrected with the code, not around it.

    **Finding: a parked run's ending can be journaled twice (`SessionMailbox.swift:549`).**

    This is a regression introduced by this change: before it, the outbox did not journal, so `close()` was the sole writer of a terminal. Two independent paths now exist —
    1. `sweep()` awaits `run.canceler()`, which suspends the mailbox actor; the run can settle naturally in that window and journal its own terminal live, after which `sweep()` returns the same event from `settledTerminalEvents` and `RoutedSessionActorForking.swift:220` appends it again;
    2. cooperative cancellation — a run swept at `close()` can still finish and post a second `.completed` for the same `correlationID` **with a different outcome**.

    The second is the dangerous one: the transcript would hold two contradictory outcomes for one call, and a view grouping by parent would render both. That breaks the card's own criterion that every parked call has *a* recorded outcome.

    **Do not fix this by mutating or removing an already-appended entry** — the data model is append-only, and rewriting history to hide a duplicate is worse than the duplicate. Make the terminal write idempotent per `correlationID` at the point of append, or establish a single writer. Whichever is chosen, the comment at `RoutedSessionActorForking.swift:188-190` currently asserts the opposite of the truth and must be corrected.

    Also: `close()` journals swept terminals through `append(partial:)` directly, bypassing the chain every other journal write uses (`RoutedSessionActorForking.swift:219`). Route it through the chain, or document why it must not be.

    **Sequencing note.** The ungated test verification on this commit was contaminated — I ran `^way106d`'s implementer concurrently against the same working tree, so the reported 800/77 measured two cards mixed together. That was my error. The fix pass for these findings must run **after** `^way106d` commits, and must re-verify ungated green cleanly.
  timestamp: 2026-08-11T12:37:18.405063+00:00
- actor: claude-code
  id: 01kzrjbp5shzte1kmr60hshtme
  text: |
    ### The `Transcript.ToolOutput.id` contradiction, settled from the SDK

    The review and this card's own design comment disagreed. The SDK settles it.

    Apple ships doc comments in the binary `.swiftdoc` beside the `.swiftinterface`. Extracted from
    `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftdoc`:

    ```
    s:16FoundationModels10TranscriptV10ToolOutputV2idSSvp
    /// A unique id for this tool output.
    ```

    `xcrun swift-demangle` on `$s16FoundationModels10TranscriptV10ToolOutputV2idSSvp` gives
    `FoundationModels.Transcript.ToolOutput.id : Swift.String`. The neighbouring entries confirm the
    field set: `.toolName` is "The name of the tool that produced this output.", `.segments` is
    "Segments of the tool output.", and the type itself is "A tool output provided back to the model."
    `Transcript.ToolCall.id` carries no doc comment at all.

    **Verdict: `Transcript.ToolOutput.id` is the output entry's OWN identity, not the id of the call it
    answers.** The card's design comment ("Apple's own convention for a `Transcript.ToolOutput` is that
    its `id` names the call it answers") is wrong as a documented contract.

    That convention does exist as *observed runtime behaviour*, and this codebase already says so — and
    already refuses to rely on it. `RoutedSessionActorRecording.swift`'s doc on
    `completedToolCallId(forOutputEntryId:dispatched:completed:)` states it verbatim: "Measured against
    macOS 27 FoundationModels ... `Transcript.ToolOutput.id` is the id of the call it answers ... **That
    invariant is the SDK's, undocumented and unenforced, and this router does not rely on it.**" So the
    codebase is already correct and consistent: the field is documented by Apple as the output's own
    identity; the id-equals-call-id coincidence is undocumented, and this router treats it as such. The
    three doc sites the review cited need no correction — they describe how a *model-invoked* output's
    id happens to arrive, not what the field means.

    **Therefore the second branch of the orchestrator note applies:** the field is the entry's own
    identity, so the journal must give the entry its own id and carry the parent reference in the typed
    payload. `OperationEventSegment` already carries the whole `OperationEvent`, `correlationID`
    included, so the parent reference needs no new field — only the identity slot has to stop being
    misused.

    ### Other facts established before editing

    - Only `.completed` is terminal — `OperationEventKind`'s own contract: "A run that posts any event
      at all must post exactly one terminal (`.completed`) event before it ends." So idempotence is
      keyed on `(correlationID, kind == .completed)`.
    - `SessionMailbox.park(tool:op:kind:completionToken:settling:canceler:)` is `public` and takes the
      settling task and canceler as parameters, so both double-journal races are constructible from a
      test with no live model and no `DetachingTool`.
    - `SessionOutbox.journalChain` is the only ordering authority for journal writes; `close()` reaching
      `append(partial:)` directly is what puts it outside that order.
  timestamp: 2026-08-11T14:06:57.209459+00:00
- actor: claude-code
  id: 01kzrjwhn954a74a85caq8bwb6
  text: |
    ### The three design findings — what changed, and the proof

    **1. `SessionMailbox.swift:549` — a parked run's ending journaled twice. Fixed by making the terminal write idempotent per `correlationID` at the point of append.**

    `RoutedSessionActor` gains `journaledTerminalCorrelationIDs`, and `record(event:)` now opens with
    `guard claimJournalWrite(for: event) else { return }`. The claim is synchronous, taken before any
    suspension on the actor, so the two writers cannot both claim one run. Only `.completed` is claimed,
    because `OperationEventKind`'s own contract makes only `.completed` terminal; progress and
    elicitation stay uncapped, as a run's running commentary must.

    **First write wins, and nothing already appended is ever mutated or removed.** The record is
    append-only; rewriting history to hide a contradiction would be worse than the contradiction.

    Proved to bite, both directions, before the fix existed. `swift test --filter
    DetachedRunTranscriptTests` on the unfixed code:

    - `a run that settles inside sweep()'s canceler window is journaled once` — `terminals.count → 2`
    - `a swept run that finishes cooperatively afterwards does not journal a second, contradicting
      terminal` — `terminals.count → 2`

    Both are built from real machinery, not stubs of it: a run is parked in the session's own
    `SessionMailbox` with a real `settling` task and a real canceler, and `session.close()` drives the
    real `sweep()`.

    - Direction 1 runs the race rather than hoping for it. The canceler signals the run's body, then
      itself awaits `mailbox.wait(completionToken:seconds:)`, so it cannot return until the mailbox has
      marked the run settled — which holds `sweep()` inside exactly the window it suspends across. The
      body posts its terminal through the outbox in that window, journaling it live; `sweep()` then
      returns the same retained event, and `close()` used to append it again.
    - Direction 2 is the contradiction case. The sweep synthesizes `.cancelled`; the cooperatively
      cancelled run then finishes and posts `.succeeded` for the same token. The test asserts one
      terminal *and* that it is `.cancelled` — the first-recorded one — so a fix that kept the wrong
      ending would still fail.

    After the fix both report exactly one terminal with the right outcome.

    The comment at `RoutedSessionActorForking.swift` that asserted the opposite ("a sweep only ever
    produces terminals for runs still parked ... so the two paths never record one run's ending twice")
    is deleted and replaced with a statement of both collision paths and how they are reconciled.

    **2. `RoutedSessionActorRunJournal.swift:83` — `completionToken` in `Transcript.ToolOutput.id`.
    Settled against the SDK; the id was wrong, so the code changed.**

    Verdict and evidence are in the comment above: Apple documents that field as "A unique id for this
    tool output" — the entry's own identity. So the second branch of the orchestrator note applies.

    - The entry now carries a fresh `ULID.generate().description`: its own identity.
    - The parent reference stays where it already was and where it belongs — inside the typed
      `OperationEventSegment`, whose `OperationEvent` carries `correlationID`. No new field was needed;
      the identity slot simply stopped being misused.

    The old shape was not only a category error, it made the id useless *as* an identity: every report
    of one run shared one entry id, so a lifecycle of many entries was indistinguishable from one entry
    appended repeatedly. The regression test now pins that too — three posted events of one run must
    yield three distinct entry ids and one distinct `correlationID`.

    `DetachedRunTranscriptTests.swift:110` no longer pins the wrong invariant. It now asserts
    `entryId != token`, `!entryId.isEmpty`, and `event.correlationID == token`, so the parent reference
    is checked where it actually lives.

    **The three doc sites were left alone, deliberately, and here is why that is not a dodge.** They do
    not claim `Transcript.ToolOutput.id` *means* a call id. `RoutedSessionActorRecording.swift` states
    the observation and then disclaims it in the same breath — "That invariant is the SDK's,
    undocumented and unenforced, and this router does not rely on it" — and the code backs that up:
    `completedToolCallId(forOutputEntryId:dispatched:completed:)` resolves a completion's call id from
    the calls the same diff announced, never from the entry id. The journal's own doc at `:57` was the
    one place that stated the false convention as fact, and that is the text this change rewrites.

    **3. `RoutedSessionActorForking.swift:219` — `close()` bypassed the journal chain. Routed through
    it.**

    New `SessionOutbox.journalWithoutStaging(event:)` enqueues on the same `journalChain` every other
    journal write uses, and stages nothing — there is no next turn for a teardown terminal to ride, so
    staging it would leave an item pending on an outbox nothing will ever drain. `close()` now calls it
    per swept terminal instead of reaching `append(partial:)` directly, and calls
    `attachOutboxJournalIfNeeded()` first so the path never depends on "a run can only be parked from
    inside a turn" continuing to hold for every future caller. Its `recordSessionMetaIfNeeded()` call is
    gone because `record(event:)` already does it — and better: a close whose swept terminals were all
    already journaled now records no meta line either, instead of opening a file to write nothing.
  timestamp: 2026-08-11T14:16:09.641280+00:00
- actor: claude-code
  id: 01kzrjxbehabzz3kqyc7hd0ndb
  text: |
    ### The ten label findings — every site, fixed or waived, with its access level

    One rule for all ten: **"Omit the first argument label only for value-preserving conversions.
    Otherwise, label it."** (`swift/fluent-usage`, quoted verbatim from `dump validators`.)

    The card's policy splits on whether a rename is source-breaking, and source-breaking only applies to
    `public` API. I checked each site's real access level, as instructed, and applied the policy on that
    reading.

    #### Fixed — no external consumer can be broken (6 of the 10 findings)

    | Site | Access | Change |
    |---|---|---|
    | `Concurrency/SerialAsyncChain.swift` `enqueue` | internal (new in `a3c2e4c`) | `enqueue(body:)` |
    | `Session/SessionOutbox.swift` `requeue` | internal (new in `a3c2e4c`) | `requeue(event:)` |
    | `Session/SessionOutbox.swift` `enqueueJournalWrite` | private (new in `a3c2e4c`) | `enqueueJournalWrite(event:)` |
    | `Session/SessionOutbox.swift` `stage` | private | `stage(event:)` |
    | `Session/SessionOutbox.swift` `appendNewPendingEvent` | private | `appendNewPendingEvent(event:)` |
    | `Session/RoutedSessionActorRecording.swift` `appendingOperationEventSegments` | private static | `appendingOperationEventSegments(events:to:)` |
    | `Hosting/DetachingTool.swift` `register` | internal, on `private final class RaceGate` | `register(continuation:)` |

    `DetachingTool.swift`'s `register` sits in the card's "do not rename" list, but its real access level
    is internal on a **file-private** type, so no consumer outside this one file can see it and the
    source-breaking constraint the policy rests on does not apply to it. That is the whole reason the
    card said to check.

    #### Swept, same rule, same files — not in the findings but the same cause

    A finding shows one example of a cause; the cause is removed from the file. Three more non-public
    sites in the files already being edited:

    - `Session/OperationEventJournal.swift` `record` → `record(event:)` (internal protocol, new in
      `a3c2e4c` — named by the card's own "anything introduced by `a3c2e4c`" clause).
    - `Session/RoutedSessionActorRecording.swift` `requeueUnattachedPendingEvents` →
      `requeueUnattachedPendingEvents(events:)` (internal).
    - `Hosting/DetachingTool.swift` `enqueueUpstream` → `enqueueUpstream(event:)` (private).

    Every DocC link to a renamed symbol was updated with it, so no doc reference is left dangling.

    #### Waived — rule versus constraint, stated as a conflict

    Four sites are left unchanged. In each the rule is correct and the code does violate it; a documented
    constraint outranks applying it here.

    | Site | Access | Constraint |
    |---|---|---|
    | `Hosting/DetachingTool.swift` `isRendered(_ text:)` | **public static**, pre-existing | Source-breaking rename of shipped public API |
    | `Hosting/DetachingTool.swift` `wrapping(_ tool:…)` | **public static**, pre-existing | Source-breaking rename of shipped public API |
    | `Hosting/DetachingTool.swift` `post(_ event:)` (`RunEventFunnel`) | internal, pre-existing | **Protocol requirement.** It implements `OperationEventSink.post(_:)`, which is `public`. Renaming the member breaks the conformance; renaming it *and* the protocol is a source-breaking change to public API |
    | `Session/SessionOutbox.swift` `post(_ event:)` | **public**, pre-existing | Same `OperationEventSink.post(_:)` requirement, and public in its own right |

    The stated conflict is the card's, recorded so it is not rediscovered: two source-breaking public
    renames already shipped in this batch (`45b3930`, `e6b6070`), and a third for a style rule is not
    acceptable. `OperationEventSink.post(_:)` adds a second, independent reason for the two `post` sites
    — a protocol requirement cannot be relabelled on the conforming side alone, which is one of the
    listed true conflicts (a rule that requires code that cannot compile).

    A previous attempt renamed across `Hosting/DetachingTool.swift`, `Hosting/ToolContext.swift` and
    `Hosting/OperationEventSink.swift` and was discarded for exactly this. Not repeated. Those two other
    files are untouched by this pass.
  timestamp: 2026-08-11T14:16:36.049050+00:00
- actor: claude-code
  id: 01kzrjz8366tnp30m9vnkhxcny
  text: |
    ### implement — changed

    - evidence: 10 files, commit `228b067`. `Session/RoutedSessionActorRunJournal.swift` (idempotence gate `claimJournalWrite(for:)`, own-ULID entry id, rewritten identity doc), `Session/RoutedSessionActor.swift` (`journaledTerminalCorrelationIDs`), `Session/RoutedSessionActorForking.swift` (`close()` routed through the chain, false "never twice" comment replaced), `Session/SessionOutbox.swift` (`journalWithoutStaging(event:)` + label fixes), `Session/OperationEventJournal.swift`, `Concurrency/SerialAsyncChain.swift`, `Session/RoutedSessionActorRecording.swift`, `Session/RoutedSessionActorTurnExecution.swift` (doc links), `Hosting/DetachingTool.swift`, `Tests/FoundationModelsRouterTests/DetachedRunTranscriptTests.swift` (+2 tests, corrected id invariant).
    - red then green, both duplicate directions: on the unfixed code the canceler-window test and the cooperative-post test each reported `terminals.count → 2`; the identity test reported `entryId == token` and `Set(entryIds).count → 1` for 3 entries. All six pass after the fix.
    - tests: ungated `swift test` run 3 consecutive times — **811 tests / 77 suites + 27 / 11 + 24 / 5, zero failures**, 1 pre-existing `BoundedWait` known issue each time. Baseline was 809/77; +2 is the two new tests. `swift build` clean, no compile warnings. `TurnCancellationTests.cancellingAStreamingTurnFinishesTheStreamWithCancellationError` (`^79qgjef`) did not fire in any of the three runs.
    - all 13 review findings ticked; 3 design findings fixed, 7 label sites fixed (6 findings + `register` on the file-private `RaceGate`), 4 waived with access levels and the rule-versus-constraint conflict stated. 3 further non-public sites in the same files swept for the same cause.
    - not run: gated suites (`FM_ROUTER_INTEGRATION_TESTS=1`, `MULTITOOL_INTEGRATION=1`) per `^pw807cp`; `swift format` (never in this repo); `Scripts/check-doc-links.py` (deleted). Nothing pushed. `FoundationModelsMultitool` and the vendored `mlx-swift-lm` fork untouched.
    - next: `/review`.
  timestamp: 2026-08-11T14:17:38.150418+00:00
- actor: claude-code
  id: 01kzrkybv7rx7xnx2nqfshnbze
  text: |-
    ### review — clean

    - scope: `review sha HEAD~1..HEAD`, which resolved to `ca792cb..7210df0` — the commit under review. `HEAD` was `7210df0` when the engine ran. Another session then committed the kanban-only commit `fc0a751` on top. A sha-scoped read uses committed state, so the scope is correct.
    - engine: 18 validator and file pairs attempted, **0 findings**, 1 candidate refuted, 0 failed, 0 skipped. All 13 findings of the last round are ticked. All 6 acceptance criteria are ticked.
    - tests: I ran ungated `swift test` 3 times, one after the other, alone. Each run gave **811 tests / 77 suites + 27 / 11 + 24 / 5, zero failures**, and 1 known issue at `BoundedWait.swift:114`. I checked `git status --porcelain -- Sources Tests` before and after each run. It was empty every time. This agrees with the claim. The baseline was 809/77, so the 2 more tests are the 2 new tests. `swift build` is clean, with no compiler warning.

    ### The six checks

    **1. The `Transcript.ToolOutput.id` verdict — the extraction is real.** I read Apple's binary `.swiftdoc` again, without trust in the claim. In `/Applications/Xcode-beta.app/…/FoundationModels.swiftmodule/arm64e-apple-macos.swiftdoc`, the symbol `s:16FoundationModels10TranscriptV10ToolOutputV2idSSvp` is followed by the text `A unique id for this tool output.` The neighbour symbols use the same layout, for example `.segments` gives `Segments of the tool output.` `xcrun swift-demangle` on `$s16FoundationModels10TranscriptV10ToolOutputV2idSSvp` gives `FoundationModels.Transcript.ToolOutput.id : Swift.String`. The `.swiftinterface` holds the declaration but no doc comment, which is usual. So the field is the entry's own identity. Nothing in the framework docs says the id is the id of the call it answers.

    The entry now mints its own id: `RoutedSessionActorRunJournal.swift:150` uses `ULID.generate().description`. The parent reference is in the typed segment at `:152`.

    The parent reference is truly reachable. `OperationEventSegment` is public, its `content` is public, and `OperationEvent.correlationID` is public. `TranscriptReconstruction` defaults to `CustomSegmentRegistry.routerDefault`, which already registers `OperationEventSegment`, so a client needs no setup. `SessionMailboxTests.swift:676-685` walks exactly the path a client walks and reads the `correlationID` back. The rendered text also holds the id in plain words.

    **2. `claimJournalWrite(for:)` stops the duplicate.** There is no gap between the check and the claim, because there is no pair. `Set.insert` does both in one expression at `RoutedSessionActorRunJournal.swift:83-86`. The function is not `async`, so it cannot suspend. It is isolated to `RoutedSessionActor`, and `journaledTerminalCorrelationIDs` is actor state. It has one caller, `record(event:)`, and the guard is the first statement, before both `await`s. A caller that loses the claim returns at once and appends nothing. Both duplicate paths now go through the same `record(event:)`, so one claim covers both. Nothing already appended is changed or removed: every recorder only appends, and the claim only causes an early return.

    **3. The bite-proof is real, and I proved it by experiment.** Both tests use a real parked run in the session's real `SessionMailbox`, and `session.close()` drives the real `sweep()`. Neither test calls `record(event:)`, `append(partial:)`, or `claimJournalWrite` itself. I made the claim always succeed and ran the suite: `DetachedRunTranscriptTests.swift:276` gave `terminals.count → 2`, and `:322` gave `terminals.count → 2`. Both failed, and the other 4 tests still passed. I then tried a wrong fix that keeps the later success: `:323` failed with `terminals.first?.outcome → .succeeded`. So the outcome assertion bites on its own. The suite passed 6 of 6 before and after I put the file back.

    **4. `close()` goes through the chain.** `SessionOutbox.journalWithoutStaging(event:)` calls the same private `enqueueJournalWrite(event:)` that `post(_:)` calls, on the same one `journalChain`. It is not a second chain and not a bare `Task`. Order stays sure: `SerialAsyncChain.enqueue` reads `tail` synchronously before any suspension, and each task first awaits the task before it. `journalWithoutStaging` awaits `.value`, and `close()` awaits each turn of its loop. No event is lost when staging is skipped: every reader of the staged list is next-turn machinery, and after `close()` there is no next turn. The transcript is the record, and restore rebuilds these terminals from it.

    **5. The waivers are all correct.** `isRendered(_:)` at `DetachingTool.swift:230` is `public static` and dates from `13a7048`. `wrapping(_:…)` at `:681` is `public static` and dates from `6cffe80`. Both are older than this batch and this commit does not touch them. `post(_:)` on `SessionOutbox` is `public` and is also an `OperationEventSink` requirement. `post(_:)` on `RunEventFunnel` is an internal member of a file-private actor, so access is not the reason, but the protocol reason is real: Swift matches a requirement by the full selector, so a rename on the conforming side alone breaks the conformance. I checked the way out that would make the waiver wrong, and it is not there: `OperationEventSink` is itself `public`, and `ToolContext.post` is a third public conformer, so a rename of the protocol with all conformers is still a source-breaking change. All 11 fixed and swept sites now carry a label, and every one is internal, private, or file-private. `RaceGate` is file-private, as claimed.

    **6. No public API broke.** `git diff 7210df0^..7210df0 -- '*ToolContext.swift' '*OperationEventSink.swift'` is empty, and neither file is in the commit's file list. Both files still hold their first labels. A search of the whole commit for a changed `public` or `open` declaration returns zero lines. Nothing of the discarded attempt is left.

    ### Two things to know, neither a finding

    - `TranscriptEntryMapper.entry(from:kind:registry:)` defaults to an empty `CustomSegmentRegistry()`, but the public high-level entry points default to `.routerDefault`. The two defaults disagree. A client that calls the low-level API with the default gets a thrown `unregisteredCustomSegmentType`, which is a loud failure, not lost data. This code is older than this commit and this commit does not touch it, so it is out of scope here. Worth a card of its own.
    - The claim is taken before the append, and `JSONLRecorder.append` drops the write on an I/O failure. So if the first writer fails to write to disk, the `correlationID` is used up and the second writer is refused. This only happens when the disk write already failed, and the record is already incomplete in that case. Not a rule breach, but worth stating.

    ### A note on my own method

    My first test measurement was bad. I ran the test agent at the same time as the agent that neuters the mechanism to prove the bite, so runs 2 and 3 measured a changed tree. That is the same contamination as the last round, and it was my fault. I threw that evidence away and ran the 3 runs again, alone, with a clean-tree check around each one. The numbers above come from the clean runs.

    The failure seen in the bad runs was `TurnCancellationTests.swift:1187`, which is `^79qgjef` exactly — same file, same line, same assertion. That card records 3 failures in 8 runs both with this change and with it stashed. It did not appear in any of my 3 clean runs.

    - next: none. Card moves to `done`.
  timestamp: 2026-08-11T14:34:37.799540+00:00
- actor: claude-code
  id: 01kzrmf6xgxh9q80adjntfw9x5
  text: |
    ### Follow-up: the three public label findings were ticked but not applied

    This card ticked ten label findings. The commit `7210df0` applied the seven non-public ones and left the three public ones in the code, with the reason recorded on the card: two source-breaking public renames had already shipped in the batch.

    The user then gave a direct instruction to apply them. That work is on `^pckk91c`, which lands:

    - `PendingRunEnvelope.isRendered(text:)`
    - `ToolDetachment.wrapping(tool:sessionID:mailbox:sink:configuration:)`
    - `OperationEventSink.post(event:)`, with its two conformers (`SessionOutbox`, `RunEventFunnel`) and every call site

    Recorded here so a reader of this card does not think the code matches the ticks.
  timestamp: 2026-08-11T14:43:49.808741+00:00
position_column: done
position_ordinal: ff8980
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
- Aligns with the standing direction: stream transcript entries, do not invent a parallel layer of data types.

## Review Findings (2026-08-11 07:16)

> tool rule 'code-hygiene/no-commented-code-parsed' is unavailable (tool missing: bash: : command not found); prompt rule 'no-commented-code' ran instead.

- [x] `Sources/FoundationModelsRouter/Concurrency/SerialAsyncChain.swift:28` — First parameter label omitted on `enqueue` method without a value-preserving conversion. This is a method enqueueing a closure body to execute serially, not a conversion operation, so it should label its parameter. Change to `mutating func enqueue(body: @escaping @Sendable () async -> Void) -> Task<Void, Never>` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:230` — First parameter label omitted on `isRendered` method without a value-preserving conversion. The method is a predicate/test function, not a type conversion, so per the fluent-usage rule it should label its parameter. Change to `public static func isRendered(text: String) -> Bool` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:681` — First parameter label omitted on `wrapping` static factory method without a value-preserving conversion. This is not a type conversion but a factory method decorating a tool with detachment behavior, so it should label its parameter. Change to `public static func wrapping(tool: any Tool, sessionID:, ...)` to label the first parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:918` — First parameter label omitted on `register` method without a value-preserving conversion. This is registering a continuation for race resolution, not a conversion operation. Change to `func register(continuation: CheckedContinuation<Value, Never>)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:1044` — First parameter label omitted on `post` method without a value-preserving conversion. This is a side-effecting method posting an event (implementing OperationEventSink protocol), not a conversion operation. Change to `func post(event: OperationEvent) async` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:322` — First parameter label omitted on `appendingOperationEventSegments` static method without a value-preserving conversion. This is a helper method to augment a partial with segments, not a conversion operation. Change to `private static func appendingOperationEventSegments(events: [OperationEvent], to partial: TranscriptEvent.Partial)` to label the first parameter.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:192` — First parameter label omitted without a value-preserving conversion. The fluent-usage rule states: 'Omit the first argument label only for value-preserving conversions. Otherwise, label it.' `requeue` is a side-effecting method restaging an event, not a conversion, so the parameter should be labeled. Change to `func requeue(event: OperationEvent)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:208` — First parameter label omitted without a value-preserving conversion. The method `stage` is not a conversion operation but a side-effecting helper that stages an event, so per the rule it should have a labeled parameter. Change to `private func stage(event: OperationEvent)` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:252` — First parameter label omitted on `enqueueJournalWrite` method without a value-preserving conversion. This is a helper method enqueueing a journal write operation, not a conversion operation, so it should label its parameter. Change to `private func enqueueJournalWrite(event: OperationEvent) -> Task<Void, Never>?` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:265` — First parameter label omitted without a value-preserving conversion. This pre-existing method violates the fluent-usage rule: `appendNewPendingEvent` is not a conversion but a side-effecting method that should label its parameter. Change to `private func appendNewPendingEvent(event: OperationEvent)` to label the parameter.

### Data-model verification, same pass

Checked against the binding data model in this card's comment of 2026-08-11 02:34. These are requirements on the same footing as every item above.

- [x] `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:549` — One parked run's ending can be journaled twice, which breaks the append-only record's claim that a run ends once. `sweep()` awaits `run.canceler()` at `:546`, which suspends the mailbox actor; the run can settle naturally during that window, and `DetachingTool.settle` (`:509`) awaits `funnel.settleRun` (`:1105`) which posts the terminal to `SessionOutbox.post`, journaling it live. `sweep()` then resumes, finds the same event in `settledTerminalEvents` at `:549`, and returns it, so `RoutedSessionActorForking.swift:220` journals the identical event a second time. A second path reaches the same result: cancellation of a `.swiftTask` run is cooperative (`DetachingTool.swift:459-466`), so a run swept at `close()` can still finish afterwards and post its own terminal through the still-attached journal, appending a second `.completed` for the same `correlationID` with a different outcome. This is a regression of this change — before it the outbox did not journal, so `close()` was the only writer. The doc comment asserting the opposite at `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:188-190` ("the two paths never record one run's ending twice") must be corrected or made true. Fix the cause for both paths, not only the canceler window: distinguish a synthesized terminal from a natural one, or make the journal reject a terminal for a `correlationID` that already reached it.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift:83` — The entry id puts a `completionToken` into `Transcript.ToolOutput.id`, a field this codebase documents three times as holding Apple's `Transcript.ToolCall.id`: `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:414`, `Sources/FoundationModelsRouter/Session/DiscoveryPriming.swift:216`, and this file's own doc at `:57`. The `completionToken` is a ULID minted at `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:356`, independent of the SDK-assigned `Transcript.ToolCall.id`, so the journaled entries are tool outputs whose id names no call — conceded at `:50-52` ("The entry has no paired `.toolCalls`"). This is `^w8dzvee`'s D1 conflation moved one field over. It is not reachable as a live `SessionEvent` today, because the journal never reaches `emitSessionEvents` and `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:407` baselines restored entries with `persistedEntryCount: transcript.count`; without that baseline, `completedToolCallId` (`Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:436-443`) would fall through to `?? outputEntryId` and emit `.toolStatus(id: <completionToken>)`. Correct the stated invariant at `:54-61` and in the commit message, which claim the model's reference and the transcript's parent reference are one identity space when the merge is actually with Apple's transcript id space. `Tests/FoundationModelsRouterTests/DetachedRunTranscriptTests.swift:110` (`#expect(journaled.first?.entryId == token)`) pins the wrong invariant and must be updated with the fix.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:219` — `close()` journals swept terminals by calling `append(partial:)` directly, bypassing the `journalChain` that every other journal write goes through (`Sources/FoundationModelsRouter/Session/SessionOutbox.swift:252-255`). Position in the transcript is the record, but close-journaled terminals are not ordered against journal writes still in flight on the chain, so a terminal appended at teardown can land before an earlier posted event that has not yet drained. Route the teardown path through the same chain, or otherwise establish the ordering the rest of the design relies on. #phase-1
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzsj80b45dqde03gjmjzg29v
  text: |-
    ### Research — what the code shows

    Facts, each read from the code:

    - The sink each binding layer holds is the session's `SessionOutbox` (`RoutedLLM.swift` passes `sink: outbox`; forks pass the child outbox). `SessionOutbox.post(_:)` stages an event for a FUTURE turn and journals it. It does not reach the current turn's event stream.
    - The four `SessionEvent.toolCall`/`.toolStatus` construction sites are all in `RoutedSessionActorRecording.swift`, in the post-turn diff. Each id comes from Apple's `Transcript.ToolCall.id`.
    - The binding layers (`DetachingTool.call`, `ContextBindingTool.call`) do not receive the SDK call id. The `Tool.call(arguments:)` boundary carries only the decoded arguments. The model executor mints `Transcript.ToolCall.id` (scripted model: script ids; MLX: UUID strings).
    - A mid-turn read of `backend.transcriptEntries()` is not permitted. Its contract says a read is safe only when no generation call can append concurrently. During a turn the SDK appends live, so the actor cannot peek the transcript to learn the SDK call id early.
    - The attach pattern for live outbox-to-actor delivery exists: `OperationEventJournal`, weak reference, attached in `beginTurn()` through `attachOutboxJournalIfNeeded()`.
    - `ToolContext.completionToken` is a ULID string, minted per call, and is the `correlationID` on every posted `OperationEvent`. One identity space for the run, per ^zn8n9md.
    - The test harness for a scripted tool turn exists: `ScriptedSessionFixture.make(playing:mounting:tempDirPrefix:)` drives the real `MLXFoundationModelsSessionBackend` over `ScriptedToolCallingModel`, with tools mounted through the real binding layers (`DetachConfiguration.nativeSessionMount`, mode `.detaching`, wait 5 s).
    - `SessionProjection.Phase.runningTool` today only becomes set at diff time, from `.toolCall`/`.toolStatus`. That is the "spinner with no truth" the card describes.

    Conclusion on identity: the live event cannot carry an id the diff will confirm. The SDK call id does not exist at the binding layer, and the identity rule (cards ^zn8n9md, ^way106d) forbids a `correlationID` inside a `.toolCall`/`.toolStatus` id. The design must reconcile the two spaces explicitly. The design comment that follows records the decision.
  timestamp: 2026-08-11T23:24:10.980255+00:00
- actor: claude-code
  id: 01kzsjajj7qnyvp83wpzb1fx4a
  text: |-
    ### Design decision — the identity reconciliation, recorded

    The card's proposal says: translate the invocation records into live `.toolCall`/`.toolStatus` events "using the same ids the post-turn diff will confirm". The research comment above shows this is not possible: the SDK call id does not exist at the binding layer, a mid-turn transcript read is forbidden by `transcriptEntries()`'s own contract, and the identity rule (cards ^zn8n9md, ^way106d) forbids a `correlationID` inside a `.toolCall`/`.toolStatus` id. The dispatcher's brief authorizes the alternative: "the design must reconcile them explicitly — record whatever you decide on the card". This comment records that decision.

    **Decision: the two identity spaces stay separate, by type, and never share a field.**

    1. New public type `ToolInvocationRecord` (Hosting layer): `tool`, `op`, `correlationID`, `sessionID`, `openedAt`, `closedAt?`, and a derived `duration`. The `correlationID` is the run's `completionToken` — the SAME identity space as `OperationEvent.correlationID`, and the type documents that. It is never an SDK call id.
    2. The binding layers post the record through the sink they already hold (`OperationEventSink` gains a defaulted `post(invocation:)` requirement, so every existing conformer compiles unchanged). `DetachingTool` posts the open record before it starts the work, and the close record when the wrapped call returns — also for a detached run, late, self-attributed by `correlationID`. `ContextBindingTool` does the same around its in-band call, on the success path and the throw path.
    3. `SessionOutbox` forwards an invocation record to a weakly attached observer on the session actor (the `OperationEventJournal` attach pattern, same attach point in `beginTurn()`). It never stages and never journals the record: the record is delivery-only. The post-turn diff stays the one authority for what is RECORDED, byte for byte.
    4. The session actor emits a new live event case, `SessionEvent.toolInvocation(ToolInvocationRecord)`, on the current turn's stream and on the session-scoped feed. `.toolCall`/`.toolStatus` stay untouched: their ids remain Apple's `Transcript.ToolCall.id` space only, and they keep arriving from the diff.
    5. A consumer joins the two views explicitly: the live record identifies the run (`correlationID`, tool name, open order inside the turn frame); the diff's `.toolCall` identifies the SDK call. The event doc states this join and states that neither id may be stamped into the other.
    6. `SessionProjection` gains one behavior: `phase` becomes `.runningTool` when an open record arrives and returns to `.generating` when the last open record closes. That is the live "running tool" truth the card asks for. Transcript rows stay diff-driven.

    Deviation from the card's letter, stated plainly: the live event is `.toolInvocation`, not a live `.toolCall`. A live `.toolCall` would require an id from a space the binding layer cannot reach, or an id from the wrong space — the exact ^w8dzvee D1 defect. Adding a `SessionEvent` case follows the documented evolution policy on that enum (`turnStarted` was added the same way in ^way106d, with the source-compatibility note).

    Ordering guarantees delivered: the open record is awaited to delivery before the wrapped tool starts, so it arrives while the tool still runs. An in-band close record is awaited to delivery before the tool returns to the SDK, so it precedes `turnEnded`. The diff's `.toolCall` precedes its `.toolStatus(completed)`, and both precede `turnEnded`, unchanged.

    Handoff note for ^1s8p8qt (TurnOutcome — NOT built here, per the dispatcher's scope note): `ToolInvocationRecord` carries `openedAt`, `closedAt`, and `duration`, and is `Codable`/`Equatable`/`Sendable`, so `TurnOutcome` can surface the turn's records directly for per-call durations without touching the event stream. The type's doc states this.
  timestamp: 2026-08-11T23:25:35.175146+00:00
- actor: claude-code
  id: 01kzsmbgpk01h6bq3gt4v2crym
  text: |-
    ### Orchestrator note — implement step interrupted and restarted
    The first implement agent for this card ended early on a transient network error (the API server was unreachable). It had moved the card to `doing` and written the RED test suite `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift` (untracked in the working tree); no source file changed yet. A new implement agent continues from that state. This note replaces a stuck report because the failure was environmental, not task-inherent.
  timestamp: 2026-08-12T00:01:03.187600+00:00
- actor: claude-code
  id: 01kzsn244d6z796wjpzdr4sfq1
  text: |-
    ### Resume — RED evidence confirmed, research complete

    The second implement agent resumed from the interrupted state. RED evidence: `swift build --build-tests` fails to compile `ToolInvocationLivenessTests.swift` — `cannot find type 'ToolInvocationRecord'`, `reference to member 'toolInvocation' cannot be resolved`, `type 'ScriptedToolFixture' has no member 'firstStepName'`, and `fixture.recorder` does not exist. That is the correct failure: the feature is missing, not the test.

    Discoveries past the prior design comments, each read from the code:

    - The turn's own event sink (`turnEventSink(onEvent)`) is a LOCAL closure inside `runTurn` — no actor state names the current turn's sink. Live delivery therefore needs one new actor property, set for the turn's duration in `runTurn` and cleared by `defer`, that `deliver(invocation:)` reads. Actor reentrancy makes this safe: the actor is free while `runTurn` awaits the model call.
    - `SessionOutbox` holds its journal weakly through the `OperationEventJournal` protocol. The invocation observer follows the SAME pattern with a SEPARATE internal protocol (`ToolInvocationObserver`) and a second weak var, because the journal's contract is "recorded into the transcript" and the observer's is delivery-only — one protocol must not carry both meanings.
    - The RED suite needs two test-helper additions to compile: `ScriptedToolFixture.firstStepName` (a shared step-name constant) and a `recorder: InMemoryRecorder` property on `ScriptedSessionFixture` (created in `make`, passed to `RouterTestFixtures.makeRouter(recorder:)`).
    - Two exhaustive switches over `SessionEvent` exist in this repo's tests (`ScriptedToolTurnComparisonTests`, `RealToolTurnComparisonTests`); both get the new case added to their ignore arm. The one production exhaustive switch is `SessionProjection.apply(_:)`.
    - The in-band ordering guarantee falls out of task structure: `DetachingTool` posts the open record (awaited) before it creates the work task, and the work task posts the close record after `settle` returns — `.runToCompletion` and a settled `.detaching` call both await that task before returning, so both records are delivered before the SDK gets the output. A detached run's close posts late from the same task, self-attributed by `correlationID`.
    - `ULID` (yaslab library, re-exported) is already `Codable`/`Equatable`/`Sendable`, so `ToolInvocationRecord` can be all three for the ^1s8p8qt handoff.
  timestamp: 2026-08-12T00:13:23.981399+00:00
- actor: claude-code
  id: 01kzstj1jhfnprjfk08nyrc1av
  text: |-
    ### Implementation landed — RED to GREEN

    GREEN evidence: `swift build --build-tests` clean (zero errors, zero warnings beyond the accepted vendored mlx-swift "missing creator" line), then ONE ungated `swift test`: 841 tests in 80 suites passed (plus 27 and 24 in the sibling targets), with exactly 1 known issue — the pre-existing, accepted BoundedWait one. All 9 liveness tests pass, including the acceptance case: the open `.toolInvocation` event arrives while the gated tool still runs, and open < close < diff `.toolCall` < `.toolStatus(completed)` < `turnEnded`.

    What was built, matching the design comment exactly:

    - NEW `Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift` — public, `Codable`/`Equatable`/`Sendable`, `duration` derived, `closed(at:)`. Docs state the identity rule and the ^1s8p8qt handoff (`TurnOutcome` NOT built).
    - `OperationEventSink` gains `post(invocation:)` with a default no-op extension — every existing conformer compiles unchanged.
    - `DetachingTool.call` posts the open record (awaited) before the work task starts and the close record inside the work task after `settle` returns — in-band settlements deliver both before the call returns; a detached run posts its close late, self-attributed by `correlationID`. `ContextBindingTool.call` posts open before and close after the wrapped call, on the throw path too (a `Result` capture, because `defer` cannot await).
    - `SessionEvent.toolInvocation(_:)` added, with the delivery-only, identity-rule, and ordering doc; the "Source compatibility" paragraph now names it beside `turnStarted(_:)`.
    - `SessionOutbox.post(invocation:)` forwards to a new weakly-held internal `ToolInvocationObserver` (declared beside `OperationEventJournal`) and does nothing else — never staged, never journaled. Attached in `attachOutboxJournalIfNeeded()` beside the journal.
    - `RoutedSessionActor` conforms to `ToolInvocationObserver`: during a turn the record goes through the new `currentTurnEventSink` (installed/cleared by `runTurn` for exactly the turn's duration) so it reaches the turn's own stream AND the session-scoped feed; between turns it reaches the session-scoped feed alone.
    - `SessionProjection`: `.toolInvocation` open sets `.runningTool`; the close of the last tracked open returns to `.generating`; `turnEnded` clears the tracked set so a detached run's stale open never pins a later turn; an untracked close changes nothing.
    - Exhaustive `SessionEvent` switches updated: `SessionProjection.apply`, `ScriptedToolTurnComparisonTests`, `RealToolTurnComparisonTests`, and `Examples/CompactionDemo/main.swift` (the switch the first build run surfaced).
    - Test helpers the RED suite required: `ScriptedToolFixture.firstStepName`, and `ScriptedSessionFixture` now creates and exposes its `InMemoryRecorder`.

    Three corrections to the RED file itself, none behavioral: two missing `await`s on the actor-isolated `streamEvents(to:)` (compile fix), and the expected recorded-kinds list gained `.instructions` — the post-turn diff has always recorded the SDK's instructions entry (the same shape `ScriptedToolTurnComparisonTests` asserts on the raw transcript), the RED expectation had mis-enumerated the fixture's shape. The exact-equality assertion is unchanged in strength and still proves no invocation record reaches the recorder.

    Not committed; task left in `doing` for review.

    ### implement — changed
    - evidence: 16 files — 2 new (Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift), 14 edited (Sources/FoundationModelsRouter/Hosting/OperationEventSink.swift, Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Sources/FoundationModelsRouter/Session/SessionEvent.swift, Sources/FoundationModelsRouter/Session/OperationEventJournal.swift, Sources/FoundationModelsRouter/Session/SessionOutbox.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Sources/FoundationModelsRouter/Session/SessionProjection.swift, Examples/CompactionDemo/main.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedSessionFixture.swift, Tests/FoundationModelsRouterTests/ScriptedToolTurnComparisonTests.swift, Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift); `swift test` 841/841 + 27 + 24 passed, 1 accepted known issue (BoundedWait)
    - next: `/review`
  timestamp: 2026-08-12T01:49:28.529562+00:00
- actor: claude-code
  id: 01kzstygpbvcx6yqf5fysyh2fy
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 16 validator runs, 0 failed
    - next: none. The task is complete and is in the done column.
  timestamp: 2026-08-12T01:56:17.227293+00:00
- actor: claude-code
  id: 01kzstz6q0r31emgx22x1xbc46
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 16 files (2 new), RED to GREEN
    - test: green — swift test, 841 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 14ae079
    - review: clean — 0 findings, scope HEAD~1..HEAD
    - result: the task is in done
  timestamp: 2026-08-12T01:56:39.776294+00:00
depends_on:
- 01KZPW9RY91W2KAMGY3W8DZVEE
position_column: done
position_ordinal: ff8f80
title: Stream tool and reasoning events live during the turn, not after it
---
## Problem

A turn's tool and reasoning events are not live. The backend seam streams text only: `ResponseFragment` is the whole mid-turn vocabulary (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift:102). `SessionEvent.toolCall`, `.toolStatus`, and `.reasoningDelta` are synthesized after generation finishes, when the turn's snapshot diff runs — `SessionProjection`'s own doc states this (Sources/FoundationModelsRouter/Session/SessionProjection.swift:42-48). A UI therefore shows "running tool" only after the whole turn is over. On a local model, a tool turn can take many seconds; the user watches a spinner with no truth in it.

This is about WHEN events arrive. Task ^w8dzvee is about WHAT the stream says (the textReset invariant); the two are separate.

## Proposed solution

The tool half needs no polling: the per-call `ToolContext` binding layers already observe the true invocation moment. `DetachingTool` (String-output tools) and `ContextBindingTool` (the rest) bind a stamped context — tool name, op, sessionID, per-call correlationID — around each call and hold the session's event sink (Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:361-372, :811-822).

1. Emit a typed invocation record from the binding layer: opened-at when the binding opens, closed-at and duration when the wrapped call returns, carrying tool, op, correlationID, and sessionID. Post it through the sink the binding already holds — the same route operation events take.
2. The session actor translates those records into live `SessionEvent.toolCall` / `.toolStatus` deliveries on the current turn's stream, using the same ids the post-turn diff will confirm. The diff stays the authority for what is RECORDED; the live records only accelerate delivery. If the diff and the live records disagree, the diff wins.
3. Reasoning and text-restart liveness stays on the fragment stream (`ResponseFragment`); widen it only if the backend can report reasoning deltas directly.
4. Emission-order guarantee: a `.toolCall` event arrives before its `.toolStatus(completed)`, and both before `turnEnded`. Consumers need no changes — `SessionProjection.apply(_:)` already handles the vocabulary.
5. Surface the invocation records (with timing) to `TurnOutcome` (task ^1s8p8qt), so a caller gets per-call durations without touching the event stream.

## Acceptance

- A scripted tool-using turn delivers `.toolCall` before the tool's own work completes (test with a slow scripted tool: assert the event arrives while the tool is still running).
- The recorded transcript for that turn is byte-identical to what the post-turn diff alone would have recorded.
- Each invocation record carries opened-at, closed-at, and duration, and reaches `TurnOutcome`.
- The stub-backend default (text-only) keeps working unchanged. #streaming
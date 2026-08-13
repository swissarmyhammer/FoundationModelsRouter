---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzwtxgdf812fhm5hhw4rarhk
  text: |-
    Research results:

    - `RoutedSessionActor` is internal. Only the `RoutedSession` protocol is public. Thus the two properties can move off the protocol, and the actor keeps them as internal stored properties.
    - All queue and elicitation methods live in `extension RoutedSession` today. They read `outbox`/`mailbox` through the protocol requirements. Plan: make these methods protocol requirements. Move the bodies to a new internal actor extension file.
    - The `dispatchNextPrompt()` doc shows a driver loop that calls `session.outbox.nextEvent()`. External drivers need this wake-up signal. Plan: add one new typed capability `awaitQueuedWork()` to the protocol. It delegates to `SessionOutbox.nextEvent()`.
    - Sources that touch `.outbox`/`.mailbox`: only RoutedSession.swift, RoutedSessionActor*.swift (internal), ToolContext.swift and DetachingTool.swift (own stored copies, injected at construction).
    - `ToolContext.mailbox` is public. Tools do not need it: `elicit(_:)` covers the capability. Plan: make it internal.
    - Tests: 16 files in FoundationModelsRouterTests touch `.outbox`/`.mailbox` (~148 sites) through `RoutedSession` existentials, all with `@testable`. Plan: one test-target extension on `RoutedSession` that casts to `RoutedSessionActor` keeps all sites unchanged.
    - Plain-import targets (IntegrationTests support, Evals, TestSupport, Examples) use none of the members that go internal. PropagationProbeIntegrationTests builds a `ToolContext` with `SessionMailbox()` + `makeCompletionToken()`, but it imports with `@testable`.
    - `SessionOutbox.post(_:)`/`post(invocation:)` must stay public: they witness the public `OperationEventSink` protocol on a public actor.
    - Public signatures keep these vocabulary types public: `SessionOutbox.ItemID`, `.PromptQueueMutationResult`, `.QueueDepth`, `SessionMailbox.ElicitationAnswerDelivery`, `.ElicitationCompletionDelivery`.
    - No DocC catalog exists yet. Plan: create `Sources/FoundationModelsRouter/FoundationModelsRouter.docc` with topic-group extension pages by audience.
  timestamp: 2026-08-13T05:53:27.471062+00:00
- actor: claude-code
  id: 01kzxectme2104f8bq7xd5d3wr
  text: |-
    ## Audit table — `RoutedSession` public members

    Bins: **app** = app-facing capability (stays public), **tool** = tool-facing capability already served by `ToolContext` (raw member goes internal), **wiring** = internal wiring (goes internal; tests use `@testable`).

    | Member | Bin | Reason |
    | --- | --- | --- |
    | `profile` | app | The resolved profile the session runs against. An app reads it to see the models. |
    | `routerId` | app | Recording-root identity. An app uses it to find the transcript tree. |
    | `id` | app | The session span id. An app keys its own state on it. |
    | `parentId` | app | Fork lineage. An app shows the tree. |
    | `recordingDirectory` | app | Where the transcript is. An app reads and archives it. |
    | `workingDirectory` | app | Where model and tool work runs. An app sets and reads it. |
    | `grammar` | app | Tells an app if the session is guided. |
    | `contextFill` | app | The proactive-compaction signal an app reads between turns. |
    | `transcript` | app | Read-only history (task ^5aky6xr). An app seeds a `SessionProjection` with it. |
    | `respond(to:)`, `respond(to:maxTokens:)` | app | The conversation entry points. |
    | `streamResponse(to:)`, `streamResponse(to:maxTokens:)` | app | The conversation entry points. |
    | `streamEvents(to:)`, `streamEvents(to:maxTokens:)` | app | The conversation entry points. |
    | `streamSessionEvents()` | app | The session-scoped observation route. |
    | `compact()`, `compact(prompt:)`, `compact(budget:)`, `compact(prompt:budget:)` | app | Caller-driven folding. |
    | `enqueue(prompt:)` (both) | app | Queueing, as the card requires. |
    | `pendingPrompts()` | app | Queue inspection. |
    | `cancel(id:)`, `replace(id:prompt:)` | app | Queue mutation. |
    | `promptQueueDepth()` | app | Backlog reading. |
    | `dispatchNextPrompt()` | app | The driver pull surface. |
    | `awaitQueuedWork()` | app | **New typed capability.** See "Missing capability" below. |
    | `cancelCurrentTurn()`, `cancelPrompt(id:)` | app | Cancellation. |
    | `awaitingUser(_:)` | app | Releases the generation gate for a wait on a person. |
    | `fork(workingDirectory:)`, `close()` | app | Lifetime boundaries. |
    | `outbox` | wiring | **Now internal.** The staging area itself. An app drives the queue through the typed methods above; a tool posts through `ToolContext`. No external consumer keeps it. |
    | `mailbox` | wiring | **Now internal.** The parked-run and elicitation registry. An app answers through `respond(elicitationId:response:)` / `complete(elicitationId:)`; a tool asks through `ToolContext.elicit(_:)`. No external consumer keeps it. |

    ## Missing capability that the subtraction made necessary

    `dispatchNextPrompt()`'s documented driver loop told a caller to await
    `session.outbox.nextEvent()`. That is a genuine app need — the idle wake-up —
    so the raw property was not simply deleted. Rule 3 of the card applies: a new
    typed capability `RoutedSession.awaitQueuedWork()` now covers it, and it
    delegates to `SessionOutbox.nextEvent()` internally. The loop in the doc
    comment and in `plan.md` names the new capability.

    ## Audit table — `SessionOutbox` own public API

    | Member | Bin | Reason |
    | --- | --- | --- |
    | `SessionOutbox` (the actor) | app | Named in public signatures through its nested vocabulary types. |
    | `ItemID` (+ `description`) | app | The return type of `enqueue`, and a field of `TurnStart.promptId`. |
    | `PromptQueueMutationResult` | app | The return type of `RoutedSession.cancel(id:)` / `replace(id:prompt:)`. |
    | `QueueDepth` (+ `queued`, `dispatched`, `total`, `init`) | app | The return type of `promptQueueDepth()`. |
    | `post(_:)`, `post(invocation:)` | tool | The `OperationEventSink` conformance the binding layers post through. A tool never calls it directly; it must stay public because the protocol it witnesses is public. |
    | `init()` | wiring | Now internal. Only session construction (vend, fork, restore) mints one. |
    | `PendingEvent`, `PendingPrompt`, `Pending` | wiring | Now internal. Staging snapshots. |
    | `enqueue(prompt:)`, `cancel(id:)`, `replace(id:prompt:)` | wiring | Now internal. The session's typed methods forward to these. |
    | `pending()`, `queueDepth()`, `drainPendingEvents()`, `nextEvent()` | wiring | Now internal. Same reason. |
    | `drainForDispatch()`, `finishDispatch()`, `attach(...)`, `requeue(...)`, `journalWithoutStaging(...)`, `Drained` | wiring | Already internal before this task. |

    ## Audit table — `SessionMailbox` own public API

    | Member | Bin | Reason |
    | --- | --- | --- |
    | `SessionMailbox` (the actor) | app | The public `ToolContext.init(...)` takes one, so a host that binds its own tool context names the type. |
    | `init()` | app | **Kept public with a concrete consumer:** the public `ToolContext` initializers take a `mailbox:`. A host that binds its own context must be able to make one. |
    | `makeCompletionToken()` | app | Same consumer: the host must mint the `completionToken` the binding takes. |
    | `respond(elicitationId:_:)`, `complete(elicitationId:)` | app | Answer delivery for a hand-bound tool's elicitation. |
    | `ElicitationAnswerDelivery`, `ElicitationCompletionDelivery` | app | The return types of the two methods above and of the session's own answer methods. |
    | `RunKind`, `RunStatus`, `WaitResult`, `CancelResult`, `ParkResult` | wiring | Now internal. Run-plane vocabulary the detachment engine owns. |
    | `park(...)`, `wait(...)`, `cancel(...)`, `status()`, `updateProgress(...)`, `awaitAnswer(...)`, `pendingElicitationIds()`, `sweep()` | wiring | Now internal. `DetachingTool` and `RoutedSessionActor` drive them. |
    | `terminalDetailTailLimit`, `settledTerminalEventRetentionLimit`, `waitSecondsCeiling` | wiring | Now internal. Bounds the mechanism applies to itself. |

    ## `ToolContext.mailbox`

    Bin: **tool**. Now internal. A tool reaches elicitation through the typed
    `ToolContext.elicit(_:)` capability, never through the raw mailbox. The binder
    supplies the mailbox at construction and keeps its own reference.

    ## Acceptance

    - `outbox` and `mailbox` are no longer public on `RoutedSession`.
    - Every existing test passes through `ToolContext` and the typed methods. The
      unit suite reads the two mechanisms through one `@testable` extension
      (`Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift`),
      so no test asserts against a public surface that is now internal.
    - The public surface is recorded in the new DocC catalog with topic groups by
      audience: `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md`.
  timestamp: 2026-08-13T11:33:52.398272+00:00
- actor: claude-code
  id: 01kzxed5pv27h0thzw2zwnwsrf
  text: |-
    Implementation notes for the next agent:

    - The two properties left the `RoutedSession` protocol, so every method that
      read them had to leave the protocol extension too. The queue and elicitation
      methods are now protocol *requirements*, and their bodies moved to a new
      internal actor extension:
      `Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift`.
      Those bodies are `nonisolated` — the mechanism actors do their own
      serialization, so nothing needs the session actor's isolation.
    - The test-target extension must be `nonisolated`. A plain `var` on an
      `extension RoutedSession` inherits the actor's isolation, and the compiler
      refuses the access from outside the actor even though the stored properties
      are `nonisolated let`. This failed first with "actor-isolated property
      'outbox' cannot be accessed from outside of the actor" across many test
      files; `nonisolated var` fixed all of them.
    - The DocC catalog needs `exclude:` in `Package.swift`. Without it, `swift
      build` warns "found 1 file(s) which are unhandled" — the Swift Build backend
      does not consume a `.docc` directory as build input.
    - `SessionOutbox.post(_:)` and `post(invocation:)` must stay public: they
      witness the public `OperationEventSink` protocol on a public actor. Making
      them internal does not compile.
    - `SessionMailbox.init()` and `makeCompletionToken()` must stay public: the
      public `ToolContext` initializers take a `mailbox:` and a `completionToken:`,
      so a host that binds its own tool context needs both. This is the one place
      the audit kept a mechanism public, and the reason is recorded in the audit
      table and in the type's own doc comment.
  timestamp: 2026-08-13T11:34:03.739218+00:00
- actor: claude-code
  id: 01kzxedet2fcxkqxzd19fwxmrj
  text: |-
    ### implement — changed
    - evidence: one bare ungated `swift test` run — 924 tests in 87 suites passed (1 known issue, the pre-existing `BoundedWait` never-holds probe), 27 tests in 11 suites passed, 24 tests in 5 suites passed; 975 tests total, zero failures. `swift build --build-tests` is clean, zero errors and zero warnings from this package.
    - files: 14 changed — `Package.swift`; `Sources/FoundationModelsRouter/Session/RoutedSession.swift`, `.../Session/RoutedSessionActor.swift`, `.../Session/RoutedSessionActorForking.swift`, `.../Session/SessionOutbox.swift`, `.../Hosting/SessionMailbox.swift`, `.../Hosting/ToolContext.swift`, `.../Recording/SessionTreeRestoration.swift`, `.../RoutedLLM.swift`; new `.../Session/RoutedSessionActorQueueing.swift`; new `.../FoundationModelsRouter.docc/RoutedSession.md`; `Tests/FoundationModelsRouterTests/PromptQueueTests.swift`; new `Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift`; `plan.md`.
    - next: ready for `/review`. The task stays in `doing`.
  timestamp: 2026-08-13T11:34:13.058388+00:00
- actor: claude-code
  id: 01kzxf1hw37yysa9zgee5gezxv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 0410871) — 0 findings, 0 confirmed, 8 refuted, 24 attempted, 0 failed, 0 skipped. No prior `## Review Findings` section on the card.
    - next: the card moves to `done`.
  timestamp: 2026-08-13T11:45:11.555163+00:00
- actor: claude-code
  id: 01kzxf1xrgz1122agndy8xa778
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 14 files; one bare ungated `swift test` run: 975 tests, 0 failures
    - commit: 0410871 — 18 files
    - review: clean — 0 findings (24 checks attempted, 8 candidates refuted)
    - next: none — task is done
  timestamp: 2026-08-13T11:45:23.728845+00:00
position_column: done
position_ordinal: ffa380
title: 'Audit the session plumbing surface: capabilities stay, mechanisms go internal'
---
## Problem

`RoutedSession` publicly exposes its raw plumbing — `outbox` and `mailbox` (Sources/FoundationModelsRouter/Session/RoutedSession.swift:101, :110) — even though neither audience needs the mechanism:

- **Tools** reach every capability ambiently through the per-call `ToolContext` binding (post events, `elicit(_:)`, `isCancelled`, correlation identity). A tool never touches `session.outbox`.
- **Apps** have typed methods for their side: `streamSessionEvents()` to observe operation events, `respond(elicitationId:response:)` / `complete(elicitationId:)` to answer elicitations, `dispatchNextPrompt()` for the queue.

The public properties exist for internal wiring (fork composition, restoration seeding) and for tests. They are the members that make the protocol read as a twenty-member god-surface. This task replaces the namespacing/partition discussion: subtract instead.

## Proposed solution

1. Audit every public member of `RoutedSession` (and `SessionOutbox`/`SessionMailbox`'s own public API) and sort each into one of three bins: app-facing capability (stays public, with a doc stating its audience), tool-facing capability (already served by `ToolContext` — the raw member goes internal), or internal wiring (goes internal; tests use `@testable`).
2. Expected outcome, to verify during the audit: `outbox` and `mailbox` go internal; identity (`id`, `parentId`, `routerId`, `recordingDirectory`, `workingDirectory`), conversation methods, queueing (`dispatchNextPrompt`, prompt enqueue), elicitation answers, `cancelCurrentTurn`, `awaitingUser`, `fork`, `close`, `compact`, and `contextFill` stay.
3. Where an external consumer genuinely needs a raw mechanism, do not keep the property — add the missing typed capability and record why.
4. Record the resulting public surface in the DocC catalog with topic groups by audience (the free documentation partition), so the shrunken protocol also reads as organized.

## Acceptance

- `outbox` and `mailbox` are no longer public on `RoutedSession`, or the audit documents the concrete external consumer that keeps each public.
- Tools and apps pass every existing test through `ToolContext` and the typed methods alone.
- The audit table (member, bin, reason) lands in the task comments or the DocC article. #api
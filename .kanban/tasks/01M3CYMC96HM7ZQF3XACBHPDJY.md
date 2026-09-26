---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3dwqr65hm63a4x6mdtrej2v
  text: |-
    Picked up. Research done at HEAD 0da7081.

    What holds now:
    - `SessionOutbox` has three lists: mail (`events`), caller messages (`messages`, which the pump takes), and queued prompts (`prompts`, which wait for `dispatchNextPrompt()` to release them). `dispatched` tracks released prompt ids for `PromptQueueDepth`.
    - `dispatchNextPrompt()` releases the front prompt (`releaseFrontPrompt`), or with no prompt ends the mail hold (`releaseHeldMail`) and waits for the pump to be idle (`awaitPumpIdle`, `PumpIdleWaiter`, `pumpIdleWaiters`, `mailReply`). Only these two paths use the idle waiters and `releaseHeldMail`.
    - `awaitQueuedWork()` is `outbox.nextEvent()`; only it uses `nextEvent`/`wakeups`.
    - `cancelCurrentTurn()` holds the mail, cancels the running work and withdraws the waiting caller messages. `cancelPrompt(id:)` is an extension over `cancel(id:)` + `promptQueueDepth()` + `cancelCurrentTurn()`.
    - `TurnStart.promptId` (internal field) names only a `.dispatch` message. `RouterTracing.TurnEntryPoint.dispatch` covers a released prompt and a mail-only answer.
    - No IntegrationTests file and no Examples file uses a removed symbol (`rg`). Tests that use them: PromptQueueTests (86 refs), TurnCancellationTests (40), SessionOutboxTests (10), RoutedSessionPublicSurfaceTests (11), DiscoveryPrimingTests, TurnTracingTests, SessionOutboxToolWiringTests, RoutedSessionToolContextBindingTests, NestedGenerationReentryTests, RespondRunPlaneDrainTests, SessionMessagePumpTests, PromptTextFlatteningTests, TurnFrameAssertions, ToolResultCompactionModel.

    Plan decisions (names decided here, reasons in the landing comment): `send` adds a caller message to the outbox and wakes the pump; there is one message list, so `pendingMessages()` lists every waiting caller message (`send`, `respond`, stream); the actor keeps a registry of the open messages so `cancel(message:)` can tell a message the pump took (not yet in its work) from an answered one.
  timestamp: 2026-09-26T03:39:26.789669+00:00
- actor: claude-code
  id: 01m3dxz8310f3tyqn3cswre5ma
  text: |-
    ### Decisions (implement)

    - `cancel(message:)` has no lock. The actor keeps `openMessages` (id to answer) for each message that has no answer. Not in the registry: `.alreadyAnswered`. In the running answer: stop that work, `.cancelledInSubmission`. Waiting: set the cancel mark of the answer in the same actor turn, then remove the message from the outbox, `.withdrawn`. The pump reads the marks in `liveMessages` with no suspension point before it sets the running work. Thus a message that the pump took at the same time is dropped, and never reaches a prompt. Reason: a race-free result with no wait on a permission.
    - `PromptQueueMutationResult` became `MessageQueueMutationResult` (`.applied`, `.alreadySent`). Reason: one name family for the message queue.
    - `MessageQueueDepth` has `waiting` (count), `running` (the `MessageID`s of the running answer) and `total`. Reason: the task text.
    - Tracing: `TurnEntryPoint.dispatch` became `.send` ("send"), and an answer that only mail started uses `.mail` ("mail"). The span and attribute names stay; task ^x7cxsg3 renames them.
    - `TurnStart.promptId` became internal `messageId: MessageID?`: the id of the first message of the submission that came from `send`. It is `nil` for `respond`, the stream helpers and mail. ^x7cxsg3 replaces `TurnStart`.
    - `send(_:)` runs no refusal of a wait inside an open submission, because it does not wait. A tool of the same session can call it. The helpers that wait keep the refusal.
    - `send(_ prompt: String)` is a public extension member that calls `send(.plainText(prompt))`. `Transcript.Prompt.plainText(_:)` is internal.
    - The outbox lost its driver wait (`nextEvent`, `releaseHeldMail`, the prompt list). The old `nextEvent()` tests are restated as mail-observer tests in `SessionOutboxTests`.
    - `generation-queue.md` 5.3: one sentence records that `dispatchNextPrompt()` is gone and that `send` runs no refusal.
    - Restated tests (not deleted): `PromptQueueTests` became `MessageQueueTests`; `TurnCancellationTests` (a sent message cancelled in its submission; a withdrawal behind a busy submission); `RoutedSessionPublicSurfaceTests` (send and `.alreadyAnswered`: a withdrawal needs a busy session, and the internal suites prove it); `TurnTracingTests` (entry point "send"); `DiscoveryPrimingTests` (send); `SessionOutboxToolWiringTests` (respond in place of enqueue plus dispatch).
  timestamp: 2026-09-26T04:01:01.025112+00:00
- actor: claude-code
  id: 01m3dxzbnpsydvh7ydke77bs3b
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Session (MessageQueue.swift from PromptQueue.swift, RoutedSession.swift, RoutedSessionActor*.swift, SessionOutbox.swift, SessionMessage.swift, TurnIdentity.swift), Tracing/RouterTracing.swift, RoutedSession.md DocC, generation-queue.md; new Tests/FoundationModelsRouterPublicSurfaceTests/MessageQueuePublicSurfaceTests.swift; MessageQueueTests.swift from PromptQueueTests.swift; restated tests in 14 more test files. Full recompile: 0 code warnings. `swift test`: 1445 + 7 + 19 = 1471 passed. Session, pump, outbox, message-queue, cancellation, tracing and public-surface suites (150 tests) with `--parallel`: 20 of 20 runs passed. IntegrationTests `swift build --build-tests`: clean. `rg` of the removed names in Sources: nothing.
    - next: review
  timestamp: 2026-09-26T04:01:04.694506+00:00
- actor: claude-code
  id: 01m3dzhzx5vqfbz8rchxxk88k7
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD. 2 findings (2 confirmed, 0 refuted): Sources/FoundationModelsRouter/Session/TurnIdentity.swift:53, Sources/FoundationModelsRouter/Session/TurnIdentity.swift:60 (swift/access-control).
    - next: Implement the 2 findings in the dated Review Findings section. Then run the review again. The task stays in review.
  timestamp: 2026-09-26T04:28:43.813993+00:00
- actor: claude-code
  id: 01m3dzkjgvxr6yd38mwf1syje1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 25 files (send, MessageID, cancel(), cancel(message:); removed dispatchNextPrompt, cancelCurrentTurn and others)
    - test: green — swift test, 1471 passed (1445+7+19), 0 failed, 0 skipped; 8 session and queue suites 3 extra runs clean; Examples and IntegrationTests build clean
    - commit: c02325d
    - review: findings — Session/TurnIdentity.swift:53, Session/TurnIdentity.swift:60
  timestamp: 2026-09-26T04:29:35.643280+00:00
- actor: claude-code
  id: 01m3dzp2s21f31k2jq50s0659r
  text: |-
    Pulled back to doing for the 2 review findings (TurnIdentity.swift: `messageId` and `init` of `TurnStart` are internal).

    Research:
    - `TurnIdentity.swift` has two public types. `TurnID` has `private let value`, an explicit and documented `internal init` (only the pump mints a turn id), and `public var description`. It has no access-control gap. `TurnStart` has `public let turnId`, and an implicit internal `messageId` and `init`. These two are the gap.
    - The only caller of `TurnStart.init` is `RoutedSessionActorTurnExecution.swift` (`emit(.turnStarted(...))`). A wider access level changes no caller.
    - The public-surface target links only the library. A consumer cannot mint a `TurnID` or a `MessageID`, so a test in that target cannot build a real `TurnStart` value at run time. The proof is at compile time: the new test binds `TurnStart.init(turnId:messageId:)` and the `\TurnStart.messageId` key path over a plain import, and it asserts that the key path is read-only for a consumer.
  timestamp: 2026-09-26T04:30:57.826738+00:00
- actor: claude-code
  id: 01m3dzs6c9b1g34z1nqga0921m
  text: |-
    ### implement — changed
    - evidence: `Sources/FoundationModelsRouter/Session/TurnIdentity.swift` (`TurnStart.messageId` and `TurnStart.init(turnId:messageId:)` are now `public`; the init doc tells why a consumer calls it). `TurnID` has no gap: its `internal init` is explicit and deliberate. New `Tests/FoundationModelsRouterPublicSurfaceTests/TurnStartPublicSurfaceTests.swift` (plain import: it reads `messageId`, binds and calls the init, and asserts the key path is read-only). RED: the new file did not compile ("'messageId' is inaccessible due to 'internal' protection level", "'TurnStart' initializer is inaccessible"). GREEN: `swift test --filter TurnStartPublicSurfaceTests` 1 passed. Full `swift test`: 1445 + 8 + 19 = 1472 passed, 0 failed, 0 code warnings (the 2 known issues are the existing `withKnownIssue` in BoundedWaitTests and RealModelHarnessTests). Both findings flipped to `- [x]`.
    - next: review
  timestamp: 2026-09-26T04:32:39.817517+00:00
depends_on:
- 01M3CYK7FSPBXGC7NWD3QX0MPT
position_column: doing
position_ordinal: '80'
title: 'Public message API: send a message, name it by MessageID, cancel with cancel()'
---
## Why

After task ^3qx0mpt, a session is a message queue with one pump. The public API still speaks of turns and of an external driver: `enqueue(prompt:)` returns a `PromptID`, a driver calls `awaitQueuedWork()` and `dispatchNextPrompt()`, and `cancelCurrentTurn()` returns `TurnCancellationResult`. The user decided on 2026-09-25 that `respond(prompt)` "is only a helper: it sends a prompt and waits for the next final answer", and that no lock and no turn is visible in the API. Breaking the consumers is acceptable (user decision 2026-09-24). Design: `generation-queue.md`, sections 5.4, 5.6 and 5.10.

## What to do

1. Add `send(_ prompt: Transcript.Prompt) async -> MessageID` and `send(_ prompt: String)`. `send` returns when the message is in the outbox. It never waits for a submission and never throws a lock or turn error, from any task, also from a tool of the same session.
2. Rename `PromptID` to `MessageID`. `pendingPrompts()` becomes `pendingMessages()`, `replace(id:prompt:)` keeps its meaning on a waiting message, and `PromptQueueDepth` becomes `MessageQueueDepth` (waiting count, and the ids of the running submission).
3. `respond(to:maxTokens:)`, `streamResponse(to:maxTokens:)` and `streamEvents(to:maxTokens:)` stay as helpers: send, then wait for (or stream until) the answer of that message.
4. Remove `dispatchNextPrompt()` and `awaitQueuedWork()`: the pump delivers each message and each settled run by itself.
5. Replace `cancelCurrentTurn() -> TurnCancellationResult` with `cancel() -> CancellationResult` (`.requested`, `.nothingToCancel`), and `cancel(id:)` / `cancelPrompt(id:)` with `cancel(message:) -> MessageCancellationResult` (`.withdrawn` for a waiting message, `.cancelledInSubmission` for a message whose submission runs, `.alreadyAnswered`).
6. Update the DocC of `RoutedSession` and the public-surface tests.

## Acceptance Criteria

- [x] A test: `send` from a tool of the same session, during its submission, returns a `MessageID` at once, and the message is in the prompt of the next submission. <!-- NestedGenerationReentryTests.aToolBodyThatSendsToItsOwnSessionGetsAMessageIDAtOnce -->
- [x] A test: `send` on an idle session starts a submission with no other call. <!-- SessionMessagePumpTests.aSendOnAnIdleSessionStartsASubmission; also MessageQueueTests.sendReturnsBeforeItsAnswer -->
- [x] A test: `cancel(message:)` returns `.withdrawn` for a waiting message (it never reaches a prompt) and `.cancelledInSubmission` for a message whose submission runs. <!-- SessionMessagePumpTests.cancelOfAWaitingMessageWithdrawsIt, SessionMessagePumpTests.cancelOfAMessageInARunningSubmissionStopsIt -->
- [x] A public-surface test compiles against `send`, `MessageID`, `cancel()`, `cancel(message:)` over a plain import. <!-- Tests/FoundationModelsRouterPublicSurfaceTests/MessageQueuePublicSurfaceTests.swift; also RoutedSessionPublicSurfaceTests -->
- [x] `rg -n "dispatchNextPrompt|awaitQueuedWork|PromptID|cancelCurrentTurn|TurnCancellationResult" Sources` finds nothing. <!-- rg exit 1 -->
- [x] Full `swift test` green, 0 new warnings. <!-- swift test: 1445 + 7 + 19 = 1471 passed, after a full recompile with 0 code warnings -->

#generation-queue

## Review Findings (2026-09-25 23:10)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 37 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Session/PromptQueue.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/PromptQueueTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Session/PromptQueue.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/PromptQueueTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Session/PromptQueue.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/PromptQueueTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Session/PromptQueue.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/PromptQueueTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Session/PromptQueue.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/PromptQueueTests.swift, so its declarations are unread

- [x] `Sources/FoundationModelsRouter/Session/TurnIdentity.swift:53` `swift/access-control` — Public struct property lacks `public` access modifier. The property defaults to `internal`, making it inaccessible from outside the module, while the sibling property `turnId` is explicitly marked `public`. This is inconsistent with the struct's public API contract. Change to `public let messageId: MessageID?`.
- [x] `Sources/FoundationModelsRouter/Session/TurnIdentity.swift:60` `swift/access-control` — Custom initializer of a public struct lacks `public` access modifier. The init defaults to `internal`, making the struct impossible to instantiate from outside the module, which defeats the purpose of a public struct. Change to `public init(turnId: TurnID, messageId: MessageID?)`.
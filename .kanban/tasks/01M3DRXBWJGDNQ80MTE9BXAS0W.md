---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ez78cjyza71rhn4fmqbnqp
  text: |-
    Research (implement step).
    - The pump is `RoutedSessionActorPump.swift`. `runNextAnswer()` takes a batch with `SessionOutbox.takeSubmissionBatch(deliveringRunsOf:)`; `runAnswer(of:settledRunTokens:)` runs the answer. An answer with no live caller message is a mail-only answer (its prompt is `settledRunDeliveryPrompt`).
    - The outbox already has a per-event hold (`PendingEvent.isHeld`). A held terminal starts no submission by itself; the next submission that a caller message starts takes it with the other mail. So the bound can use the hold: the mail stays in the outbox and is not lost.
    - A caller message can also join a mail-only answer through a continuation (`takeMessagesJoiningTheAnswer()`). Thus the count must reset from the messages that the answer delivered (`deliveredMessages`), not only from the first batch.
    - Between answers `currentAnswerEventSink` is nil, so an event from the pump goes out through `emitSessionScopedEvent(_:)` to `streamSessionEvents()`.
    - `SessionEvent` has exhaustive switches in `SessionProjection.apply`, `SessionAnswerReducer`, `ScriptedToolAnswerComparisonTests`, `IntegrationTests/.../RealToolAnswerComparisonTests` and `Examples/MultiModelGeneration/main.swift`. Each needs the new case.
    - Configuration pattern: `RepetitionDetection` (^1hcwaqy) is a `SessionConfiguration` field, stored on the actor, written to the sidecar envelope as an optional field (nil in an old sidecar gives the default), inherited by a fork and applied again on restore. The new limit follows the same path.
  timestamp: 2026-09-26T13:42:06.482479+00:00
- actor: claude-code
  id: 01m3ezxbfpbpygwembc4jw7grs
  text: |-
    ## Decision: a bound in the pump

    "Mail causes the next submission" is correct behavior. A short chain of mail-only answers is normal. An endless chain is a defect only at the extreme: it uses the model with no end, and no caller asked for it. Thus the session model stays the same (a transcript plus a queue of messages, no locks, no "turn"), and the pump gets a safety bound.

    - **Where:** the pump (`RoutedSessionActorPump.runAnswer`). The actor counts consecutive mail-only answers since the last caller message (`mailOnlyAnswersInARow`). An answer that delivers a caller message sets the count to 0.
    - **Name:** `SessionConfiguration.mailOnlyAnswerLimit`. The default is `SessionConfiguration.defaultMailOnlyAnswerLimit` (100). The value is generous: a real agent loop with 100 mail-only answers and no caller message is not normal, but a long normal chain is not stopped.
    - **At the limit:** the pump starts no submission. It puts the mail back in the outbox as held mail (`SessionOutbox.putBack(holding:)`). The mail is not lost. It rides the next caller message, as all held mail does.
    - **Report:** one `SessionEvent.mailDeliveryPaused(MailDeliveryPause)` on `streamSessionEvents()` for each hold, and one notice log line in the category `MailDelivery`. `MailDeliveryPause` gives the limit and the held mail.
    - **0** holds all mail until a caller message. A negative value acts as 0.
    - **Persistence:** the sidecar keeps the value (an optional field; an old sidecar restores with the default). A fork inherits it, and a restore applies it again.
    - **Surface:** the setting is reached through `SessionConfiguration` only. The flat `makeSession(instructions:...)` has no new parameter, because it is a small common surface and 13 DocC selector references name it. `makeGuidedSession` is the precedent for a surface that does not carry every field.

    Documented in `generation-queue.md` 5.4 and in `RoutedSession.md`.
  timestamp: 2026-09-26T13:54:10.550365+00:00
- actor: claude-code
  id: 01m3ezxf7ajmj51medvz6k5bq4
  text: |-
    ### implement — changed

    - Source: SessionConfiguration.swift, MailDeliveryPause.swift (new), SessionEvent.swift, SessionOutbox.swift, RoutedSessionActorPump.swift, RoutedSessionActor.swift, RoutedSessionActorForking.swift, SessionTreeRestoration.swift, RoutedLLM.swift, SessionProjection.swift, SessionAnswer.swift, Examples/MultiModelGeneration/main.swift.
    - Docs: RoutedSession.md, generation-queue.md 5.4.
    - Tests: MailOnlyAnswerLimitTests (new, 8 tests), MailDeliveryPausePublicSurfaceTests (new, 2 tests), SessionProjectionTests, SessionAnswerTests, SessionTreeRestorationTests, ScriptedToolAnswerComparisonTests, IntegrationTests RealToolAnswerComparisonTests.
    - RED: a mutation that disabled the bound made the 4 behavior tests fail. The mutation is reverted.
    - `swift test`: 1486 + 17 + 19 = 1522 passed (before: 1509). The 2 known issues were there before.
    - IntegrationTests package: build complete.
    - Stress: MailOnlyAnswerLimitTests, 8 processes × 100 repetitions, 0 issues.
  timestamp: 2026-09-26T13:54:14.378976+00:00
- actor: claude-code
  id: 01m3f0nrzqcw3zgcdyhdr18w7y
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 88f6bfd). 2 findings, 2 confirmed, 0 refuted. Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:112, Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:963
    - next: Correct the 2 open items in "Review Findings (2026-09-26 09:00)". Then do a review again. The task stays in review.
  timestamp: 2026-09-26T14:07:30.807838+00:00
- actor: claude-code
  id: 01m3f0qdz2qj5mdftc68vv11n8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 20 files (mailOnlyAnswerLimit, default 100; mailDeliveryPaused event; held mail rides the next caller message)
    - test: green — swift test, 1522 passed (1486+17+19), 0 failed, 0 skipped; 6 pump and session suites 3 extra runs clean; build with warnings-as-errors clean
    - commit: 88f6bfd
    - review: findings — MailOnlyAnswerLimitTests.swift:112, SessionTreeRestorationTests.swift:963
  timestamp: 2026-09-26T14:08:25.058848+00:00
- actor: claude-code
  id: 01m3f0sx8cws8sfbfryzmxwj4j
  text: |-
    Research (implement step, review findings 2026-09-26 09:00).
    - Finding 1: `RunStartingContainer` holds only `Sendable` stored properties: `let tokenCounter: any TokenCounter` (the protocol is `Sendable`), `let runStartingCalls: Int?` and `let vended: Mutex<RunStartingBackend?>`. `RunStartingBackend` conforms to `LanguageModelSessionBackend`, which is `AnyObject, Sendable`, and keeps its counter in a `Mutex`. Thus a checked `Sendable` conformance compiles with no unchecked claim. `SettledTranscriptTests.HeldSubmissionContainer` is the precedent (a final class, `LoadedLLMContainer, Sendable`, state in a `Mutex`). The file has no other `@unchecked Sendable`.
    - Finding 2: plan is a shared helper that takes the configuration, the expected value and a closure that reads the setting from a `RoutedSessionActor`. The two `@Test` functions stay, so the test count and the task references in their names stay the same. `repetitionDetection` and `mailOnlyAnswerLimit` are `nonisolated let` on the actor, so a synchronous read closure is correct. The helper passes `sourceLocation` to each assertion, as `ResolutionProgressPublicSurfaceTests` does.
  timestamp: 2026-09-26T14:09:46.252060+00:00
- actor: claude-code
  id: 01m3f0xhdkhrfd43xm0pknf5wj
  text: |-
    ### implement — changed
    - Finding 1 (MailOnlyAnswerLimitTests.swift, no_unchecked_sendable): `RunStartingContainer` now conforms to plain `Sendable`. Its state is a `Mutex` and immutable `Sendable` values, so the compiler checks the conformance. The file has no other `@unchecked Sendable`.
    - Finding 2 (SessionTreeRestorationTests.swift, reuse): new helper `expectForkAndRestoreKeep(_:madeWith:readBy:sourceLocation:)` takes the expected value, the configuration and a closure (a key path) that reads the setting. It does the fork, the restore and the 3 expectations (fork, restored root, restored fork). Both `@Test` functions stay, with their names and task references. Test count: 2 before, 2 after.
    - Check: a temporary wrong expected value in both tests made each test fail with 3 issues, and each issue pointed at the call site in the test. The change is reverted.
    - `swift test`: 1486 + 17 + 19 = 1522 passed, 0 failed. The 2 known issues were there before.
    - `MailOnlyAnswerLimitTests|SessionTreeRestorationTests`, 3 extra runs: 31 tests, all passed each time.
    - next: review.
  timestamp: 2026-09-26T14:11:45.203813+00:00
position_column: doing
position_ordinal: '80'
title: Decide a guard for an endless chain of mail-only submissions
---
## Why

Found during ^3qx0mpt. Since the pump of a session delivers each settled background run as mail with no caller call (`generation-queue.md`, section 5.4), a model that starts one more background run in each delivery submission gets one more delivery for each run, with no end. Scripted test models showed it: `SessionOutboxToolWiringTests.ToolInvokingBackend` called its background tool in every `respond`, and a single test ran more than 250 delivery submissions after its assertions, which slowed a parallel stress run by about 50% and made timing tests fail. The fixtures now start work on the first call only (`FirstCallFlag`), but a real model can do the same thing (for example, a model that asks a background status tool after each result).

## What to decide

- Is an endless chain of mail-only submissions a defect, or the intended behavior of "mail causes the next submission"?
- If it is a defect: a bound (for example, a count of consecutive mail-only answers with no caller message, after which the mail waits for a caller message), where it lives (the pump), and how it is reported (an event, a log line).

## Acceptance Criteria

- [x] The decision and its reason are on this task. <!-- proof: the comment "Decision: a bound in the pump" on this task -->
- [x] If a guard is chosen: a test with a scripted model that starts a background run in each submission shows that the pump stops after the bound and that the next caller message carries the waiting mail. <!-- proof: MailOnlyAnswerLimitTests.anEndlessChainStopsAtTheLimit, theHeldMailRidesTheNextCallerMessage, aCallerMessageStartsTheCountAgain, aChainUpToTheLimitRunsWhole, aLimitOfZeroHoldsAllMail --> #generation-queue

## Review Findings (2026-09-26 09:00)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 19 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:112` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:963` `reuse/reuse` — New test `restoredTreeReappliesRecordedMailOnlyAnswerLimit` is a near-identical copy of the existing test `restoredTreeReappliesRecordedRepetitionDetection` (lines 934–961), differing only in the configuration property being tested and its initialization. The setup, restoration flow, and verification structure are identical across both tests, indicating this should be refactored into a parameterized test rather than duplicated. Refactor both tests into a single parameterized test using Swift's `@Test(arguments:)` or extract a shared test helper function that accepts the configuration property setter and assertion as closures. This eliminates code duplication while maintaining test clarity and independence.

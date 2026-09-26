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
---
assignees:
- claude-code
depends_on:
- 01M546C19377FP3SF7YFPZCDT3
position_column: todo
position_ordinal: '8180'
title: 'T1 follow-up 2/6: waitForPrompts of a prompt-counting backend also ends on the pump end or the answer end'
---
Source: task ^dbr1dqy (T1 audit, done). The audit comment "kinds of waits checked and left" names this helper change as not made: `waitForPrompts` with an end on the pump end (MailQueueFixtures / PumpProbeBackend). Reason given: the failure event (pump end, mail terminal) signals a different ChangeSignal, not `backend.changes`.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

Helper (checked against the code on 2026-10-17):
- `PromptCountingBackend.waitForPrompts(_:)` in Tests/FoundationModelsRouterTests/Helpers/MailQueueFixtures.swift:187. It calls `changes.wait(untilAtLeast:of:)` on the backend signal. Conformers: `SessionMessagePumpTests.PumpProbeBackend` (MailQueueFixtures.swift:192) and `BackgroundingBackend`.

Failure event to use: the end of the answer task that must send the prompt, or the pump end / settle of the session when the test has it. These events already exist. Two forms are possible, both only in test helpers:
- `RecordedWaitResult.wait(for: { try await backend.waitForPrompts(n) }, endingOnEndOf: answerTask)` (Helpers/RecordedWaitResult.swift:105).
- `changes.wait(until:endingOn:)` (Helpers/ChangeSignalWait.swift:71), when the failure state is readable and the backend signal also changes at that event.
Choose one form, add it to the helper as one member (for example `waitForPrompts(_:endingOnEndOf:)`), and use it at each site where a failure event exists.

Waits that depend on the helper:
- [ ] Add the new member to the PromptCountingBackend extension in MailQueueFixtures.swift.
- [ ] Helpers/MailQueueFixtures.swift:165 (`waitForPrompts(heldAnswerPrompts)`).
- [ ] MailSubscriptionTests.swift:138.
- [ ] MailTranscriptTests.swift:199, 242, 365, 562.
- [ ] OriginAndTerminalEventTests.swift:252, 373, 419, 467, 503.
- [ ] RunMessageDeliveryTests.swift:170, 187, 194, 213, 221.
- [ ] SessionMessagePumpTests.swift:305, 371, 392, 416, 447, 484, 519, 529, 552, 683.
- [ ] SubmissionAnswerEventTests.swift:78, 105, 139, 193.
- [ ] For each site, name the failure of the test and the event that comes also in that failure. When the backend holds all work (no event comes), leave the site and write the reason in a comment on this card.
- [ ] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup
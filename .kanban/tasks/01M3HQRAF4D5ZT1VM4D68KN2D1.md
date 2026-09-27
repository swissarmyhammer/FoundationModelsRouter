---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3hr5xnh1vxw3r2wxhjjdy0x
  text: |-
    ### Research
    - Extras `Mailbox` (f4bd503): `answerNextBatch` starts a batch only with a first waiting letter; `takeJoining` returns [] when `isBatchRunning` is false. No public API starts an empty batch. A letter gets its result only from its batch or from `cancel` (`CancellationError`).
    - Chosen fix (router only, no Extras change): for a mail-only answer, the pump posts its own mail-delivery letter to `SessionOutbox.messages` and runs the mail-only answer as the body of the batch that this letter starts (joining rule: no other letter joins the first submission). Then `takeJoining` in a continuation works as for a caller batch, and the mailbox gives the final reply (or the error) to each joined caller. The delivery letter is not a caller message: the answer carries no letter for it (`letters: []`), so the mail-only limit, `runningWorkItems`, `isWorkCancelled` and the cancel marks do not change.
    - Why this is safe: callers post only on the session actor, and the pump posts the delivery letter and takes its batch on the actor with no suspension point between them. So the delivery letter is always the first letter, and no reader on the actor sees it wait. An off-actor cancel only cancels the id of its own caller.
    - The pump takes the mail first (a suspension point). When a caller message arrived in that time, the pump puts the mail back untouched and takes the caller batch; the mail rides it.
    - `messageQueueDepth()` leaves the delivery letter out of `running`. `pendingMessages()` now reads the mailbox on the session actor, so it never shows the delivery letter.
    - Tests (SessionMessagePumpTests): `aCallerMessageJoinsARunningMailOnlyAnswer` fails on the current code (the message got answer 4, not the continuation answer 3). The two other tests (not admitted, cancelled before the join) pass on the current code and guard the fix.
  timestamp: 2026-09-27T15:36:46.001654+00:00
- actor: claude-code
  id: 01m3hrc17ajnt4y6e7x8z3mfcz
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorPump.swift (`answerMail`, `answerCallerBatch`, `mailDeliveryMessage`, `PumpWork.mailDeliveryLetter`, re-read of the waiting messages after the mail take), Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift (`messageQueueDepth()` leaves out the delivery letter; `pendingMessages()` reads on the session actor), Sources/FoundationModelsRouter/Session/SessionOutbox.swift (doc only), Tests/FoundationModelsRouterTests/SessionMessagePumpTests.swift (3 new tests). `swift test --filter SessionMessagePumpTests`: 11 tests in 1 suite passed; the join test failed before the fix (4 issues). The memory file of the cancellation invariants is updated.
    - next: test
  timestamp: 2026-09-27T15:40:06.250607+00:00
- actor: claude-code
  id: 01m3hsw9jjvcj5m33skjcxfjw2
  text: |-
    ### test — green
    - evidence: clean build (package intermediates removed) `swift build --build-tests`: 0 code warnings (only the build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle"). `swift test`: 1451 tests in 173 suites passed (2 known issues, the same as before), 17 tests in 8 suites passed, 19 tests in 3 suites passed. `swift test --filter AnswerCancellation --parallel --num-workers 8` x20: 27 tests each, 20/20 passed, 0 issues. Pump, queue, mail-limit and outbox suites parallel x20: 70 tests each, 20/20 passed.
    - next: commit
  timestamp: 2026-09-27T16:06:27.666394+00:00
- actor: claude-code
  id: 01m3hswtkwk96awm4ts0cyhmas
  text: |-
    ### commit — changed
    - evidence: b9e6202 fix(session): let a caller message join a mail-only answer again (^68kn2d1)
    - next: review
  timestamp: 2026-09-27T16:06:45.116504+00:00
- actor: claude-code
  id: 01m3ht20ptb9nq23z278j4q1gw
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b9e6202) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs, 0 failed. No prior findings.
    - next: done
  timestamp: 2026-09-27T16:09:35.194751+00:00
- actor: claude-code
  id: 01m3ht22pj9cx0yh57cqavdkyn
  text: |-
    ### finish iteration 1 — clean
    - implement: changed (pump-owned delivery letter starts the mailbox batch of a mail-only answer; 3 new pump tests; the join test failed before the fix)
    - test: green (swift test 1451 + 17 + 19 passed; AnswerCancellation parallel x20: 27/27 each; clean build 0 code warnings)
    - commit: b9e6202
    - review: clean — 0 findings
  timestamp: 2026-09-27T16:09:37.234542+00:00
position_column: done
position_ordinal: ffffffa080
title: 'Router: a caller message can join a running mail-only answer again'
---
## What
Regression from task ^9h3rkxf (commits 8e30e3c, d71a2af), reported by its implementer: "A mail-only answer has no batch in the mailbox, so a caller message that arrives while it runs waits for the next answer. Before this change it could join that answer." No one decided this change. Before ^9h3rkxf, `takeMessagesJoiningTheAnswer()` took each waiting caller message that the options of the running answer admit, also when the answer started from mail only (the terminal of a settled background run). Restore that behavior.

- `Sources/FoundationModelsRouter/Session/RoutedSessionActorPump.swift` (`takeMessagesJoiningTheAnswer()`) and `Session/SessionOutbox.swift`: during a mail-only answer, a continuation submission takes each waiting caller message that the answer's options admit, and the message joins the answer: its caller gets the final reply of that answer (or its error).
- The Extras `Mailbox.takeJoining(admitting:)` returns [] when no batch runs. Choose the fix yourself: for example, the router starts an empty Mailbox batch for a mail-only answer (if the Extras API allows it), or the router takes the waiting letters another way that keeps the same cancel guarantee (a cancelled message is never taken). If Extras needs a small API change, stop and write the exact request in a task comment; the router session sends it to the Extras session.
- Keep every cancellation invariant in `/Users/wballard/.claude/projects/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/memory/routed-session-cancellation-invariants.md`.

## Acceptance Criteria
- [ ] A caller message sent while a mail-only answer runs, and admitted by its options, joins that answer and gets its final reply.
- [ ] A caller message that the options do not admit waits for the next answer, in FIFO order.
- [ ] A caller message cancelled before the join is not taken and gets `CancellationError`.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add session tests in `Tests/FoundationModelsRouterTests/` for the three cases, with a scripted backend and real signals (no wall clock). The first test must fail on the current code.
- [ ] `swift test --filter AnswerCancellation --parallel --num-workers 8`, 20 times; all runs pass.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #defect
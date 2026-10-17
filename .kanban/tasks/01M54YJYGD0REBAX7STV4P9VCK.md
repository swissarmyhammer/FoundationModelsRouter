---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5509bgh14bf48s8xhr45tsh
  text: |-
    ### Decision of the coordinating session (swissarmyhammer-96), 2026-10-17
    - Do this task after the `t1-followup` chain.
    - The helper must not cancel the mail when only the test wait ends. Use a wait that ends without the `onCancel` of `awaitTerminal(of:)`, or write in the doc why the cancel is wanted.
  timestamp: 2026-10-17T13:19:43.121505+00:00
- actor: claude-code
  id: 01m553jtqbmy6zbp1f7yc15tea
  text: |-
    Research (implement step):
    - `SessionOutputHub.awaitTerminal(of:orThrow:)` has its own `onCancel`. That cancel only removes the waiter of the hub. It sends no cancel signal for the mail. The actor wait `awaitMailTerminal(of:)` puts `onCancel: { cancel(id) }` around that hub wait. So the helper can wait on the hub directly (`(session as! RoutedSessionActor).outputHub`, as MailSubscriptionTests does), with no change of production code.
    - A send makes the mail id pending in the hub before it returns, so a hub wait after the send does not throw `unknownMail`.
    - Fixed order for the red test: the hub wait of the old helper (inside the actor handler) and of the new helper both show as `outputHub.waiterCount == 1`. The test gives the permit only after that count. Then the cancel of the old helper runs `onCancel` at once, and `cancel(id)` puts its signal in the serial signal chain before the helper returns. A later probe signal of the test ends after that cancel. A queued mail then has the terminal `.cancelled` with the old helper, and no terminal with the new helper. No hang in either state.
    - Callers of the helper: AwaitAnswerTests (4 sites), SessionMailQueueTests `waitForTheStart(of:carrying:on:sourceLocation:)`, AnswerCancellationEntryPointTests `cancellingASentMessageInTheRunningAnswerLeavesTheAnswerToItsEnd`. The helper change fixes all of them.
    - No other test helper (Tests/…/Helpers, IntegrationTests, Tools) calls `awaitTerminal(of:)` or `awaitAnswer(of:)`. The other test Tasks that wait in them (AwaitAnswerTests, MailSubscriptionTests) are not cancelled. MailSignalTests cancels its `awaitAnswer(of:)` wait on purpose: that test checks the production cancel.
  timestamp: 2026-10-17T14:17:19.339637+00:00
- actor: claude-code
  id: 01m5540my1ahvbkh5b1k1wjbhm
  text: |-
    Implementation landed:
    - RED: `MailTerminalPermitWaitTests/aPermitThatComesFirstLeavesTheMailQueued` failed with the old helper. The queued mail had the terminal `.cancelled(<queued>)`, and the feed had two `signalDone` ends (one stray cancel signal, then the probe). After the second assertion was added, the old helper was put back for one run to see that both assertions fail; then the fix was put back.
    - GREEN: the helper waits in `SessionOutputHub.awaitTerminal(of:orThrow:)`. The test passes (1 test, 1 suite).
    - No change of production code. IntegrationTests does not compile the files of the unit test target, so it was not built.
    - Note for later: the test Tasks that call `respond(to:)` and are cancelled in a `defer` also cancel their mail (production API of `respond`). These are tests of the cancel itself or a cleanup after the test, not test helpers, so they are out of the scope of this card.
    - The build output has `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)` from the SwiftPM build system on each build. It is not a compiler warning of this change.
  timestamp: 2026-10-17T14:24:52.161930+00:00
- actor: claude-code
  id: 01m5540qyxxdtxq24qrdkvd8dh
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/Helpers/RecordedWaitResult.swift (helper waits in the output hub, doc tells why), Tests/FoundationModelsRouterTests/MailTerminalPermitWaitTests.swift (new red-then-green test). `swift test --filter 'FoundationModelsRouterTests.MailTerminalPermitWaitTests/aPermitThatComesFirstLeavesTheMailQueued'`: red (2 issues) with the old helper, green 1 test with the new. Full `swift test` one time at the end: 1835 tests in 226 suites passed with 9 known issues; 26 tests in 14 suites passed; 19 tests in 3 suites passed; XCTest 0 tests (3 targets).
    - next: `/review`
  timestamp: 2026-10-17T14:24:55.261472+00:00
- actor: claude-code
  id: 01m5545dbcmf2sa7nnksnpyedj
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (df829b46). Counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0, skipped 0. The engine reviewed 2 files. An ignore rule (.kanban/ from .reviewignore) excluded 4 files.
    - next: none. The task is in done.
  timestamp: 2026-10-17T14:27:28.236392+00:00
- actor: claude-code
  id: 01m5545zw8mjj6f97msnass7t0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 test files (1 new); red-first test failed with 2 issues on the old helper
    - test: green — full swift test after the last edit: 1835 tests in 226 suites + 26 + 19 passed (the full suite ran two times on this card)
    - commit: df829b46
    - review: clean — 0 findings, 2 files reviewed
  timestamp: 2026-10-17T14:27:47.208690+00:00
position_column: done
position_ordinal: ffffffff9080
title: 'T1 follow-up: the end wait of `wait(forPermitOf:endingOnTerminalOf:on:)` cancels the mail'
---
Found in ^cj4fd37. `RoutedSessionActor.awaitMailTerminal(of:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift) has `onCancel: { cancel(id) }`: a cancel of a task that waits in `awaitTerminal(of: MailID)` sends a cancel signal for that mail. `RecordedWaitResult.wait(forPermitOf:endingOnTerminalOf:on:)` (Tests/FoundationModelsRouterTests/Helpers/RecordedWaitResult.swift) starts `Task { _ = try? await session.awaitTerminal(of: id) }` and cancels it in a `defer`. So each call of that helper sends one more cancel signal for the mail of the test, and one more `signalDone` goes to the feed. In ^cj4fd37 the same form in CancelAllSignalTests made `theSessionWorksAfterCancelAll` fail (one more done signal); that site now waits on the recorder of the feed.

- [x] Change the end event of `wait(forPermitOf:endingOnTerminalOf:on:)` to an event whose cancel has no effect on the mail (for example a read of the session feed for the terminal event of the mail), with no change of production code.
- [x] Add a test that fails with the old helper: after the wait, the feed has no `signalDone` of a cancel that the test did not send.
- [x] Check each caller of the helper (for example AnswerCancellationEntryPointTests `cancellingASentMessageInTheRunningAnswerLeavesTheAnswerToItsEnd`).
- [x] Run the full suite one time. #t1-followup

## Sites

- Helper: `RecordedWaitResult.wait(forPermitOf:endingOnTerminalOf:on:sourceLocation:)` now waits in `SessionOutputHub.awaitTerminal(of:orThrow:)` of the session. A cancel of that wait only removes the waiter of the hub; it sends no cancel signal. The doc of the helper tells why.
- Test: `MailTerminalPermitWaitTests.aPermitThatComesFirstLeavesTheMailQueued` (new file Tests/FoundationModelsRouterTests/MailTerminalPermitWaitTests.swift). Red with the old helper: the queued mail got `.cancelled`. Green with the new helper.
- Callers that the helper change fixes, with no edit: AwaitAnswerTests `mailThatSharesAnAnswerGetsThatAnswer`, `aCancelBeforeDeliveryThrowsCancellationError`, `aWaitForAQueuedMailGetsItsAnswer`, `aWaitForTheRunningAnswerGetsIt`; SessionMailQueueTests `waitForTheStart(of:carrying:on:sourceLocation:)`; AnswerCancellationEntryPointTests `cancellingASentMessageInTheRunningAnswerLeavesTheAnswerToItsEnd`.
- Other test helpers: no other helper in Tests/FoundationModelsRouterTests/Helpers, IntegrationTests or Tools calls `awaitTerminal(of:)` or `awaitAnswer(of:)`. The test Tasks that wait in them in AwaitAnswerTests and MailSubscriptionTests are not cancelled. MailSignalTests cancels its `awaitAnswer(of:)` wait on purpose, to test the production cancel. CancelAllSignalTests was fixed in ^cj4fd37.
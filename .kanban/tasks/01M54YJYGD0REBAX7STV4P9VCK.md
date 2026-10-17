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
position_column: todo
position_ordinal: '9380'
title: 'T1 follow-up: the end wait of `wait(forPermitOf:endingOnTerminalOf:on:)` cancels the mail'
---
Found in ^cj4fd37. `RoutedSessionActor.awaitMailTerminal(of:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift) has `onCancel: { cancel(id) }`: a cancel of a task that waits in `awaitTerminal(of: MailID)` sends a cancel signal for that mail. `RecordedWaitResult.wait(forPermitOf:endingOnTerminalOf:on:)` (Tests/FoundationModelsRouterTests/Helpers/RecordedWaitResult.swift) starts `Task { _ = try? await session.awaitTerminal(of: id) }` and cancels it in a `defer`. So each call of that helper sends one more cancel signal for the mail of the test, and one more `signalDone` goes to the feed. In ^cj4fd37 the same form in CancelAllSignalTests made `theSessionWorksAfterCancelAll` fail (one more done signal); that site now waits on the recorder of the feed.

- [ ] Change the end event of `wait(forPermitOf:endingOnTerminalOf:on:)` to an event whose cancel has no effect on the mail (for example a read of the session feed for the terminal event of the mail), with no change of production code.
- [ ] Add a test that fails with the old helper: after the wait, the feed has no `signalDone` of a cancel that the test did not send.
- [ ] Check each caller of the helper (for example AnswerCancellationEntryPointTests `cancellingASentMessageInTheRunningAnswerLeavesTheAnswerToItsEnd`).
- [ ] Run the full suite one time. #t1-followup
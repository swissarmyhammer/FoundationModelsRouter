---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4x47xxyr2gj21jy7152jteg
  text: 'Add from part H: the existing in-band refusal test of awaitTerminal(of:) uses a clock. Change it to an event wait, and add the same in-band refusal check for awaitAnswer(of:) when a tool calls it.'
  timestamp: 2026-10-14T11:54:55.294760+00:00
depends_on:
- 01M4X2JQH4PY1MWZEPHDFQ2YG8
position_column: done
position_ordinal: ffffffe080
title: Replace the other polls, sleeps and yield loops in the tests with event waits
---
Found in the first analysis of the wall-clock task. These waits are not in its file list:
- AwaitedCondition is a poll with no limit (yields, then a 5 ms sleep). About 12 more files use it, for example ChangeSignalTests, SessionIdleWaitTests, AnswerCancellation*, HumanWaitGateTests, PerCallMountSessionTests and BackgroundRunTranscriptTests.
- Task.sleep is in CancelAllSignalTests, MailSubscriptionTests, QueuedPassStallWatchTests, SessionChokepointTests, PerCallMountSessionTests, RoutedSessionToolContextBindingTests, SessionOutboxToolWiringTests, PendingElicitationFixtures and ToolMountFixtures.
- AsyncSemaphoreTests and CancellableWaitTests use loops of `while … { await Task.yield() }`.

Plan: use the internal ChangeSignal (changeCount, waitForChange(after:)) with one test helper: "read the state; if it is not correct, wait for the next change". Test recorders send that signal at each change. Add small internal observation points where no event exists (GenerationQueue, the pool admissions queue, the SessionOutbox mail queue, RunPlane).

Rules: no clock, poll, sleep, retry or time limit in their place. Run the full suite one time. Do it with the wall-clock task 01M4VMF0TF813VM891JED89NF4. #test
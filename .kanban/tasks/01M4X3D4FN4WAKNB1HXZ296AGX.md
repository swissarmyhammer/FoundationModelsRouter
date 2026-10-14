---
assignees:
- claude-code
depends_on:
- 01M4X2JQH4PY1MWZEPHDFQ2YG8
position_column: todo
position_ordinal: '8180'
title: Replace the other polls, sleeps and yield loops in the tests with event waits
---
Found in the first analysis of the wall-clock task. These waits are not in its file list:
- AwaitedCondition is a poll with no limit (yields, then a 5 ms sleep). About 12 more files use it, for example ChangeSignalTests, SessionIdleWaitTests, AnswerCancellation*, HumanWaitGateTests, PerCallMountSessionTests and BackgroundRunTranscriptTests.
- Task.sleep is in CancelAllSignalTests, MailSubscriptionTests, QueuedPassStallWatchTests, SessionChokepointTests, PerCallMountSessionTests, RoutedSessionToolContextBindingTests, SessionOutboxToolWiringTests, PendingElicitationFixtures and ToolMountFixtures.
- AsyncSemaphoreTests and CancellableWaitTests use loops of `while … { await Task.yield() }`.

Plan: use the internal ChangeSignal (changeCount, waitForChange(after:)) with one test helper: "read the state; if it is not correct, wait for the next change". Test recorders send that signal at each change. Add small internal observation points where no event exists (GenerationQueue, the pool admissions queue, the SessionOutbox mail queue, RunPlane).

Rules: no clock, poll, sleep, retry or time limit in their place. Run the full suite one time. Do it with the wall-clock task 01M4VMF0TF813VM891JED89NF4. #test
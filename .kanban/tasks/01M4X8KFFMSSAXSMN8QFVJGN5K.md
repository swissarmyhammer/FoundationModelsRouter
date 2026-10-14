---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Use the Extras clock input for the run timeout, the settle grace and the stall report
---
Blocked: start only when FoundationModelsExtras has an injectable clock for the run timeout, the inline settle grace and the stall report interval (mailbox.md step 8, Extras). Do not start before that.

A test that depends on a real clock, also by a large timer value, is still timing dependent. When Extras has the clock input:
- Use it in Router and in the tests.
- Remove MountFixtures.generousInterval (30 s, the inline settle grace in 5 suites) and unreachableReportInterval (600 s, QueuedPassStallWatchTests) as time bounds.
- Bring back ToolDisplayDeliveryTests.displayEventsResetTheTimeout as a fixed-order test. It was removed in cc7471a5, because it depended on the real clock of the Extras run timeout.

Rules: no clock waits, sleeps, polls or time limits in tests. Run the full suite one time. #test
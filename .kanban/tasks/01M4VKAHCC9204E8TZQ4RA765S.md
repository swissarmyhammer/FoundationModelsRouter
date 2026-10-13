---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4vmebfgr8pam1x7p680m116
  text: 'Fixed in commit bafa9774. Cause: after respond returns, the detached pump task holds the session for one more cycle, and a prewarm task holds it in the same way. The test read the count one time. Fix: the test helper ModelPool.awaitNoResidentModel() waits for the pool footprint events until no model is resident (no clock, no retry). One run alone with the live models: 4 tests in 1 suite passed.'
  timestamp: 2026-10-13T21:59:34.128333+00:00
position_column: done
position_ordinal: ffffffda80
title: CrossRouterPoolIntegrationTests fails some of the time
---
In the IntegrationTests package, CrossRouterPoolIntegrationTests fails some of the time. It expects `admittedResidentModelCount == 0` after the profile and its temporary sessions are dropped (lines 245 and 322). The test passes alone. In a full run of the live-model suite, it failed in 1 of 2 runs (the first run with 1 issue, the second run at both lines). The cause may be timing: a session can stay alive for a short time after `respond` returns. This is not proved. It is not known if the failure started before mail step 2. Found in part F (commit 69146032). #test
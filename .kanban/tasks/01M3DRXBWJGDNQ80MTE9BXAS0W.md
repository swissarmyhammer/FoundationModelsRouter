---
assignees:
- claude-code
position_column: todo
position_ordinal: '9880'
title: Decide a guard for an endless chain of mail-only submissions
---
## Why

Found during ^3qx0mpt. Since the pump of a session delivers each settled background run as mail with no caller call (`generation-queue.md`, section 5.4), a model that starts one more background run in each delivery submission gets one more delivery for each run, with no end. Scripted test models showed it: `SessionOutboxToolWiringTests.ToolInvokingBackend` called its background tool in every `respond`, and a single test ran more than 250 delivery submissions after its assertions, which slowed a parallel stress run by about 50% and made timing tests fail. The fixtures now start work on the first call only (`FirstCallFlag`), but a real model can do the same thing (for example, a model that asks a background status tool after each result).

## What to decide

- Is an endless chain of mail-only submissions a defect, or the intended behavior of "mail causes the next submission"?
- If it is a defect: a bound (for example, a count of consecutive mail-only answers with no caller message, after which the mail waits for a caller message), where it lives (the pump), and how it is reported (an event, a log line).

## Acceptance Criteria

- [ ] The decision and its reason are on this task.
- [ ] If a guard is chosen: a test with a scripted model that starts a background run in each submission shows that the pump stops after the bound and that the next caller message carries the waiting mail. #generation-queue
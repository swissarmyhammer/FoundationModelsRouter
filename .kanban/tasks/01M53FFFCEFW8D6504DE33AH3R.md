---
assignees:
- claude-code
depends_on:
- 01M53FF6DB5XXAG4T9JDMZ1CB9
position_column: todo
position_ordinal: '8180'
title: 'R3: end each open question on a feed before close ends the feeds'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 1, rule R3, group A.

Rule R3: each `elicitationRequested` on a feed gets its `elicitationEnded` on the same feed before the feed ends.

Defect: `close()` calls `performCancelAll()` (RoutedSessionActorForking.swift ~433-435), then ends the feeds (~440), and only then runs the drain (~448).

Scenario:
1. A child asks q2 while `performCancelAll()` of P waits.
2. P journals q2 and sends `elicitationRequested` while the feeds are open.
3. The feeds end.
4. The drain closes the child, and the relay ends q2 at P through `endElicitation` (SubagentQuestionRelay.swift ~383-386).
5. That end goes to a finished feed, so a client sees q2 open forever.

- [ ] Write a fixed-order test that fails before the fix: q2 is asked in the window of step 1; expect `elicitationEnded(q2)` on the same feed before the feed ends.
- [ ] Change the order of close so that each open question ends (on each open feed) before the feeds end. Keep the cancellation invariants (memory: RoutedSession cancellation invariants).
- [ ] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes
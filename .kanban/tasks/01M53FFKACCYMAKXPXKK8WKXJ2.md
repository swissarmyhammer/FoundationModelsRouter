---
assignees:
- claude-code
depends_on:
- 01M53FFFCEFW8D6504DE33AH3R
position_column: todo
position_ordinal: '8280'
title: 'R5: a relayed question is not model input, also after restore and fork'
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 2, rule R5, group C.

Rule R5: a relayed question is not model input.

Defect: RoutedSessionActorRunJournal.swift (~57) writes each run event as `.toolOutput`, and a relayed question is a run event. `ContextRenderer.context(of:)` puts that entry into the context after a restore or a fork (ContextRenderer.swift ~97-102, TranscriptReconstruction ~237-260). So after a restore of P, or a fork of P, the model of P reads the question q.

- [ ] Write a fixed-order test that fails before the fix: a child relays q to P; restore P (and, in a second test, fork P); the context of the model does not contain q.
- [ ] Fix: the relaying level keeps the question in its journal, but not in the context. This must also be true after restore and after fork. Keep the other run events in the context as they are now.
- [ ] Run the full suite one time. Build IntegrationTests one time.
#elicitation-fixes
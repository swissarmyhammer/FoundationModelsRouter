---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Session event elicitationCompleted when the run plane completes an accepted URL flow
---
Do not start this task until the Extras card is done that posts a run plane event when an accepted URL flow completes.

- [ ] Add a public SessionEvent case `elicitationCompleted(ElicitationCompletion)`. `ElicitationCompletion` carries the elicitation id (the same ULID as in `elicitationRequested`).
- [ ] The origin is the run mail (`.mail([id])` of the run that asked the question).
- [ ] The session sends the event when the run plane completes an accepted URL flow, from any source (the `complete(elicitationId:)` call of the client or another path that the Extras event reports). It comes before the events of the resumed run.
- [ ] Fixed-order test: the event comes one time, with the correct id and origin, before the first event of the resumed run.
- [ ] This is a new public case. The consumer switches (Agents demo, ACPAgent translator, Multitool ScenarioRunner) change in one step. Do not push before the reviewer is told and gives the word. #elicitation-phase-3
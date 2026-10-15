---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: cancelAll()/close() end a question that a tool completes before the sweep cancels it
---
Found while working ^rkh6k6m (finding hand-check/completion-gap).

The end check of `cancelAll()` and `close()` (`endOpenQuestions(at:)`, Sources/FoundationModelsRouter/Session/RoutedSessionActorQuestionEnds.swift) ends each recorded question that is still OPEN on the run plane, because the sweep that starts next cancels it. But the sweep cancels the questions only after it calls the canceler of each run (`RunPlaneActor.sweep`, `cancelQuestions { _ in true }` at the end). In that window, a tool can call `ToolContext.complete(elicitationId:)` on an accepted URL question. The run plane then completes the flow, the run gets the accept, and the completion post comes. The session already sent `elicitationEnded` for the question, and the record marked it `.ended`, so the post sends no `elicitationCompleted`. This is the same contract break as the finding (an end for a question that completed), with a different cause: the end check decides before the run plane does.

The fix of ^rkh6k6m covers a completion that started BEFORE the end check (`RunPlane.completingElicitations()`). It does not cover a completion that starts AFTER the end check and before the sweep cancels the question.

- [ ] Decide the design. Possible ways: the run plane cancels the open questions in the same step as the end check reads them (an Extras API that takes the open questions off at once), or the session defers the end of an open accepted URL question until the sweep took it off.
- [ ] Fixed-order test: an accepted URL question, `cancelAll()` (and `close()`), a canceler that holds the sweep, a tool completion in that window. Expect exactly one of `elicitationEnded` or `elicitationCompleted`, consistent with what the run got. #elicitation-phase-3
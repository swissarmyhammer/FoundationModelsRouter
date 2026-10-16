---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: cancelAll() sends no elicitationEnded for an open URL question of a runCode MCP tool
---
Reported by FoundationModelsACPAgent (foundationmodelsacpagent-85) on Router 2f78fda4 (^pjycptw) with Extras 6cfd13c.

A session prompt runs runCode. runCode calls an MCP tool that asks a URL-mode question (ToolContext.elicit). The client does not answer. Then cancelAll() (ACP session/cancel).

Observed order on streamSessionEvents after the cancel: cancelled(mail), cancelled(mail), answerFailed(.cancelled) of the prompt mail, signalDone(signal), runSettled(runCode, cancelled), workEnded, runProgress(detail CancellationError()). There is no elicitationEnded, before or after signalDone.

Expected (doc of SessionEvent.elicitationEnded): one elicitationEnded with the cancel response, origin Origin.signal of the cancel-all signal, before signalDone.

On Router 61d57115 the same test got one elicitationEnded with cancel and the reason "run cancelled".

Failing test: ElicitationRelayTests.sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle (FoundationModelsACPAgent). It fails every time on 2f78fda4.

- [ ] Find the cause: a question of a nested or mounted run (runCode, MCP tool) and the end post path of the run plane.
- [ ] Fixed-order Router test that is red before the fix: a URL question of a nested tool run, cancelAll(), expect one elicitationEnded with Origin.signal before signalDone.
- [ ] Fix.
- [ ] One full run. Tell the ACPAgent session and the reviewer. #defect #elicitation-phase-3
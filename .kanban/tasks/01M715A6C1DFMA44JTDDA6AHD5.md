---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m715kxaxtps4jt0v204hpqy3
  text: |-
    Research (worktree FoundationModelsRouter-fix @67cc8119). Root cause is NOT in the Router; it is the idle rule of FoundationModelsAgents (AgentRun+Drive.swift).

    Transcript 27NG7G, read in order:
    - seq 989-1087 are ONE answer (answer 1, the task prompt mail 01M711J8XC…, 188 s, all rows flushed at 20:59:38 by the submission diff). The pending notice at seq 1056 is inside it; its 46 s "delay" is only the write time of the diff, not a delivery delay.
    - The run completed at 20:58:52 while answer 1 ran. Its mail: progress 01M711P55Z… (the later progress events coalesce into it) and terminal 01M711PMERP…. Both waited in the queue (no continuation submission happened, so no join). The terminal held its WorkKind.mail lease.
    - seq 1088: answer 1 ends (one `answered` emit, one mail record: J8XC).
    - seq 1089: a SECOND, separate mail record event: answer 2 (the pump's next cycle, which took P55Z + PMERP and would render them with settledRunDeliveryPrompt) gets `answerFailed(.cancelled)` from `endRunningAnswerAtOnce()` (stopRunningAnswer, i.e. cancelAll/close). `answerFailed` also maps to MailRecord.answerEnded, so the rows read "answer ended".
    - seq 1090: the empty `.response` with ms 0 / tokens 0 is `recordFailedSubmission` of answer 2's model call, which threw CancellationError at once. Because the answer was silenced, `requeueUndeliveredRunMail` did not put the mail back.

    Who closed it: FoundationModelsAgents `AgentRun.drive` → follower `signal(after: .answered)` → `idleSignal` → `acceptedMessagesIfIdle` → `waitsForNoUserInput`. That rule ignores queued run mail on purpose (`userTypeKinds` = every MailKind except `.runEvent`, doc: "Run mail in the queue does not keep the session from idle"), checks `depth.running.isEmpty` (true in the short gap before the pump takes answer 2's batch), `isEachCallClosed` (the runCode call closed at completion), and terminals only for the mail of CHILD agent calls, not of a runCode background run. So it settles `.finished("Status: waiting on …")` and `session.close()` → cancelAll → answer 2, which carried the result, is cancelled. The Router's own no-work (work registry) was never reached: the terminal's mail lease was open.

    Router side checked: `takeMailJoiningTheAnswer` runs only for a continuation submission, and that submission renders the joining mail (deliveredMail + joining → composedPrompt), so hypothesis (a) "joined but never rendered" does not happen. The exact Router ordering (run settles inside the answer that started it, answer ends, answer to the run mail alone runs, ONE work-end after it) is already covered by SessionWorkLeaseTests.aRunThatSettlesInsideItsAnswerGivesOneWorkEnd.
  timestamp: 2026-11-09T22:07:17.853499+00:00
- actor: claude-code
  id: 01m715mkknthb03vsqx8zmxqgj
  text: |-
    ### implement — stuck
    - evidence: no files changed. Base 67cc8119 builds (`swift build --build-tests`, exit 0). `swift test --skip-build --filter "SessionWorkLeaseTests|RequeuedRunTerminalTests"`: 7/7 pass, including aRunThatSettlesInsideItsAnswerGivesOneWorkEnd. That test is the transcript ordering on the Router side: the run settles inside the answer that started it, a second answer delivers the terminal with settledRunDeliveryPrompt, and there is one work-end, after that answer. I can't write a Router test that fails for this bug, because the Router delivers the result and does not reach no-work early.
    - root cause: FoundationModelsAgents `AgentRun+Drive.swift` `acceptedMessagesIfIdle` / `waitsForNoUserInput` decides idle by its own rule. It skips queued `.runEvent` mail (`userTypeKinds`). It also passes in the gap between the `answered` of answer 1 and the pump taking answer 2's batch. The run then settles and closes its session, and that close cancels the answer that delivers the result. This breaks "no-work is the only end signal".
    - suggested fix (FoundationModelsAgents, outside the scope I was given): end the run on the Router's no-work and not on an idle rule rebuilt from queue depth. Two ways: the `workEnded` event, which `ChildSessionWork` already follows, or `session.runPlane.workRegistry.hasWork` / `awaitIdle()`. Each terminal or message of a background run that can start an answer holds a WorkKind.mail lease, so it keeps the session from no-work, and progress mail holds none. The hermetic failing test goes in FoundationModelsAgentsTests: a child run with a background tool that settles while the task-prompt answer still runs. Assert that the run's final reply comes from the answer to the run mail, and that the run does not close before that answer.
    - next: a human decides. Either retarget this card to FoundationModelsAgents, or allow work in that repo.
  timestamp: 2026-11-09T22:07:40.661087+00:00
- actor: claude-code
  id: 01m715nwjcjw48sggr7mkyxxnp
  text: |-
    ### Resolution: not a Router bug
    The root cause is in FoundationModelsAgents. AgentRun+Drive.swift judges idle with its own rule (acceptedMessagesIfIdle / waitsForNoUserInput):
    - it skips queued run mail;
    - it waits only on child-agent results;
    - it passes in the gap before the pump starts the answer that delivers the result.
    So it closes the session, and that cancels the answer (seq 1089 is cancelled, seq 1090 is an empty response).

    The Router behaves correctly:
    - its work registry keeps work open for the result;
    - joined mail always goes into a follow-up submission's prompt;
    - the existing test aRunThatSettlesInsideItsAnswerGivesOneWorkEnd covers this ordering and passes.

    Handed to foundationmodelsagents-8b to fix: end the run on the Router's no-work, with a failing test. No Router change. Branch fix/result-delivery removed unused.
  timestamp: 2026-11-09T22:08:22.604487+00:00
position_column: done
position_ordinal: fffffffff280
title: A background runCode result that completes is never delivered to the model, and the session ends at no-work
---
## Report (from foundationmodelsacpagent-96, 2026-11-09)
A background `runCode` result is never delivered to the model. The session then reaches no-work and ends, so a child agent finishes with "waiting on …" as its report, and the parent starts another agent to redo the work. This costs SWE-bench runs a lot of time.

### Evidence
Bench run planner24, django__django-13447, coder session …27NG7G. Transcript: `../FoundationModelsACPAgent/bench/preds.planner24.transcripts/django__django-13447/<dir ending 27NG7G>/transcript.jsonl`. Grep it for `01M711P55Y78RQSSCKNX6VRN9Q`.
- 20:58:37, seq 923-925: runCode (tools.shell.execute, admin_views suite) goes background. The pending notice carries completionToken 01M711P55Y78RQSSCKNX6VRN9Q.
- 20:58:52, seq 933-935: the run completes (operation event `completed`, exitCode 0, 418 tests, 15.6 s).
- 20:59:38, seq 1056: the model is given the "pending … Its result will arrive in this conversation as a message" notice, 46 s AFTER the run completed.
- seq 1058-1085: the model does other work, then writes "Status: waiting on the background admin_views regression run…".
- seq 1088-1090: mail rows `mail 01M711P55Z16RJVBTB5F5F6KFE answer ended` and `mail 01M711PMERP892YF3CBX6C6QWQ answer ended`, an empty response, then the SESSION ENDS. The completed result never became input to the model.
The same shape appeared 3× in planner24 (two coders in 13447, one in 13710), and in dotask24 13964 (2026-11-08). There, foundationmodelsmultitool-35 traced it: "The terminal result reached the transcript but was never given to the model as a follow-up turn" (its item "H part 2").

### Suspects (confirm in code)
SessionOutbox, the MailQueue, RoutedSessionActorIdle / the work registry.
1. A completed background run must deliver its result as an input mail to the model. That includes a run that completes BEFORE the model has processed its own pending notice, or while a generation is running. Here the result's mail looks marked handled ("answer ended") without ever being fed to the model.
2. A session must not reach no-work while a completed result is still undelivered.
Design rule: there are no turns. Results and mail are input messages, and no-work is the only end signal.

## Acceptance
- [ ] A hermetic failing test reproduces the race: the run completes before the model has handled the pending notice, or during a generation, and the result is never delivered and the session reaches no-work.
- [ ] Fixed: the completed result is delivered to the model as input mail, and no-work is not reached while a completed result is undelivered.
- [ ] Pushed. Reply to foundationmodelsacpagent-96 with the sha. #bug
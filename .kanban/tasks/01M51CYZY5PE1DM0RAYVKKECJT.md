---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51dxjm6hk0mjvewmn8tqcjt
  text: |-
    Cause (checked in the code, it agrees with the investigation):
    1. performCancelAll() calls stopRunningAnswer() first. endRunningAnswerAtOnce() sends answerFailed(.cancelled), then outputHub.silence(ids) and openAnswerMail.silence(). The answer stops later, so runAnswerWork keeps currentAnswerEventSink set.
    2. cancelOpenElicitations() posts the end. record(elicitationEnded:) -> deliverLive(_:origin:) -> deliverLive(_:) -> the sink of the stopped answer -> emit with audience = openAnswerMail.all -> SessionOutputHub.emit drops it (audience not disjoint with silenced).
    3. close() runs performCancelAll() too, so close() had the same drop (origin .system). The close variant of the test was red too.
    4. elicitationCompleted had the same drop: a completion on its way at cancelAll() is recorded after stopRunningAnswer(), while the stopped answer continues. Red test for it in ElicitationCompletedEventTests.

    Design decision: the new deliverQuestionPost(_:origin:) sends the end or the completion session-scoped (OriginContext = origin.output, no audience) ONLY while openAnswerMail.isSilenced. Else it uses deliverLive(_:origin:) as before. Reason: SessionEvent.elicitationEnded/elicitationCompleted docs say the event is "on the stream of the answer when the question ends inside an answer". A session-scoped event at all times would remove the event from the mail subscription of a running answer that is not stopped. The stopped answer already has its terminal event, so no reader of its mail waits for the post. The guard !outputHub.drops(poster) stays. deliverLive(_:) is not changed.

    Other events dropped in the same window (runSettled/runProgress/elicitationRequested of another background run, toolInvocation/report/display): recorded as new card ^x2aawec, not fixed here.

    Tests: SessionWorkEventTests-style fixed order, no sleeps. A plain Tool (no background declaration) runs to completion inside the answer and asks a URL question; the test mails the prompt and reads the feed up to elicitationRequested. For the completion test, the backend holds the first answer (BackgroundingLLMContainer(holdFirstAnswer:)), and ElicitationPostings holds the completion post.
  timestamp: 2026-10-16T04:00:59.526823+00:00
- actor: claude-code
  id: 01m51dxphgvbstenkw9kmp3rav
  text: |-
    ### implement — changed
    - evidence: files Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift, Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift, Tests/FoundationModelsRouterTests/ElicitationCompletedEventTests.swift. RED (swift test --filter "DuringAnAnswer", 3 tests matched): "cancelAll() during an answer whose tool waits on a question gives the end before signalDone" recorded an issue: expected one end of the question, got 0; the close() variant: got 0; "cancelAll() during an answer while the completion of the tool is on its way gives that completion before the signalDone": expected one completion of the question, got 0. GREEN: "Test run with 3 tests in 2 suites passed". Full run (one time): "Test run with 1758 tests in 213 suites passed after 9.624 seconds with 1 known issue" (the known issue is the withKnownIssue of RealModelHarnessTests), plus 26 and 19 test runs passed, no warnings. IntegrationTests: swift build --build-tests --manifest-cache local -> Build complete.
    - next: review. The last card item (tell the ACPAgent session and the reviewer) is for the main session. New card ^x2aawec for the other dropped live events.
  timestamp: 2026-10-16T04:01:03.536789+00:00
position_column: doing
position_ordinal: '80'
title: cancelAll() sends no elicitationEnded for an open URL question of a runCode MCP tool
---
Reported by FoundationModelsACPAgent (foundationmodelsacpagent-85) on Router 2f78fda4 (^pjycptw) with Extras 6cfd13c.

A session prompt runs runCode. runCode calls an MCP tool that asks a URL-mode question (ToolContext.elicit). The client does not answer. Then cancelAll() (ACP session/cancel).

Observed order on streamSessionEvents after the cancel: cancelled(mail), cancelled(mail), answerFailed(.cancelled) of the prompt mail, signalDone(signal), runSettled(runCode, cancelled), workEnded, runProgress(detail CancellationError()). There is no elicitationEnded, before or after signalDone.

Expected (doc of SessionEvent.elicitationEnded): one elicitationEnded with the cancel response, origin Origin.signal of the cancel-all signal, before signalDone.

On Router 61d57115 the same test got one elicitationEnded with cancel and the reason "run cancelled".

Failing test: ElicitationRelayTests.sessionCancelDuringAPendingElicitationDeliversCancelBeforeIdle (FoundationModelsACPAgent). It fails every time on 2f78fda4.

- [x] Find the cause: a question of a nested or mounted run (runCode, MCP tool) and the end post path of the run plane.
- [x] Fixed-order Router test that is red before the fix: a URL question of a nested tool run, cancelAll(), expect one elicitationEnded with Origin.signal before signalDone.
- [x] Fix.
- [ ] One full run. Tell the ACPAgent session and the reviewer. #defect #elicitation-phase-3
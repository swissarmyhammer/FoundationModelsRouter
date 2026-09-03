---
comments:
- actor: claude-code
  id: 01m1km35wwa1ebcg8zjf341bpv
  text: |-
    Picked up. Research of the attach carrier route, before any edit.

    The route a mounted call's record takes today:
    1. The mounting run binds a `ToolContext` whose `attachmentSink` appends to the run's own `ToolCallAttachmentBox` (Hosting/ToolRun.swift, Hosting/ContextBindingTool.swift).
    2. `ToolContext.mount(_:op:as:)` gives the mounted run a `MountedRunUpstreamSink(context: self)` (Hosting/ToolContext.swift). That sink is both an `OperationEventSink` and a `ToolCallReportSink`.
    3. The mounted call closes. `ToolRun.execute` calls `sink.postToolCallReport(closing:attachments:)`. The extension in Session/OperationEventJournal.swift casts the sink to `ToolCallReportSink`, so `MountedRunUpstreamSink.post(report:)` runs and hands each attachment to the MOUNTING context with `attach(_:)`. The mounted call therefore posts no report of its own.
    4. The mounting call closes. Its own `postToolCallReport` reaches `SessionOutbox`, which is also a `ToolCallReportSink`. `SessionOutbox.post(report:)` calls `invocationObserver.deliver(report:)`, and `RoutedSessionActorRunJournal.deliver(report:)` calls `deliverLive(.toolCallReport(report))`. Inside a turn that goes to `currentTurnEventSink`, so the event lands on `streamEvents()`.

    So both facts the card asks for should already hold. What exists today proves only parts of them:
    - ToolContextMountTests `nestedCallAttachmentsRideTheMountingCallReport` proves the correlation at the decorator level, against a `RecordingSink`, with no session and no live stream.
    - ToolInvocationLivenessTests `runToCompletionCallReportsItsAttachmentsOnTheTurnStream` proves live delivery on the turn stream, but only for a tool that attaches on its OWN context, never through a mount.

    Nothing joins the two: no test drives a real session turn whose tool mounts another tool and reads the report off `streamEvents()`. That join is what this card asks for.

    Existing helpers the proof can reuse: `ScriptedSessionFixture.make(playing:mounting:tempDirPrefix:)`, `collectEvents(_:prompt:)`, `MountFixtures.attachmentsInCallOrder`, and the private `NestingAttachingTool` in ToolContextMountTests.
  timestamp: 2026-09-03T12:32:27.036665+00:00
- actor: claude-code
  id: 01m1kmsv10cz1vwfzqr4hw63bj
  text: |-
    Research of the attach carrier, before any edit.

    The route a mounted call's record takes today:
    1. The mounting run binds a `ToolContext` whose `attachmentSink` appends to that run's own `ToolCallAttachmentBox` (Hosting/ToolRun.swift, Hosting/ContextBindingTool.swift).
    2. `ToolContext.mount(_:op:as:)` gives the mounted run a `MountedRunUpstreamSink(context: self)` (Hosting/ToolContext.swift). That sink is both an `OperationEventSink` and a `ToolCallReportSink`.
    3. The mounted call closes. `ToolRun.execute` calls `sink.postToolCallReport(closing:attachments:)`. The extension in Session/OperationEventJournal.swift casts the sink to `ToolCallReportSink`, so `MountedRunUpstreamSink.post(report:)` runs and hands each record to the MOUNTING context with `attach(_:)`. The mounted call posts no report of its own. Its invocation records take the `OperationEventSink` blanket default and go nowhere.
    4. The mounting call closes. Its own `postToolCallReport` reaches `SessionOutbox`, which is also a `ToolCallReportSink`. `SessionOutbox.post(report:)` calls `invocationObserver.deliver(report:)`, and `RoutedSessionActorRunJournal.deliver(report:)` calls `deliverLive(.toolCallReport(report))`. Inside a turn that goes to `currentTurnEventSink`, so the event lands on `streamEvents()`.

    What existed before this card proved only halves of the two facts:
    - ToolContextMountTests `nestedCallAttachmentsRideTheMountingCallReport` proves the correlation at the decorator level, against a recording sink, with no session and no live stream.
    - ToolInvocationLivenessTests `runToCompletionCallReportsItsAttachmentsOnTheTurnStream` proves live delivery on the turn stream, but only for a tool that attaches on its OWN context, never through a mount.

    Nothing joined the two. That join is what this card asked for.
  timestamp: 2026-09-03T12:44:49.568429+00:00
- actor: claude-code
  id: 01m1kmtdc8t7a0cnajhqdx70e6
  text: |-
    Implementation landed. Both facts the card names already hold in the Router, so the work is the proof, and no production file changed (`git diff Sources` is empty).

    New suite: Tests/FoundationModelsRouterTests/MountedRunAttachmentCarrierTests.swift, three tests over a real scripted session turn whose tool mounts another tool.

    1. `mountedCallReportArrivesOnTheTurnStreamMidTurn` — fact 1. The script has two rounds: round 1 calls the mounting tool, round 2 calls a gated tool that blocks. The test reads the turn's own `streamEvents(to:)` until the report arrives, and only THEN opens the gate. The turn cannot end before the gate opens, so a report read above that line is delivered mid-turn. It then asserts the gated round really ran, one report for the whole turn, and that the report follows the mounting call's close record.
    2. `liveReportIsKeyedToTheMountingRun` — fact 2. Exactly two invocation records reach the host, both stamped with the mounting tool, so the mounted call's own correlation is never visible. The report's `correlationID`, `tool`, `op` and `sessionID` equal the mounting call's close record, and `report.tool != "attaching_tool"` is the decisive negative.
    3. `attachedRecordsDecodeBackUnchanged` — the records arrive whole and in call order, and the first one's `contentJSON` decodes into a `FileChangeSetProbe` equal to the value the fixture holds.

    Supporting edits, all in the test target:
    - Helpers/ToolMountFixtures.swift: `NestingAttachingTool` moved in from ToolContextMountTests, so both suites share one fixture instead of two copies.
    - Helpers/SessionEventCollection.swift: the `SessionEvent` readers (`isOpenInvocation`, `isCloseInvocation`, `carriedInvocation`, `carriedReport`) promoted from a fileprivate extension in ToolInvocationLivenessTests to one internal extension.
    - ToolContextMountTests.swift and ToolInvocationLivenessTests.swift: point at the shared fixture and the shared readers.

    Discrimination check, so the tests are not vacuous. `MountedRunUpstreamSink.post(report:)` was temporarily neutered to drop each attachment instead of re-attaching it to the mounting context. All three tests went red: tests 2 and 3 failed on the missing report, and test 1 ran into the suite's 1-minute time limit — which is itself the proof that the gate really holds the turn open and that the report genuinely arrives before the turn ends. The production file was restored, and the suite is green again.

    Two notes for the next agent:
    - The scripted model reports no token usage, so `SessionEvent.turnEnded` never fires in these fixtures. An ordering assertion of the form `report < turnEnded` would be vacuous. That is why the gated-round shape carries the liveness claim instead.
    - A `#require(events.firstIndex(where: \.isCloseInvocation))` does not compile: the `#require` macro rewrites the call and the key-path argument then reads as throwing. Write the closure form, `events.firstIndex { $0.isCloseInvocation }`.
  timestamp: 2026-09-03T12:45:08.360897+00:00
- actor: claude-code
  id: 01m1kmtmm2xf3pqan002envryh
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterTests/MountedRunAttachmentCarrierTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/ToolMountFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/SessionEventCollection.swift, Tests/FoundationModelsRouterTests/ToolContextMountTests.swift, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift. `swift test` reports 1219 tests in 132 suites passed, plus 83 tests in 10 suites passed. No production file changed: both facts the card names already hold.
    - next: /review
  timestamp: 2026-09-03T12:45:15.778968+00:00
position_column: doing
position_ordinal: '80'
title: 'Prove the mounted-run attach carrier: a live toolCallReport under the mounting run''s correlationID'
---
## What
FoundationModelsMultitool will make its mutating file verbs attach the encoded `FileChangeSet` through `ToolContext.attach(_:)` at journal commit (see the task ^n313gma on the Multitool board). A file verb runs as a MOUNTED (nested) tool inside a `runCode` call. For the attachment to reach an ACP client, two Router-side facts must hold. Prove each one with a test, and correct the code where a proof fails:

1. **Live delivery.** An attachment made from a mounted tool context fires `SessionEvent.toolCallReport(ToolCallReport)` (Session/SessionEvent.swift:47) on `streamEvents()` DURING the turn — not only into the recording. `MountedRunUpstreamSink` (Hosting/ToolContext.swift:88-105) forwards attachments; the proof must show the forwarded attachment reaches the live stream.
2. **The correct key.** The `ToolCallReport` carries the MOUNTING run's `correlationID` — the outer `runCode` completionToken. That token is the one `toolCallId` a wire client knows. A report keyed to the inner verb's own token reaches no visible tool call.

## Test shape
A tool mounted through `ToolContext.mount(_:op:as:)` calls `attach(_:)` with one record; the session's `streamEvents()` receives one `toolCallReport` before the turn ends, keyed by the mounting run's token, and the record decodes back unchanged.

## Why
FoundationModelsACPAgent (card ^9jfmhh0) fills `tool_call_update.locations` from this record (its plan.md §11.5, §11.6, §20.1 proof 3). Its projection arm for `toolCallReport` exists. See Ask 4 in UPSTREAM_ASKS.md.
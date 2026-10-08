# ``FoundationModelsRouter/RoutedSession``

The public session surface, grouped by audience (tasks ^j0pp9yp, ^k0mecjp).

## Overview

A session has three audiences, and each one gets typed capabilities:

- **Apps and drivers** hold a `RoutedSession` and use the members below.
  They never touch the raw staging and backgrounding machinery — the session's
  `SessionOutbox` and its run plane (the `RunPlane` of FoundationModelsExtras)
  are internal wiring.
- **Tools** do not use this protocol at all. A running tool reads the
  ambient ``ToolContext`` and uses its capabilities:
  `ToolContext.post(_:)`, `ToolContext.progress(_:plan:)`, and
  `ToolContext.elicit(_:)`. Its `isCancelled` property is internal to
  FoundationModelsExtras.
- **Tool hosts** — a tool that shows the run plane to a model — read that
  plane through the same ambient context, never through a mailbox:
  `ToolContext.backgroundRuns()`,
  `ToolContext.wait(completionToken:seconds:)`, and
  `ToolContext.cancel(completionToken:)` (task ^k0mecjp).

## Tool hosting comes from FoundationModelsExtras

The core `FoundationModelsExtras` package hosts the tools of each session: it
mounts each tool, runs a background tool, keeps the run plane of the session,
and binds the ambient ``ToolContext`` of each call. The session makes the run
plane and the outbox of its tools, caps the tool output, and records each
event of a run in its transcript.

The router names ``ToolContext``, ``BackgroundTool``, ``ToolMount``,
``ToolMountError``, ``SubmissionBoundaryTool``, ``LostRunError``, ``RunKind``,
``BackgroundRun``, ``WaitOutcome``, ``CancelOutcome``, ``PendingRunEnvelope``,
``ToolCallAttachment``, ``ToolCallReport``, ``ElicitationAnswerDelivery`` and
``ElicitationCompletionDelivery`` are aliases of the Extras types. A file that
imports both modules finds one type for each name.

## Long-running tools

A tool declares ahead of time that it runs long, through
`BackgroundTool.mount`, or for one call through `BackgroundTool.mount(for:)`.
Such a call runs in the background mode of ``ToolMount``: it returns a
``PendingRunEnvelope`` handle at once, and the work goes on behind it. Every
other call runs to completion and returns its result in band;
`ToolMount.timeout` bounds the work.

The session pushes settlement to the model — the model never polls:

- ``respond(to:maxTokens:)`` and the streaming surfaces answer from their own
  submission, and return while a run is in flight.
- The terminal of a settled run is mail. The pump of the session delivers it
  to the model in a later submission, with no caller call, and it is also
  reported as ``SessionEvent/runSettled(_:)``.
- A background run can send a message to its session while it continues
  (`ToolContext.message(_:)`). The message is mail too: the pump delivers it
  in a later submission, with no caller call, and it is also reported as
  ``SessionEvent/runMessage(_:)``. The run stays open, and its terminal comes
  later. A message of a run that is not a background run starts no
  submission: it goes with the next submission.
- A run can report its progress while it continues
  (`ToolContext.progress(_:plan:)`). Each progress event goes live to the
  host as ``SessionEvent/runProgress(_:)``. The model gets only the short
  text line of the event. The agent plan of the event (`OperationEvent.plan`)
  goes only to the host: no model input holds it, also after a restore. The
  journal writes a progress event that has a plan at once, so a host can
  replay the last plan after a restore.
- `status` and `wait` give an earlier look; they are not required.

A model can start one more background run in each answer, for example to ask
a status tool again after each result. Each settled run then starts one more
answer, with no end. ``SessionConfiguration/mailOnlyAnswerLimit`` bounds that
chain: when that many answers in a row had no caller message, the session
holds new mail in its queue and starts no answer for it. The next caller
message carries the held mail, so no mail is lost. The session reports each
hold with ``SessionEvent/mailDeliveryPaused(_:)`` and a log line. The default,
``SessionConfiguration/defaultMailOnlyAnswerLimit``, is far past a normal
chain.

## Topics

### Identity and directories

- ``profile``
- ``routerId``
- ``id``
- ``parentId``
- ``recordingDirectory``
- ``workingDirectory``
- ``grammar``

### Conversation

- ``respond(to:)``
- ``respond(to:maxTokens:)``
- ``streamResponse(to:)``
- ``streamResponse(to:maxTokens:)``
- ``streamEvents(to:)``
- ``streamEvents(to:maxTokens:)``
- ``respond(to:maxTokens:observing:)``
- ``transcript``

### Session-scoped events

Each submission sends ``SessionEvent/submissionQueued(_:)`` (only when it must
wait for the worker of its model), ``SessionEvent/submissionStarted(_:)`` and
``SessionEvent/submissionEnded(_:)``. Each chain of submissions ends with
``SessionEvent/answered(_:)``, or with ``SessionEvent/answerFailed(_:)`` when
it gives no answer.

- ``streamSessionEvents()``
- ``SessionEvent``
- ``SubmissionStart``
- ``SubmissionEnd``
- ``SubmissionID``
- ``SessionAnswer``
- ``AnswerFailure``
- ``MailDeliveryPause``

### Messages

A session is a queue of messages (`generation-queue.md`, section 5.4).
``send(_:)-(Transcript.Prompt)`` puts one message in the queue and returns its
``MessageID`` at once. The pump of the session starts a submission for it with
no other call, or puts it into the next submission when one runs.
``respond(to:maxTokens:)`` and the two stream methods are helpers: each sends
one message, then waits for its answer.

- ``send(_:)-(Transcript.Prompt)``
- ``send(_:)-(String)``
- ``pendingMessages()``
- ``replace(id:prompt:)``
- ``messageQueueDepth()``

### Cancellation

- ``cancel()``
- ``cancel(message:)``

### Elicitation answers

- ``respond(elicitationId:response:)``
- ``complete(elicitationId:)``

### Context and compaction

- ``contextFill``
- ``compact()``
- ``compact(budget:)``
- ``compact(prompt:budget:)``

### Lifecycle and forking

- ``fork(workingDirectory:)``
- ``drain()``
- ``awaitIdle()``
- ``close()``

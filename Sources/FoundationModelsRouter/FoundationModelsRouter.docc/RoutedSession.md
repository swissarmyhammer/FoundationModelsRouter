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
  plane through the same ambient context, never through a direct reference
  to the run plane:
  `ToolContext.backgroundRuns()`,
  `ToolContext.wait(completionToken:seconds:)`, and
  `ToolContext.cancel(completionToken:)` (task ^k0mecjp).

### Mail, signals and output

A session works like a program with an input and an output. All input is
mail. All output is events. Control is signals.

- **Mail.** ``MailSink/mail(_:)`` puts one ``Mail`` in the mail queue of the
  session and returns a ``MailSubscription`` at once. Each mail has a
  ``MailID`` and a ``MailBody``. ``send(_:)-(Transcript.Prompt)`` sends one
  user message and returns its ``MailID``. ``respond(to:)``,
  ``streamEvents(to:)`` and ``streamResponse(to:)`` are helpers: each sends
  one mail and reads the output of that mail by its id.
- **Output.** Each element of ``streamSessionEvents()`` is a
  ``SessionOutput``: an event and the ``Origin-enum`` of the work that sent
  it. The origin is ``Origin-enum/mail(_:)`` with the ids of the mail of an
  answer, ``Origin-enum/signal(_:)`` with the id of a signal, or
  ``Origin-enum/system``. The output event of a run event
  (``SessionEvent/runMessage(_:)``, ``SessionEvent/runSettled(_:)``,
  ``SessionEvent/runProgress(_:)`` and
  ``SessionEvent/elicitationRequested(_:)``) has the origin
  ``Origin-enum/mail(_:)`` with the id of its run mail. Thus a reader waits
  for the ``SessionEvent/mailDelivered(_:)`` of that id to know that the model
  sees the run event. A run event that makes no run mail (a run that
  ``cancelAll()`` stopped, or a run event after ``close()``) keeps the origin
  of the work that posted it.
- **Signals.** ``cancel(_:)``, ``cancelAll()``, ``replace(_:with:)`` and
  ``compact(prompt:budget:)`` do not wait in the mail queue. Each returns a
  ``SignalID`` at once. ``close()`` ends the session.
- **One terminal event for each id.** Each mail id gets exactly one
  terminal event: ``SessionEvent/answered(_:)``,
  ``SessionEvent/answerFailed(_:)``, ``SessionEvent/cancelled(_:)`` or
  ``SessionEvent/lost(_:)``. Each signal id gets exactly one terminal event:
  ``SessionEvent/signalDone(_:)``, or ``SessionEvent/compaction(_:)`` or
  ``SessionEvent/compactionFailed(_:)`` for a compaction.
  ``awaitTerminal(of:)-(MailID)`` and ``awaitTerminal(of:)-(SignalID)`` wait
  for it. ``awaitAnswer(of:)`` waits for the terminal event of a mail and
  gives its ``SessionAnswer``, or throws the original error of its failed
  answer, the same error that ``respond(to:)`` throws. A wait for an id
  that the session has no record of throws ``TerminalLookupError`` at once.

### The context is a render of the transcript

The session records the life of each mail in its transcript. The context
that the model reads is a render of that recorded transcript. The render
starts at the last compacted value. A mail enters the context at the point
where the pump delivered it (``SessionEvent/mailDelivered(_:)``), not at the
point where it arrived. Queued mail, cancelled mail and the old body of a
replaced mail are not in the context. The render is a pure function: the
same transcript gives the same context, also after a restore.

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
imports both modules finds one type for each name. The router also re-exports
the Extras display types ``ToolDisplayEvent`` and ``ToolDisplayContent``, which
``SessionEvent/toolDisplay(_:)`` carries.

## Long-running tools

A tool declares ahead of time that it runs long, through
`BackgroundTool.mount`, or for one call through `BackgroundTool.mount(for:)`.
Such a call runs in the background mode of ``ToolMount``: it waits for its
run up to the settle period of the session,
``SessionConfiguration/inlineSettleGrace``. A run that ends in that time
answers with its own result, the same as a synchronous call, and is no mail.
A run that continues answers with a ``PendingRunEnvelope`` handle, and the
work goes on behind it. The default settle period is
`ToolMount.defaultInlineSettleGrace`, and `0` gives the handle at once. Every
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
  replay the last plan of each plan id after a restore. A plan replaces only
  the earlier plan that has the same `PlanSnapshot.id`.
- A tool can send output for the client to show while it runs
  (`ToolContext.emit(chunk:)`, `ToolContext.update(title:kind:locations:)`
  and `ToolContext.post(display:)`). Each display event goes live to the host
  as ``SessionEvent/toolDisplay(_:)``, in post order with the progress events
  of the same run. The model never gets it, the session never combines two of
  them, and the journal never records one. A display event resets the
  timeout of the run, the same as a progress event. A run that settles inside
  its settle period keeps its display events: the host already has them.
- `status` and `wait` give an earlier look; they are not required.
- A model that waits for a run must do nothing. A host can give
  ``SessionConfiguration/isNoOpToolCall``, the check that marks a tool call
  that does no work (``NoOpToolCallCheck``). While at least one run is open,
  or a settled run's terminal waits as mail, the session does not run a
  marked call, does not answer it, and does not put it in the transcript.
  Every other call of the same round runs to its end, and its result goes
  into the transcript. Then the generation stops. When the round had a real
  call, the answer goes on with the real results. When the round had only
  marked calls, the answer ends, and the terminal of the run is the next
  message that starts the model. With no pending run, the check changes
  nothing. The recording does not hold the check, so a host gives it again to
  ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:)``
  when it restores a session.

A model can start one more background run in each answer, for example to ask
a status tool again after each result. Each settled run then starts one more
answer, with no end. ``SessionConfiguration/mailOnlyAnswerLimit`` bounds that
chain: when that many answers in a row had no user-type mail (a user message,
an agent message or an elicitation answer), the session holds new run mail in
its queue and starts no answer for it. The next user-type mail carries the
held mail, so no mail is lost. The session reports each
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

Each element of ``streamSessionEvents()`` is a ``SessionOutput``: the event,
and the ``Origin-enum`` of the work that sent it. The pump sends
``SessionEvent/mailDelivered(_:)`` for each mail that an answer delivers:
user-type mail and run mail. Each mail gets exactly one terminal event:
``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)`` of the
answer that carries it, ``SessionEvent/cancelled(_:)`` when it left the
queue before the pump took it (``cancel(_:)``, ``cancelAll()`` or
``close()``), or ``SessionEvent/lost(_:)`` at restore when the process
stopped before its answer ended.

- ``streamSessionEvents()``
- ``SessionOutput``
- ``SessionEvent``
- ``SubmissionStart``
- ``SubmissionEnd``
- ``SubmissionID``
- ``SessionAnswer``
- ``AnswerFailure``
- ``MailDeliveryPause``

### Messages

All input to a session is mail in one mail queue: user-type mail (a user
message, an agent message or an elicitation answer) and run mail.
``MailSink/mail(_:)`` puts one mail in the queue and returns its subscription
at once. ``send(_:)-(Transcript.Prompt)`` and ``send(_:)-(String)`` put one user
message in the queue and return its ``MailID``. The pump of the session starts
a submission for the mail with no other call, or puts it into the next
submission when one runs. ``respond(to:maxTokens:)`` and the two stream
methods are helpers: each sends one message, then reads its output to its
terminal event. A caller that sends its own mail uses ``awaitAnswer(of:)`` to
get the answer, or the typed error of a failed answer, for example
`LanguageModelError.contextSizeExceeded`. The session keeps that error for the
4096 most recent terminal ids. A wait for mail that waits in the queue or in
the answer that runs waits for its terminal event. A call for an id that left
that record, or for an id that the session never knew, throws
``TerminalLookupError`` at once, because no terminal event can come for it.

- ``MailSink/mail(_:)``
- ``send(_:)-(Transcript.Prompt)``
- ``send(_:)-(String)``
- ``pendingMessages()``
- ``mailQueueDepth()``
- ``MailQueueDepth``
- ``awaitTerminal(of:)-(MailID)``
- ``awaitAnswer(of:)``
- ``awaitTerminal(of:)-(SignalID)``
- ``PromptRefusal``
- ``TerminalLookupError``

### Signals

Each signal returns a ``SignalID`` at once. The session runs the work of its
signals one at a time, in arrival order: the work of a signal starts when the
work of the earlier signal ended. Each signal ends with
``SessionEvent/signalDone(_:)`` after all its other events, and
``awaitTerminal(of:)-(SignalID)`` waits for that end. ``cancel(_:)`` and
``replace(_:with:)`` act only on queued mail. ``cancelAll()`` stops all work:
it cancels each queued mail, stops the running answer and the background runs,
and does not wait for the end of the cancels of the runs. It does not stop a
running compaction: that compaction ends first, then ``cancelAll()`` runs.
``compact(prompt:budget:)`` is a signal too.

- ``cancel(_:)``
- ``cancelAll()``
- ``replace(_:with:)``

### Mail and signal types

- ``Mail``
- ``MailBody``
- ``MailID``
- ``SignalID``
- ``Origin-enum``
- ``MailSubscription``
- ``MailSink``
- ``MailRefusal``

### Elicitation answers

A question of a run that ends with no answer of the client (a cancel of the
run, ``cancelAll()`` or ``close()``) gets one ``SessionEvent/elicitationEnded(_:)``
with the id of its ``SessionEvent/elicitationRequested(_:)``. A question that
the client answered gets none.

A session with no user is headless: a host gives
``SessionConfiguration/userPresence`` the value ``UserPresence/headless``.
Each question of a run of that session ends at once with a cancel that gives
the reason `RunPlane.noUserPresentReason`. The session sends no
``SessionEvent/elicitationRequested(_:)`` and no
``SessionEvent/elicitationEnded(_:)`` for it, and the run continues with the
cancel. The default is ``UserPresence/interactive``. The sidecar records the
value, a restore applies it again, and a fork inherits it.

- ``respond(elicitationId:response:)``
- ``complete(elicitationId:)``
- ``ElicitationEnd``

### Context and compaction

A compaction is a signal. The automatic trigger and the requested trigger
use the same handler. ``compact(prompt:budget:)`` returns a ``SignalID`` at
once and does not wait. The handler pauses the mail queue, sends
``SessionEvent/compactionStarted(_:)`` (the reason of a requested compaction
is ``CompactionReason/requested``), and ends with
``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``.
That event is the terminal event of the signal. Then the mail queue
resumes. Use ``awaitTerminal(of:)-(SignalID)`` to wait for the result. Only
``close()`` stops a running compaction.

- ``contextFill``
- ``compact()``
- ``compact(budget:)``
- ``compact(prompt:budget:)``
- ``CompactionReason``

### Lifecycle and forking

``awaitIdle()`` returns when the session has no work. A background run that
waits only for the user is no work. ``streamSessionEvents()`` reports the same
state with no call: ``SessionEvent/workStarted`` comes when the session gets
work while it had none, and ``SessionEvent/workEnded`` comes when it has no
work any more. Both have the origin ``Origin-enum/system``, and they come in turns,
in order with the other outputs.

- ``fork(workingDirectory:)``
- ``awaitIdle()``
- ``close()``

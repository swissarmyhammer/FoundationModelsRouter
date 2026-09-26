# ``FoundationModelsRouter/RoutedSession``

The public session surface, grouped by audience (tasks ^j0pp9yp, ^k0mecjp).

## Overview

A session has three audiences, and each one gets typed capabilities:

- **Apps and drivers** hold a `RoutedSession` and use the members below.
  They never touch the raw staging and backgrounding machinery — the session's
  `SessionOutbox` and `SessionMailbox` instances are internal wiring.
- **Tools** do not use this protocol at all. A running tool reads the
  ambient ``ToolContext`` and uses its capabilities:
  ``ToolContext/post(_:)``, ``ToolContext/progress(_:)``, and
  ``ToolContext/elicit(_:)``. Its `isCancelled` property is internal, so only a
  tool in this package reads it.
- **Tool hosts** — a tool that shows the run plane to a model — read that
  plane through the same ambient context, never through a mailbox:
  ``ToolContext/backgroundRuns()``,
  ``ToolContext/wait(completionToken:seconds:)``, and
  ``ToolContext/cancel(completionToken:)`` (task ^k0mecjp).

## Long-running tools

A tool declares ahead of time that it runs long, through
``BackgroundTool/mount``. Such a tool is mounted in
``ToolMount/Mode/background`` mode: each call returns a ``PendingRunEnvelope``
handle at once, and the work goes on behind it. Every other tool is mounted in
``ToolMount/Mode/runToCompletion`` mode and returns its result in band;
``ToolMount/timeout`` bounds the work.

The session pushes settlement to the model — the model never polls:

- ``respond(to:maxTokens:)`` and the streaming surfaces answer from their own
  submission, and return while a run is in flight.
- The terminal of a settled run is mail. The pump of the session delivers it
  to the model in a later submission, with no caller call, and it is also
  reported as ``SessionEvent/runSettled(_:)``.
- `status` and `wait` give an earlier look; they are not required.

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
- ``close()``

# ``FoundationModelsRouter/RoutedSession``

The public session surface, grouped by audience (tasks ^j0pp9yp, ^k0mecjp).

## Overview

A session has three audiences, and each one gets typed capabilities:

- **Apps and drivers** hold a `RoutedSession` and use the members below.
  They never touch the raw staging and backgrounding machinery — the session's
  `SessionOutbox` and `SessionMailbox` instances are internal wiring.
- **Tools** do not use this protocol at all. A running tool reads the
  ambient ``ToolContext`` and uses its capabilities:
  ``ToolContext/post(_:)``, ``ToolContext/progress(_:)``,
  ``ToolContext/elicit(_:)``, and ``ToolContext/isCancelled``.
- **Tool hosts** — a tool that shows the run plane to a model — read that
  plane through the same ambient context, never through a mailbox:
  ``ToolContext/backgroundRuns()``,
  ``ToolContext/wait(completionToken:seconds:)``, and
  ``ToolContext/cancel(completionToken:)`` (task ^k0mecjp).

## Long-running tools

A tool declares ahead of time that it runs long, through
``BackgroundTool/mount``. Such a tool is mounted as a
``BackgroundToolRunner``: each call returns a ``PendingRunEnvelope`` handle at once,
and the work goes on behind it. Every other tool is mounted as a
``RunToCompletionRunner`` and returns its result in band;
``ToolMount/timeout`` bounds the work.

The session pushes settlement to the model — the model never polls:

- ``respond(to:maxTokens:)`` awaits each background run and delivers its
  result in a further turn before it answers.
- The streaming surfaces return while a run is in flight. A run that settles
  is reported as ``SessionEvent/runSettled(_:)``, and the next
  ``dispatchNextPrompt()`` delivers its result to the model.
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
- ``transcript``

### Session-scoped events

- ``streamSessionEvents()``

### Prompt queueing and dispatch

- ``enqueue(prompt:)-(Transcript.Prompt)``
- ``enqueue(prompt:)-(String)``
- ``pendingPrompts()``
- ``replace(id:prompt:)``
- ``promptQueueDepth()``
- ``dispatchNextPrompt()``
- ``awaitQueuedWork()``

### Cancellation

- ``cancel(id:)``
- ``cancelPrompt(id:)``
- ``cancelCurrentTurn()``

### Elicitation answers

- ``respond(elicitationId:response:)``
- ``complete(elicitationId:)``

### Context and compaction

- ``contextFill``
- ``compact()``
- ``compact(prompt:)``
- ``compact(budget:)``
- ``compact(prompt:budget:)``

### Lifecycle and forking

- ``fork(workingDirectory:)``
- ``close()``
- ``awaitingUser(_:)``

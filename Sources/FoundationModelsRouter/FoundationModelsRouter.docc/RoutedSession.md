# ``FoundationModelsRouter/RoutedSession``

The public session surface, grouped by audience (tasks ^j0pp9yp, ^k0mecjp).

## Overview

A session has three audiences, and each one gets typed capabilities:

- **Apps and drivers** hold a `RoutedSession` and use the members below.
  They never touch the raw staging and parking machinery — the session's
  `SessionOutbox` and `SessionMailbox` instances are internal wiring.
- **Tools** do not use this protocol at all. A running tool reads the
  ambient ``ToolContext`` and uses its capabilities:
  ``ToolContext/post(_:)``, ``ToolContext/progress(_:)``,
  ``ToolContext/elicit(_:)``, and ``ToolContext/isCancelled``.
- **Tool hosts** — a tool that shows the run plane to a model — read that
  plane through the same ambient context, never through a mailbox:
  ``ToolContext/parkedRuns()``,
  ``ToolContext/wait(completionToken:seconds:)``, and
  ``ToolContext/cancel(completionToken:)`` (task ^k0mecjp).

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

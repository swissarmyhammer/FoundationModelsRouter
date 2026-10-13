# Session observer

Mirror one session's live state into SwiftUI, and draw the conversation from
that mirror (task ^tf6dwx1).

## Overview

``SessionObserver`` is the `@MainActor` and `@Observable` mirror of one
``RoutedSession``. A view holds one observer, gives it the events of each
answer, and reads the observer to draw the conversation. The observer does
the bookkeeping that a view would otherwise do by hand: it collects the text
fragments into rows, it tracks each tool call through its lifecycle, and it
adds up the cost of every answer.

Hold one observer for the whole life of the session. The observer observes
many answers, and ``SessionObserver/tokensIn`` and
``SessionObserver/tokensOut`` accumulate for that whole life.

The old name `SessionProjection` is a deprecated alias of ``SessionObserver``.
Use ``SessionObserver`` in new code.

## Bind an observer to a view

Give the observer the event stream of an answer with
``SessionObserver/apply(eventsFrom:)``. The call reads the stream to its end
and updates the observer on the main actor as each event arrives, so the view
redraws itself while the answer runs:

```swift
struct ConversationView: View {
    let session: any RoutedSession
    @State private var observer = SessionObserver()
    @State private var prompt = ""

    var body: some View {
        VStack {
            List(observer.transcript) { row in
                TranscriptRowView(row: row)
            }
            if observer.phase != .idle {
                ProgressView()
            }
            TextField("Ask something", text: $prompt)
                .onSubmit(send)
        }
    }

    private func send() {
        let text = prompt
        prompt = ""
        Task {
            try? await observer.apply(eventsFrom: session.streamEvents(to: text))
        }
    }
}
```

A driver that does its own work between events calls ``SessionObserver/apply(_:)``
with one ``SessionEvent`` instead, and reads the observer after each call. A
driver that reads ``RoutedSession/streamSessionEvents()`` gets each event in a
``SessionOutput``, and gives ``SessionOutput/event`` to the observer.

For a complete offline example that drives a scripted answer and then asserts
what the observer holds, read `ProjectionExampleTests` in the test target.
That file imports the router without `@testable`, so it proves the pattern
above needs the public surface alone.

## What the observer holds

``SessionObserver/transcript`` is the conversation so far, oldest first. Each
``SessionObserver/TranscriptEntry`` is `Identifiable`, so a view puts the
array straight into a `List` or a `ForEach`. A row carries one of four kinds:

- `text` — the answer text of the model, collected from a run of
  ``SessionEvent/textDelta(_:)`` events.
- `reasoning` — the reasoning trace of the model.
- `toolCall` — one ``ToolCallEntry``, with its live
  ``ToolCallStatus``.
- `compaction` — the result of a compaction that ran in the middle of an answer.

A row starts with a provisional id. When the session records the matching
transcript entry, the row adopts the durable id of that entry and reports it as
``SessionObserver/TranscriptEntry/sourceEntryId``. Use that id to join a row
back to the recorded transcript.

``SessionObserver/groupedRows`` is a second view over the same rows. It
attaches the reasoning rows that come immediately before a tool call to that
call, so a view can show the call and its reason as one disclosure group.

## What the observer reports

``SessionObserver/phase`` says where the session is in the answer under
observation. Bind it to show or hide a progress indicator, and to say what the
session is doing:

- ``SessionObserver/Phase/idle`` — no answer is under observation.
- ``SessionObserver/Phase/generating`` — the model is producing text.
- ``SessionObserver/Phase/runningTool`` — a tool call is in flight.
- ``SessionObserver/Phase/compacting`` — a compaction is running.

The phase returns to ``SessionObserver/Phase/idle`` when a submission ends,
and also when the stream finishes or throws.

``SessionObserver/currentSubmission`` is the submission that runs now, or
`nil` between submissions. ``SessionObserver/messagesAwaitingAnswer`` holds
the mail that a started submission delivered and that no answer
named yet, in delivery order. Show them as the messages in flight.

``SessionObserver/tokensIn``, ``SessionObserver/tokensOut``, and
``SessionObserver/contextFill`` carry the metered cost. Show them in a status
bar. The two token counts accumulate across every answer the observer
observed. The context fill is the most recent measurement, not a total.

## Start from a stored conversation

A restored session already has a transcript. Call
``SessionObserver/seed(from:)`` with that transcript before the first answer.
The call replaces the rows with the rows of the stored conversation and resets
every other value. A tool call that the stored transcript never answered is
marked ``ToolCallStatus/failed``, so a view never shows a spinner that cannot
stop.

## Topics

### The observer

- ``SessionObserver``
- ``SessionObserver/apply(eventsFrom:)``
- ``SessionObserver/apply(_:)``
- ``SessionObserver/seed(from:)``

### What a view reads

- ``SessionObserver/transcript``
- ``SessionObserver/groupedRows``
- ``SessionObserver/phase``
- ``SessionObserver/currentSubmission``
- ``SessionObserver/messagesAwaitingAnswer``
- ``SessionObserver/tokensIn``
- ``SessionObserver/tokensOut``
- ``SessionObserver/contextFill``

### The row types

- ``SessionObserver/TranscriptEntry``
- ``SessionObserver/Phase``
- ``SessionObserver/GroupedRow``
- ``SessionObserver/ToolCallGroup``
- ``ToolCallEntry``
- ``ToolCallStatus``

### The events behind it

- ``SessionEvent``
- ``SessionOutput``
- ``RoutedSession/streamEvents(to:maxTokens:)``
- ``RoutedSession/streamSessionEvents()``

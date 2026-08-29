# Session projection

Mirror one session's live state into SwiftUI, and draw the conversation from
that mirror (task ^tf6dwx1).

## Overview

``SessionProjection`` is the `@MainActor` and `@Observable` mirror of one
``RoutedSession``. A view holds one projection, gives it the events of each
turn, and reads the projection to draw the conversation. The projection does
the bookkeeping that a view would otherwise do by hand: it collects the text
fragments into rows, it tracks each tool call through its lifecycle, and it
adds up the cost of every turn.

Hold one projection for the whole life of the session. The projection observes
many turns, and ``SessionProjection/tokensIn`` and
``SessionProjection/tokensOut`` accumulate for that whole life.

## Bind a projection to a view

Give the projection the event stream of a turn with
``SessionProjection/apply(eventsFrom:)``. The call drains the stream and
updates the projection on the main actor as each event arrives, so the view
redraws itself while the turn runs:

```swift
struct ConversationView: View {
    let session: RoutedSession
    @State private var projection = SessionProjection()
    @State private var prompt = ""

    var body: some View {
        VStack {
            List(projection.transcript) { row in
                TranscriptRowView(row: row)
            }
            if projection.phase != .idle {
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
            try? await projection.apply(eventsFrom: session.streamEvents(to: text))
        }
    }
}
```

A driver that does its own work between events calls ``SessionProjection/apply(_:)``
with one ``SessionEvent`` instead, and reads the projection after each call.

For a complete offline example that drives a scripted turn and then asserts
what the projection holds, read `ProjectionExampleTests` in the test target.
That file imports the router without `@testable`, so it proves the pattern
above needs the public surface alone.

## What the projection holds

``SessionProjection/transcript`` is the conversation so far, oldest first. Each
``SessionProjection/TranscriptEntry`` is `Identifiable`, so a view puts the
array straight into a `List` or a `ForEach`. A row carries one of four kinds:

- `text` — the answer text of the model, collected from a run of
  ``SessionEvent/textDelta(_:)`` events.
- `reasoning` — the reasoning trace of the model.
- `toolCall` — one ``ToolCallEntry``, with its live
  ``ToolCallStatus``.
- `compaction` — the result of a fold that ran in the middle of a turn.

A row starts with a provisional id. When the session records the matching
transcript entry, the row adopts the durable id of that entry and reports it as
``SessionProjection/TranscriptEntry/sourceEntryId``. Use that id to join a row
back to the recorded transcript.

``SessionProjection/groupedRows`` is a second view over the same rows. It
attaches the reasoning rows that come immediately before a tool call to that
call, so a view can show the call and its reason as one disclosure group.

## What the projection reports

``SessionProjection/phase`` says where the session is in the turn under
observation. Bind it to show or hide a progress indicator, and to say what the
session is doing:

- ``SessionProjection/Phase/idle`` — no turn is under observation.
- ``SessionProjection/Phase/generating`` — the model is producing text.
- ``SessionProjection/Phase/runningTool`` — a tool call is in flight.
- ``SessionProjection/Phase/compacting`` — a fold is running.

The phase returns to ``SessionProjection/Phase/idle`` when the turn ends, and
also when the stream finishes or throws.

``SessionProjection/tokensIn``, ``SessionProjection/tokensOut``, and
``SessionProjection/contextFill`` carry the metered cost. Show them in a status
bar. The two token counts accumulate across every turn the projection
observed. The context fill is the most recent measurement, not a total.

## Start from a stored conversation

A restored session already has a transcript. Call
``SessionProjection/seed(from:)`` with that transcript before the first turn.
The call replaces the rows with the rows of the stored conversation and resets
every other value. A tool call that the stored transcript never answered is
marked ``ToolCallStatus/failed``, so a view never shows a spinner that cannot
stop.

## Topics

### The projection

- ``SessionProjection``
- ``SessionProjection/apply(eventsFrom:)``
- ``SessionProjection/apply(_:)``
- ``SessionProjection/seed(from:)``

### What a view reads

- ``SessionProjection/transcript``
- ``SessionProjection/groupedRows``
- ``SessionProjection/phase``
- ``SessionProjection/currentTurn``
- ``SessionProjection/tokensIn``
- ``SessionProjection/tokensOut``
- ``SessionProjection/contextFill``

### The row types

- ``SessionProjection/TranscriptEntry``
- ``SessionProjection/Phase``
- ``SessionProjection/GroupedRow``
- ``SessionProjection/ToolCallGroup``
- ``ToolCallEntry``
- ``ToolCallStatus``

### The events behind it

- ``SessionEvent``
- ``RoutedSession/streamEvents(to:maxTokens:)``

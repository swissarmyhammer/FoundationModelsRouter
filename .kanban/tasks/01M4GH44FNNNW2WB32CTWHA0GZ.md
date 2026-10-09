---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gk1xn5zn7z7v3ppp396nad
  text: |-
    ## Dependency status (2026-10-09)

    The FoundationModelsExtras task ^1vhftw2 is done. It is in local commit 23974f0 on `main` in FoundationModelsExtras. This commit is NOT pushed.

    ### Build blocker

    `Package.swift:158-161` gets FoundationModelsExtras from `git@github.com:swissarmyhammer/FoundationModelsExtras.git`, branch `main`. Thus this package cannot see commit 23974f0 until one of these steps occurs:
    - Someone pushes commit 23974f0 to the remote.
    - The implementer uses the local Extras checkout, for example `swift package edit FoundationModelsExtras --path ../FoundationModelsExtras`. Do not commit a local path into `Package.swift`.

    ### API notes from the Extras session

    - New types: `ToolDisplayEvent`, `ToolDisplayContent`, `ToolDisplayEvent.ToolKind`, `ToolDisplayEvent.Location`. These types are not `Codable`. This agrees with the rule "do not journal display events".
    - `OperationEventSink.post(display:)` has a default implementation that does nothing. `SessionOutbox` must override it.
    - `ToolContext.post(display:)` takes a `ToolDisplayEvent.Kind`. It stamps the tool, the op and the completion token.
    - A nested mount stamps display events again under the outer token.
  timestamp: 2026-10-09T15:03:39.429889+00:00
- actor: claude-code
  id: 01m4gpcdm62sb396y6aeat1kc8
  text: |-
    ## Extras follow-up ^jt7qx6k (2026-10-09)

    The FoundationModelsExtras task ^jt7qx6k is done. It is in local commits ba381a0, 315c17b and 5ca30c9 on `main` in FoundationModelsExtras. These commits are NOT pushed. The build blocker in the comment before this one applies to these commits too.

    ### Decisions from the Extras session that change this task

    1. A display event resets the run timeout, the same as a progress event.
    2. Display events that a tool emits in the background grace period are NOT withdrawn. Only staged operation events are withdrawn. Thus Router must deliver display events live, also when a run settles inside the grace period.

    ### Added tests

    - A display event that a tool emits in the grace period gets to `streamEvents` subscribers, also when the run settles inside the grace period.
    - A display event resets the run timeout, the same as a progress event.
  timestamp: 2026-10-09T16:01:49.190151+00:00
- actor: claude-code
  id: 01m4h7pt0f9sz77j7z0ga46eja
  text: |-
    ## Build blocker removed (2026-10-09)

    The user pushed FoundationModelsExtras `main`. The commits for Extras ^1vhftw2 and ^jt7qx6k are now on the remote. Before you build this task, run `swift package update FoundationModelsExtras` so that `Package.resolved` gets the display-lane commits. Do not put a local path in `Package.swift`.
  timestamp: 2026-10-09T21:04:35.343476+00:00
position_column: todo
position_ordinal: '80'
title: Forward tool display events as SessionEvent.toolDisplay
---
## Goal

Forward the display-only tool output from FoundationModelsExtras to Router subscribers. FoundationModelsACPAgent uses this to send ACP v2 `tool_call_content_chunk` updates (see `Agent/EventProjection.swift` in that repo). Terminals are out of scope.

## Dependency

This task depends on the FoundationModelsExtras task ^1vhftw2 (01M4GH3SXGTK24GQS301VHFTW2), "Add a display-only event lane for tools". That task adds `ToolDisplayEvent` and `OperationEventSink.post(display:)`. It is on the FoundationModelsExtras board, so this board cannot link to it. Do not start this task before that task is done.

## Work

1. Make `SessionOutbox` implement `post(display:)`. Send the event to `invocationObserver`. Use the same path as invocation records (`SessionOutbox.swift:314-326`).
2. Add a new case `SessionEvent.toolDisplay(ToolDisplayEvent)`.
3. Emit this event on both streams through `deliverLive`. See `RoutedSessionActorRunJournal.swift:216,224` for how the run journal delivers records live.
4. Do not stage display events for the next submission.
5. Do not combine display events by `(tool, correlationID, plan id)`. Progress events are combined in this way (`SessionOutbox.swift:171-180, 248-280`). Display events must not be.
6. Do not journal display events.

## Tests

- A display event from a tool gets to `streamEvents` subscribers. It arrives in the correct order with the progress events from the same tool.
- The input of the next submission does not contain the display event.

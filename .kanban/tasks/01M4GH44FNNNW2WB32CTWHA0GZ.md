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
- actor: claude-code
  id: 01m4hb9v526xp769jqw5gc3def
  text: |-
    ## Research (implement)

    - `swift package update FoundationModelsExtras` resolved Extras `main` at 5bc870a. This commit holds 23974f0 (display lane) and ba381a0 (helpers, timeout reset, no withdraw). `Package.resolved` is in `.gitignore`, so git shows no change for it.
    - Extras `RunEventFunnel.post(display:)` increments the timeout reset count and sends the event upstream in order with the other events of the run. Thus the timeout reset is Extras behavior. Router must only forward the event.
    - Extras `StagedEventWithdrawing` withdraws only staged `OperationEvent` values. A display event never goes into the outbox stage, so a run that settles inside the grace period keeps its display events if Router delivers them live.
    - Order: the funnel waits for each upstream post. `SessionOutbox.post(event:)` waits for its journal write, and the journal write calls `deliverLive`. Thus a display event that goes straight to `invocationObserver` -> `deliverLive` keeps the post order with the progress events of the same run.
    - Plan: add `deliver(display:)` to `ToolInvocationObserver`; `SessionOutbox.post(display:)` forwards it; `RoutedSessionActor.deliver(display:)` calls `deliverLive(.toolDisplay(event))`. Add the new case to each exhaustive switch: `SessionProjection`, `SessionAnswer`, `Examples/MultiModelGeneration/main.swift`, `ScriptedToolAnswerComparisonTests`, `IntegrationTests/.../RealToolAnswerComparisonTests`. The test conformer `ReportRecordingObserver` in `SessionOutboxTests` must get the new method.
  timestamp: 2026-10-09T22:07:24.834015+00:00
- actor: claude-code
  id: 01m4hcg8zbka8aj9nyg5g4fhqa
  text: |-
    ## Implementation landed (not committed)

    TDD order: the new tests failed first (compile error for the missing API, then 7 runtime failures because no display event arrived), then passed after the change.

    ### Production
    - `Hosting/OperationVocabulary.swift`: `@_exported import struct FoundationModelsExtras.ToolDisplayEvent` and `enum ToolDisplayContent`. This is the original-declaration form (not a typealias), so a router user can name `ToolDisplayEvent.Kind` in a public declaration.
    - `Session/SessionEvent.swift`: new case `toolDisplay(ToolDisplayEvent)`.
    - `Session/OperationEventJournal.swift`: `ToolInvocationObserver.deliver(display:)`.
    - `Session/SessionOutbox.swift`: `post(display:)` forwards to `invocationObserver`. No stage, no merge, no journal write.
    - `Session/RoutedSessionActorRunJournal.swift`: `deliver(display:)` calls `deliverLive(.toolDisplay(event))`, so the event goes to the answer stream inside an answer and to `streamSessionEvents()`.
    - Exhaustive switches got the new case: `SessionProjection`, `SessionAnswer` (no-op arms), `Examples/MultiModelGeneration/main.swift`, `ScriptedToolAnswerComparisonTests`, `IntegrationTests/.../RealToolAnswerComparisonTests`.
    - Docs: `RoutedSession.md` (DocC) and `generation-queue.md` section 5.4 and the event set.

    ### Tests
    - `SessionOutboxTests`: 3 new tests (forward, no merge in post order, no stage and no journal). The test observer `ReportRecordingObserver` is now `DeliveryRecordingObserver` and also records display events.
    - New `ToolDisplayDeliveryTests` (4 tests): order with progress on `streamEvents(to:)`; next submission input holds the progress line and not the display text; display event of a run that settles inside the settle period arrives on `streamSessionEvents()`; 8 display beats at 100 ms with a 0.5 s timeout run past the timeout.
    - New `ToolDisplayEventPublicSurfaceTests` (plain router import).

    ### Discoveries
    - The background runner posts its own progress event (the pending envelope) on the run, so the order test keeps only the posts of the tool.
    - The timeout reset is Extras behavior (`RunEventFunnel.post(display:)` increments `resetCount`). Router only forwards.
    - `IntegrationTests/Package.resolved` is local and ignored too. It pinned Extras at c18a9aa, so I ran `swift package --package-path IntegrationTests update FoundationModelsExtras` (now 5bc870a). Nothing to commit for it.
    - One full run had an intermittent failure in `WatchStopUsageTests` (usage.tokensOut 151 vs generation call sum 152). It passed alone. Not related to this task. New task ^0depfwy records it.
  timestamp: 2026-10-09T22:28:24.171560+00:00
- actor: claude-code
  id: 01m4hcgkjnz30g3ae1r3wzn831
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (no compiler warnings); new tests red then green (`ToolDisplayDeliveryTests` 4/4, `SessionOutboxTests` 49/49 with the 3 new ones, `ToolDisplayEventPublicSurfaceTests` 1/1); full `swift test`: 1570 tests, 1 intermittent failure in `WatchStopUsageTests` that passed alone (6/6) and is not related (task ^0depfwy); `swift build --build-tests --package-path IntegrationTests` clean. Files: 13 modified, 2 new test files.
    - next: /review. Task stays in doing. Nothing committed.
  timestamp: 2026-10-09T22:28:35.029424+00:00
- actor: claude-code
  id: 01m4hcne3408pbd9t8wk0zs537
  text: |-
    ### test — green
    - evidence: swift build exit 0. swift test exit 0. Main target: 1570 tests in 197 suites passed, 0 failures. Other targets: 24 tests and 19 tests passed. 0 skipped.
    - WatchStopUsageTests did not fail in this run.
    - The 2 known issues are from withKnownIssue in BoundedWaitTests and RealModelHarnessTests. Each one checks that an issue is recorded. They are not skips.
    - The only warning is a build-system message, "missing creator for mutated node" for the mlx-swift Cmlx bundle. It is not Router code.
    - next: review
  timestamp: 2026-10-09T22:31:13.252675+00:00
position_column: doing
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

---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4dv7215tzd4mt7989vcebcw
  text: |-
    ## Extras dependency and final names

    This task depends on Extras task 01M4DV675C3BNZHBNFNPFQFMJT (FoundationModelsExtras board, not this board). That task is not implemented yet. Do not start this task before that Extras change is available.

    Final names from the Extras session:

    - `public struct PlanSnapshot: Sendable, Codable, Equatable` (FoundationModelsExtras, OperationEvents/PlanSnapshot.swift). Fields: `id: String`, `entries: [PlanSnapshot.Entry]`. `entries` is always the full list. An update replaces the plan that has the same `id`.
    - `PlanSnapshot.Entry`: `content: String`, `priority: PlanSnapshot.Priority`, `status: PlanSnapshot.Status`.
    - `PlanSnapshot.Priority`: `.high`, `.medium`, `.low`.
    - `PlanSnapshot.Status`: `.pending`, `.inProgress` (raw value "in_progress"), `.completed`, `.cancelled`.
    - `OperationEvent.plan: PlanSnapshot?`. It is the last init parameter. Its default is nil. Only `.progress` events set it. An old record that has no `plan` key decodes as nil.
    - `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil)`. `detail` stays a short text line for the model. The model must never get `plan`.
    - There is no new `OperationEventKind`.

    Note for step 4: a plan update replaces the plan that has the same `id`. Thus the restore path must replay the last plan for each plan `id`.
  timestamp: 2026-10-08T13:28:33.061708+00:00
position_column: todo
position_ordinal: '80'
title: Send .progress operation events live as SessionEvent.runProgress and keep the plan out of the model text
---
## Origin

The FoundationModelsACPAgent session sent this request. The user approved the design. A tool must send one-way updates through Router and the ACP agent to the client, in the same way as elicitation. The first use is an ACP agent plan (https://agentclientprotocol.com/protocol/v2/agent-plan).

## Dependency

This task depends on the Extras base task (session foundationmodelsextras-98). That task adds:
- a `PlanSnapshot` type (id, full list of entries with content, priority and status),
- the field `OperationEvent.plan: PlanSnapshot?`,
- `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil)`.

The Extras session will send the final names. Use those names. Do not start before the Extras change is available. The ACP agent task depends on this task.

## Steps

1. Live delivery.
   - Add `SessionEvent.runProgress(OperationEvent)`.
   - In `RoutedSessionActorRunJournal.record(event:)` (near line 36), call `deliverLive(.runProgress(event))` for each `.progress` event. Do this in the same way as for `.message` and `.elicitation`. Now Router writes `.progress` to the journal, but it does not send it live.
   - Add the new case to each exhaustive switch (SessionProjection.swift:183, SessionAnswer.swift:182, and all other switches that the compiler shows).
2. Keep the plan out of the model text.
   - `OperationEventSegment.renderedLine(for:)` (near line 39) must use only `detail`. It must never use `plan`.
   - Examine every other path that changes a pending event into model input. Make sure that no path puts `plan` into model input.
3. Merge rule (SessionOutbox.swift:75-83).
   - Now a progress event replaces the older event that has the same `tool` + `correlationID`.
   - Add "has a plan" to that key. Then a plan replaces only an older plan, and text progress replaces only older text progress. One code-mode run can send both shell output and a plan.
   - Find which `tool` name the events of a code-mode `tools.*` call carry. Record the result on this card.
4. Durability.
   - The open progress row is in memory only (RoutedSessionActorRunJournal.swift:22-25).
   - A progress event that has a plan must go to disk immediately. It must not stay in the open row. Then session/load can replay the last plan.
   - Examine the restore path (SessionTreeRestoration.swift:411 and 606) with `plan` set. Make sure that restore keeps the plan.

## Acceptance

- A `.progress` event goes live to the client as `SessionEvent.runProgress`.
- No model input contains plan data.
- A plan event and a text progress event of the same tool and correlation ID do not replace each other.
- After a restore, the last plan is available for replay.
- Tests cover each item above.
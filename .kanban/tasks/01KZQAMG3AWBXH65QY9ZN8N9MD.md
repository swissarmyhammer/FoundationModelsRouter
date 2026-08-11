---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzqaqhedh3w1e7y0q51tc9ns
  text: |-
    ### Data model, from the user — this constrains the entry shape

    A tool call is not one entry with one outcome. It produces **many entries over time** — notifications, progress, completion, errors — and the model is:

    - **The transcript stays linear.** Flat, append-only, in the order things actually happened. No nesting in the data model.
    - **Every tool-related entry carries the originating tool call's id as a parent reference.** That is what relates a notification, a progress update, an error and a completion back to the call that started them.
    - **Views group by parent as needed.** Hierarchy is a rendering concern, not a storage concern. The UI collapses a call and its children into one block; the transcript never nests them.

    Consequences worth stating so they are not discovered later:

    1. **Interleaving is correct, not a bug.** A detached run's progress and completion will appear between entries belonging to other turns, because that is when they happened. Do not buffer them to keep a call's entries contiguous — that would falsify the order to flatter the renderer. The parent id is what lets the view regroup them.
    2. **Do not collapse a call's lifecycle into a single mutated entry.** Append a new entry per event rather than rewriting one in place. An append-only log is what makes the transcript replayable and diffable, and diffing transcripts is our test strategy.
    3. **Ordering is the record.** Position in the transcript is meaningful; nothing may be reordered or deduplicated in a way that changes it. If progress events are coalesced, coalescing must happen before an entry is appended, never by rewriting appended history — and it must be documented.
    4. **The parent id must be the same identity the model was given.** The `completionToken` handed back in `{"pending":true,"completionToken":...}` is the natural parent key, so the model's own reference and the transcript's parent reference are one identity space rather than two.

    This ties directly to `^w8dzvee`'s D1: that defect exists because a completion carried an id from a different identity space than its call. A parent-id model makes the correct thing the only expressible thing — an entry without a valid parent is malformed, rather than merely unhelpful.

    It also means the deterministic `sessionId:messageNumber` moniker pays off twice: entry identity is legible in a diff, and a parent reference reads as a pointer to a visible position rather than an opaque token.
  timestamp: 2026-08-11T02:34:22.541895+00:00
position_column: todo
position_ordinal: 8b80
title: Detached tool runs need a path back into the transcript — today they return as prompt text
---
Router exists so a long-running tool does not block the session: Apple's tools are `async` in signature but the session stalls until they return, so `DetachingTool` parks the run, hands the model `{"pending":true,"completionToken":...}`, and lets the turn finish. The parking works. **The result has no proper way back.**

Established by read-only investigation on commit `ee5b881`.

## The defect

A detached run's completion is delivered as **plain-text preamble folded into the next turn's prompt** (`Session/RoutedSessionActorTurnExecution.swift:122`, `:728-731`, `composedPrompt`). Three consequences follow:

1. **The model sees a tool result as user text.** It arrives in the prompt, not as a tool output entry, so nothing marks it as having come from a tool.
2. **The transcript never records it as a tool result.** The parked call has no completion in the transcript, so the transcript is an incomplete record of what happened.
3. **A transcript-rendering UI has nothing to draw.** Our UIs render transcripts; a tool that started, ran for minutes, and finished leaves no transcript trace of finishing.

By contrast, **in-turn** tools do land properly: `.toolCalls` and `.toolOutput` entries, from which `.toolCall`/`.toolStatus` events are derived (`Session/RoutedSessionActorRecording.swift:377`, `:383`).

So the notification story works for short tools and breaks exactly when a tool is long enough to need detaching — the case Router was built for.

## The shape of the fix

**Give the detached result a path back into the transcript**, not a parallel event channel. When a parked run completes, its outcome should become a transcript entry that references the originating call's identity (the `completionToken` that was handed to the model), so:

- the transcript is a complete record — every call that started has a recorded outcome;
- a transcript-rendering UI draws the completion with no special case;
- the model reads it as tool output rather than as user prose;
- events, if still needed, are derived from the transcript delta like every other event, rather than being a second data model.

Apple's `Transcript` may not have a case for "a tool that completed after its turn ended" — that is what the custom transcript entry mechanism is for. Design that entry deliberately: it must carry the call identity and the outcome, and must not become a stringly-typed dumping ground, which would be the parallel layer again wearing a transcript's clothes.

Existing plumbing worth reusing rather than duplicating:
- `SessionMailbox` already tracks parked runs by completion token and holds `latestProgressDetail` (`Hosting/SessionMailbox.swift`), so progress is anticipated.
- `SessionOutbox.events` already coalesces `.progress` (`Session/SessionOutbox.swift:149-164`) — decide whether transcript entries coalesce too, and record why.
- `streamSessionEvents()` exists as a session-wide fan-in but carries only `.discoveryPrimingFailed` today (`RoutedSessionActorGeneration.swift:204-214`, `RoutedSessionActor.swift:397`, `:229-233`).

## Acceptance Criteria

- [ ] A detached run's outcome lands in the transcript as a real entry, correlated to the call that parked, without requiring another user prompt to be sent
- [ ] The transcript alone is a complete record: every parked call has a recorded outcome — completed, failed, or cancelled
- [ ] A transcript-rendering client shows the completion with no special-case code path
- [ ] Progress is representable, and its coalescing behaviour is documented — whatever is chosen
- [ ] The model still receives the tool's result; if the text-preamble path is removed or changed, prove the model still sees the outcome, and record the decision
- [ ] Ungated `swift test` green

## Notes
- Overlaps `^w8dzvee` (in-turn tool events, D1's id correlation) and `^way106d` (event identity for an async client). All three touch how tool identity is represented — coordinate rather than inventing three schemes.
- Aligns with the standing direction: stream transcript entries, do not invent a parallel layer of data types.</description>
#phase-1
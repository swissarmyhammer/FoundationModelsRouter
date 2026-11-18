---
assignees:
- claude-code
depends_on:
- 01M7QTQCW62ZNN9CXFTVE3TV8Y
position_column: todo
position_ordinal: '8280'
title: A message to an archived session goes to its inbox (D204)
---
## Goal

A message to an archived session goes to its inbox, and the session stays archived. Decision D204 (`TestudoApp/features/decisions.md`, commit 9281f9c). Brief: `../.briefs/archive/router-brief.md`, item 3; Extras rule in `extras-brief.md` part 3.

## Depends on

FoundationModelsExtras (the D204 change: the note `archived` in the `reason` of a `sent` receipt). The dependency on the unarchive task is only the order of work.

## Current behavior

The resolver refuses a session id of an archived session with the reason `archived` (`Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift:39-40`, `:56`). A short id and a slug do not match an archived session.

## Change

- In `SessionAddressResolution.reaching(session:)` (`:56`), an archived target is the same as a recorded target: `.sendToRecorded(target.id)`.
- The receipt is `sent` with the note `archived` in `reason`. The directory sends `messageQueued` (the rule of ^gfnste0). The session stays archived and starts no turn.
- An archived session that is live (opened with `session/load` and not unarchived): decide and write down the rule. It must stay archived and start no turn.
- Keep: a short id and a slug do not match an archived session (D199 (d)). Only the full id reaches an archived session. `@<agent>` with only an archived session of that agent starts a new session (D199 (e)).
- A user message with no source session to an archived session: the same rule as for a recorded session (refused with `userNeedsLiveSessionReason`), unless the Extras contract says otherwise.

## Tests

- [ ] A send by full id to an archived session: receipt `sent`, reason `archived`, one `messageQueued`, a file in `inbox/`, the state stays `archived`.
- [ ] A send by short id or slug that matches only an archived session: no match, not a delivery to the archived session.
- [ ] After an unarchive and an open, the message reaches the session.
- [ ] Update the existing tests that expect a refusal with the reason `archived`.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d204
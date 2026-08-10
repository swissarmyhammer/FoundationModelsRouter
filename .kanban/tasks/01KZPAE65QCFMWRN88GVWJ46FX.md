---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: A failing tool's error never reaches the model — the SDK aborts the turn on both Router surfaces
---
Found while building the parity harness in `^vhjhaey`. Row 4 of that harness — "a call that throws" — failed on first run, and the reason is not a Router defect.

## What is actually true

**The two surfaces agree.** `respond(to:)` and `streamEvents(to:)` behave identically here, so parity is not violated and `git diff -- Sources` was empty throughout.

What is false is the row's premise. When a mounted tool throws, `LanguageModelSession`:

- aborts the turn at the failed call,
- raises `LanguageModelSession.ToolCallError` to the **caller**,
- produces one model turn, no answer text, and **no `.toolOutput` entry for the failed call**.

So nothing in the transcript ever tells the model that its call failed. The model cannot see the error, cannot retry, cannot explain the failure to the user, and cannot route around it.

## Why this may matter

A host moving from a plain `LanguageModelSession` onto `RoutedSession` inherits this. Any product behaviour that assumes "the model will notice the tool failed and try something else" is unavailable today on either surface. Whether that is acceptable is a product decision, not a test decision — which is why this is filed rather than fixed.

Note this is Apple SDK behaviour, not Router's. A fix, if wanted, would have to be a Router-side decision to catch the tool error, synthesise a `.toolOutput` describing the failure, and continue the turn — which changes what the model sees and is not a small call to make quietly.

## Current state

`^vhjhaey`'s row 4 now **locks the behaviour both surfaces really share**, so it is not a hole in coverage:

- if a future change makes only one surface start or stop aborting, that row fails;
- if the SDK later starts delivering the error to the model, that row fails and should be updated deliberately.

## Acceptance criteria

- [ ] Decide whether Router should surface a failed tool call to the model rather than aborting the turn — and record the decision and its reasoning, even if the decision is "no"
- [ ] If yes: catch the tool error, synthesise a transcript entry the model can read, and continue the turn; prove it by asserting the model's answer references the failure by content, not by event count
- [ ] If yes: `^vhjhaey`'s row 4 is updated from "both abort" to the new contract, and both surfaces still agree
- [ ] If no: leave `^vhjhaey`'s row 4 as the lock and note here why aborting is the right behaviour
- [ ] `swift test` green either way

## Notes

- Do NOT run gated integration tests (`FM_ROUTER_INTEGRATION_TESTS=1`, `MULTITOOL_INTEGRATION=1`) — 27B model, 8–11 minutes.
- Never run `swift format` / `swiftformat` in this repo.
- Harness caveat worth knowing: `String(describing:)` on a `ToolCallError` prints the whole decorator chain including the session's per-run ULID. `^vhjhaey` normalises it to `"<tool name>: <underlying error>"`; anything comparing these errors must do the same or it will be flaky.
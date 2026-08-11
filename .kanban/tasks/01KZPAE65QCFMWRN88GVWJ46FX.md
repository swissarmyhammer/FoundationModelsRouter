---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzq8h097649n5pha4vezh7gw
  text: |-
    ### Decision (AC#1): NO — Router should not synthesise a tool-failure entry by default. Keep aborting.

    Recorded with reasoning, as the card requires, including why the alternative was rejected.

    **The reasoning.**

    1. **Router's contract is parity with `LanguageModelSession`, and that parity is load-bearing.** `^vhjhaey` built a table-driven harness whose whole purpose is to assert the two surfaces behave identically, and a host migrating from a plain `LanguageModelSession` onto `RoutedSession` is entitled to identical semantics. Synthesising a `.toolOutput` the SDK never produced makes Router's transcript diverge from the SDK's for the same turn. That is a behaviour change hosts cannot see coming and cannot opt out of.

    2. **A synthesised `.toolOutput` is a lie in the one place the model trusts most.** The entry kind means "the tool ran and returned this". Using it to carry "the tool threw" teaches the model that a failed call produced a result. That is a worse failure mode than the current one: today the model is silent about a call it could not complete; under the change it may confidently report a fabricated outcome. The transcript is the model's ground truth and should not carry a fiction.

    3. **The error is not lost today — it is delivered to the caller.** `LanguageModelSession.ToolCallError` is raised to the host, which is the layer that actually knows whether a retry is safe, whether the failure is user-visible, and whether a different tool should be tried. Moving that decision into Router takes it away from the host and hard-codes one recovery policy for every consumer.

    4. **It is Apple SDK behaviour, not a Router defect.** The card establishes this and `git diff -- Sources` was empty throughout the investigation. Router working around an SDK behaviour silently is how a wrapper accumulates divergence that nobody can later explain.

    **What would change the answer.** If a host demonstrates a real agentic flow that needs in-turn recovery, the right shape is an **explicit opt-in policy** on the session — a caller-supplied "on tool failure" behaviour, defaulting to today's abort — not a silent default change. That keeps parity the default and makes divergence a deliberate, visible choice. Filing that as a new card is the correct route if the need materialises; it should not ride in under this card.

    **AC#4 — `^vhjhaey`'s row 4 stays as the lock.** Aborting is the right behaviour because it is the SDK's actual behaviour and Router's job here is to report it faithfully, not to paper over it. Row 4's value is exactly that it fails loudly if either surface diverges, or if a future SDK release starts delivering the error to the model — at which point the row should be updated deliberately rather than discovered by accident.

    **AC#2/#3 do not apply** (they are conditional on "yes").

    This decision is reversible and cheap to revisit; it is recorded here so the next reader does not re-open it without new information.
  timestamp: 2026-08-11T01:55:51.207096+00:00
position_column: done
position_ordinal: ff8780
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
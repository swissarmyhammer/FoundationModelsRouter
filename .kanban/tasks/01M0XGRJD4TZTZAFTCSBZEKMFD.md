---
assignees:
- claude-code
depends_on:
- 01M0XGQCF19BT6PM14919C9VV4
- 01M0XH9NMH6DYRNZDR06858XAS
position_column: todo
position_ordinal: '8380'
title: Split the engine into two small wrappers; a background call always returns the handle
---
## What
`DetachingTool.swift` is ~1,600 lines because one type multiplexes two behaviors through a timing race. Replace it with two small, single-purpose types in `Sources/FoundationModelsRouter/Hosting/` (background vocabulary, no "detach" in new names):

- [ ] `RunToCompletionTool` (thin): runs the wrapped tool's body, returns its value. `timeout` expiry throws one named error to the model. Owns correlation and event plumbing, nothing else.
- [ ] `BackgroundTool`: `call(arguments:)` starts the body, tracks the run in `SessionMailbox` at once (`track(tool:op:kind:completionToken:settling:canceler:)`), and returns the `PendingRunEnvelope` immediately — on every call, also when the body completes in microseconds. Keeps: the timeout watcher (progress resets it, elicitation suspends it, expiry cancels and settles as `timedOut`), the canceler with `RunKind` honesty, and exactly one terminal event per run. Uses the generation-permit rule from task ^6858xas.
- [ ] Delete the soft-deadline race and its claim arbitration (the `RaceGate` window use at the old `DetachingTool.swift:1001` area). Keep the natural-settlement-versus-timeout arbitration — that race is real.
- [ ] Rewrite the `PendingRunEnvelope` `next` text: the run continues in the background; the session reports the result when the run settles; `wait` with the `completionToken` collects it earlier.
- [ ] Keep `PendingRunEnvelope`, `SessionMailbox`, `ToolContext`, and the journal contract unchanged in shape — only their callers change. Update the doc-only `waitSeconds` mentions in `Concurrency/RaceGate.swift:16`, `Hosting/ToolContext.swift:45`, `Hosting/SessionMailbox.swift:309`.

## Acceptance Criteria
- [ ] A background tool call returns a `PendingRunEnvelope` on every call. A test proves it, with a body that completes instantly.
- [ ] `rg 'waitSeconds' Sources` returns no match at all.
- [ ] The exactly-one-terminal-event invariant holds across natural settle, cancel, timeout, and `close()` sweep — existing tests stay green.
- [ ] The two new files together are far smaller than the old engine; the old `DetachingTool` type is gone.
- [ ] `swift build --build-tests` and the full suite are green.

## Tests
- [ ] Rewrite the race cases in `Tests/FoundationModelsRouterTests/DetachingToolTests.swift` as immediate-handle cases; split the file to match the two new types.
- [ ] Simplify fixtures that used `waitSeconds: 0` (`detachAtOnceMount` in `DeclaredRunKindTests.swift`, `RegisteredJournalOpTests.swift`) — background mode now does this always.
- [ ] Run `swift test` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
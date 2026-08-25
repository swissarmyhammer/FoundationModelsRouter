---
comments:
- actor: claude-code
  id: 01m0v9tfhd7cc6j1ytq7nkv8gy
  text: |-
    ### Research

    Read the seam end to end.

    - `Sources/FoundationModelsRouter/Hosting/ToolContext.swift` — `init(stamping:sessionID:mailbox:sink:completionToken:isCancelled:)` makes one `stamp` string and fills both `tool` and `op`. The explicit `init(sessionID:mailbox:sink:tool:op:completionToken:isCancelled:)` is public and takes them apart, but it needs `SessionMailbox`, and `ToolContext.mailbox` is internal.
    - `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift` — the two decorators that call the stamping initializer are `DetachingTool.call(arguments:)` and `ContextBindingTool.call(arguments:)`. Both then build a `ToolInvocationRecord` from `context.tool`/`context.op`, and `DetachingTool.detach(...)` parks with `tool: context.tool, op: context.op`.
    - The two public entry points a registration site reaches are `ToolDetachment.wrapping(tool:inheriting:sink:configuration:)` and `ToolDetachment.wrapping(tool:sessionID:mailbox:sink:configuration:)`.
    - `ToolDetachment.sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)` (in `Session/ToolOutputCapping.swift`) is internal and is Router's own mount. The card names only the two `wrapping` overloads, so `sessionMounted` keeps its shape and takes the absent-op default.

    ### The plane question, answered from the code

    `ToolContext.post(_:)` re-stamps every event it forwards with the OUTER context's `tool`/`op`. A registration site outside this module mounts an inner tool with `wrapping(tool:inheriting:sink:...)` and hands it a sink that forwards through `ToolContext.post(_:)` — that is exactly what the `inheriting` doc says the `sink` parameter is for. So an inner `tools.*` call inside a `runCode` snippet reaches the session outbox carrying the ENCLOSING run's op.

    The declared op therefore surfaces on the RUN PLANE, and there only:

    - `SessionMailbox.park(tool:op:...)` is called with `context.op` directly, so `ParkedRun.op` carries it.
    - `ToolInvocationRecord` is built from `context.op` and posted through `OperationEventSink.post(invocation:)`, a delivery-only route that takes no part in the funnel's re-stamping, so the record carries it.
    - The `OperationEvent`s of the inner run go through the funnel to the enclosing context, which re-stamps them, so the enclosing snippet's event journal never shows the inner op.

    That answer goes into the doc comment.

    ### Rules loaded

    `dump validators` over a `.swift` path: code-hygiene, code-security, completeness, duplication, reuse, swift, test-integrity — 55 rules, read whole. The two that shape this edit most: swift/doc-parameter-naming (a `- Parameter <name>:` key names the INTERNAL parameter name) and code-hygiene/missing-docs (every public item documented).

    ### Plan

    `/tdd`: a new suite that reaches the seam through the PUBLIC surface alone — the file imports `FoundationModelsRouter` without `@testable`, so a route that needs an internal symbol cannot compile. Then the seam itself: an optional `op` on the stamping initializer, carried by both decorators and both `wrapping` overloads, with `nil` (and an empty string) falling back to today's one-string stamp.
  timestamp: 2026-08-25T01:51:09.869433+00:00
- actor: claude-code
  id: 01m0vaj2xk6j2hf5xemct0bkqr
  text: |-
    ### The seam, as built

    `/tdd`, red first. The new suite went in before the seam existed and the build refused it with three `extra argument 'op' in call` errors — one for each `ToolDetachment.wrapping(tool:inheriting:sink:op:configuration:)` call. That is the only red a new parameter can give in Swift, so it is the red that was watched.

    Then the seam:

    - `ToolContext.init(stamping:op:sessionID:mailbox:sink:completionToken:isCancelled:)` takes `op: String? = nil`. The stamp rule is now `tool.name` into `tool`, and the declared op into `op` — falling back to that same name. An EMPTY declared string reads as absent rather than tripping the explicit initializer's `!op.isEmpty` precondition, which mirrors the empty-`name`-falls-back-to-type-name rule already sitting one line above it.
    - `DetachingTool` and `ContextBindingTool` each hold a `private let op: String?`, take it on `init` with a `nil` default, and hand it to the context they bind.
    - Both `wrapping` overloads take `op: String? = nil`; the `inheriting` one forwards it to the mailbox-taking one.
    - `ToolDetachment.sessionMounted(...)` is unchanged and takes the default, so Router's own session mount behaves exactly as before.

    Access levels: `ToolContext.mailbox`, `SessionMailbox.ParkResult` and `SessionMailbox.park(...)` are each still internal — checked after the edit, not assumed.

    ### The plane, written down

    `ToolContext.init(stamping:op:...)` now carries a `### The plane the declared pair appears on` section: the pair reaches `ParkedRun.op` and `ToolInvocationRecord.op`, and it does NOT reach the event journal of an enclosing snippet, because `post(_:)` re-stamps every forwarded event with its own run's identity. The two `wrapping` overloads' `- op:` bullets point at it rather than repeating it.

    ### A trap the plane test walked into, worth knowing

    The plane test needs a sink that forwards an inner run's events through the enclosing `ToolContext.post(_:)`. Written the obvious way, its record half read:

    ```swift
    await upstream.post(invocation: record)
    ```

    where `upstream` is a recording ACTOR that conforms to `OperationEventSink`. That line silently calls `OperationEventSink`'s own no-op DEFAULT rather than the actor's method, so every record vanished — 0 recorded, no diagnostic, no warning. Dispatch through the `any OperationEventSink` existential picks the witness correctly, which is why the other tests of the suite read their records back and only the forwarding one broke.

    Measured three ways before the cause was believed: through the engine (0 records), through a hand-built existential (0), and by calling the actor directly in the test body (0). The fixture now exposes a second, distinctly named `append(invocation:)` for a forwarding sink to call, and the doc comment on it states the trap so the next author does not spend the same half hour. A production sink that forwards records to another concrete sink would hit exactly this — worth remembering if one is ever written.

    ### Coverage beyond the card's four tests

    The card names `DetachingTool.call` AND `ContextBindingTool.call` as the two decorators that pass the op through, and its test list covers only the parking route. A fifth test mounts a non-String-output tool, so the binding-only decorator's own path is measured: the declared op reaches that tool's ambient posts and both of its invocation records, and nothing parks. Without it that half of the seam would ship unmeasured.

    ### Doc links repaired

    Adding a parameter renames a symbol, so eight `` ``…`` `` references to the three old selectors were stale. All eight updated, across `ToolContext.swift`, `DetachingTool.swift`, `RoutedLLM.swift`, `ToolOutputCapping.swift`, `DetachingToolTests.swift` and `ScriptedMarkerTools.swift`. A grep for the old spellings now finds nothing.
  timestamp: 2026-08-25T02:04:03.379970+00:00
- actor: claude-code
  id: 01m0vaj9m4q7ew505gwc8035hn
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Hosting/ToolContext.swift, Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Tests/FoundationModelsRouterTests/RegisteredJournalOpTests.swift (new, 5 tests), Tests/FoundationModelsRouterTests/DetachingToolTests.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift. `swift test`: 1046 tests in 101 suites passed, plus 83 in 10 suites — 0 failures, 0 new warnings, the 2 known issues pre-existing in RealModelHarnessTests and BoundedWaitTests, neither touched.
    - next: ready for `/review`
  timestamp: 2026-08-25T02:04:10.244193+00:00
- actor: claude-code
  id: 01m0vb7bypqqqsj7abyaxq4jg5
  text: |
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted, 14 attempted, 0 failed; 7 files reviewed, 2 excluded by .reviewignore (.kanban/)
    - next: task moved to done
  timestamp: 2026-08-25T02:15:40.758628+00:00
- actor: claude-code
  id: 01m0vb7sgtvs9ns9drfgjx3ec1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files, 5 new tests in RegisteredJournalOpTests.swift
    - test: green — swift test, 1129 passed (1046 + 83), 0 failed, 0 skipped
    - commit: 6756975
    - review: clean — zero new findings, 14 validator/file pairs, task moved to done
  timestamp: 2026-08-25T02:15:54.650801+00:00
position_column: done
position_ordinal: fff280
title: Let a registration site give a tool its journal op
---
## What

`ToolContext.init(stamping:)` makes one string and puts it in both `tool` and
`op`:

```swift
let stamp = tool.name.isEmpty ? String(describing: type(of: tool)) : tool.name
self.init(..., tool: stamp, op: stamp, ...)
```

It is the only initializer the two decorators call — `DetachingTool.call` and
`ContextBindingTool.call` — and no `wrapping` overload and no decorator
initializer takes an `op`. Thus each mounted tool reports an `op` that equals its
`tool`, and a caller outside this module cannot make the two differ.

`eventplan.md` of FoundationModelsMultitool states the journal `op` of a
capability verb is the pair `"verb noun"` — `"execute shell"` for
`tools.shell.execute`. A verb cannot supply that string: it does not know its own
noun, because `register(noun:tool:)` at the registration site holds it. So the
registration site must be able to give the op, and today no public route carries
it.

**Measured, and not reasoned.** The explicit initializer
`ToolContext.init(sessionID:mailbox:sink:tool:op:...)` IS public, and Router uses
it to bind `tool: "session"` with `op: "respond"`. A package outside this module
cannot use it, because it needs the session mailbox. A probe in
FoundationModelsMultitool that reads `context.mailbox` does not compile:

```
error: 'mailbox' is inaccessible due to 'internal' protection level
```

The probe was deleted after the measurement.

### Do NOT publish the mailbox

`SessionMailbox.swift:44-46` records the decision that the run-plane machinery
stays internal, and `ToolContext.mailbox` is internal for the same reason. That
decision stands. This card does not ask to reverse it.

### The seam

Carry an optional op from the registration site to the stamp:

- `ToolContext.init(stamping:)` takes an optional op. When it is absent the
  behaviour does not change: one string fills both fields, exactly as now.
- The two decorators pass it through — `DetachingTool.call` and
  `ContextBindingTool.call`.
- Both `ToolDetachment.wrapping(...)` overloads accept it, because that is the
  public entry point a registration site reaches.

A tool that declares nothing keeps its behaviour with no edit.

### Name the plane the string appears on

The card that found this also found a fact worth settling here. An inner
`tools.*` call inside a `runCode` snippet reaches the session outbox re-stamped
with the OUTER run's op, because `ToolContext.post(_:)` re-stamps each event it
forwards. Thus a verb op of `"execute shell"` surfaces on the run plane
(`ParkedRun.op`) and on `ToolInvocationRecord`, and NOT in the event journal of
the enclosing snippet.

State which plane the pair must appear on, and write the answer into the doc
comment. A test that asserts the wrong plane is worse than no test.

## Acceptance Criteria

- [x] A registration site outside the FoundationModelsRouter module gives a tool
      an op that differs from its `tool` name.
- [x] That op reaches `ParkedRun.op` and `ToolInvocationRecord`.
- [x] `ToolContext.mailbox`, `SessionMailbox.park` and `ParkResult` each stay
      internal. The access level of none of them changes.
- [x] A tool that supplies no op keeps its behaviour with no edit: one string
      fills both `tool` and `op`.
- [x] The doc comment states which plane carries the pair, and why the event
      journal of an enclosing snippet does not.

## Tests

- [x] A test mounts a tool with an op that differs from its name and asserts
      `ParkedRun.op` carries the given op.
- [x] A test asserts `ToolInvocationRecord` carries it.
- [x] A test asserts a tool that supplies no op still reports `op == tool`, thus
      the behaviour that exists does not change.
- [x] A test asserts an inner call inside a snippet behaves the way the doc
      comment states, thus the plane question is pinned and not left to a reader.
- [x] `swift test` passes with no new failure and no new warning.

## Who waits for this

FoundationModelsMultitool `^fs7ywtg` — "Derive the \"verb noun\" journal op at
registration" — is STUCK on this card. Its `tools.shell.execute` verb reports
`"execute"` where `eventplan.md` states `"execute shell"`.

This is the second card this seam question raised. The first, `^7mxhb39`, gave a
tool a way to declare its `RunKind` and its canceler. Both come from the same
root: a registration site outside this module cannot tell the engine anything
about the run it is about to make.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #eventplan #phase-2
---
comments:
- actor: claude-code
  id: 01m2g4z4d34d1rawykccnny02g
  text: |-
    Research is complete. Discoveries:

    - `RunToCompletionRunner.call` and `ContextBindingTool.bind` are the only two sites that make a settled `Result` a throw again. `BackgroundToolRunner.call` does not throw.
    - `ContextBindingTool` returns the generic `Output`. A failure has no value of type `Output`, so the decorator cannot return failure text with its current output type. The plan: the decorator returns a new wrapper type (the tool output, or the failure text). The wrapper conforms to `PromptRepresentable`. It conforms to `ConvertibleToGeneratedContent` only when `Output` conforms, so a `@Generable` output keeps its `.structure` transcript segment (RestoreFidelityTests use `StructuredMarkerTool` for this).
    - `ToolCallSpan.withSpan` records a thrown error on the span (`recordError` and `setStatus(.error)`). When the failure becomes a return value, `withSpan` no longer sees it. To keep observability the same (ToolTracingTests expects `span.errors.count == 1`), the decorators must record the error on the span before they return the text.
    - These tests expect the old throw and must change to the new contract: RunToCompletionRunnerTests (timeout and fixture error cases), ToolInvocationLivenessTests (ContextBindingTool close record on throw), ToolTracingTests (failed call), SurfaceParityTests ("a call that throws" row, which documents the old abort), AutoCompactionTests (FailingTool). Others are found by the test run.
    - `ScriptedSessionFixture` drives a real `LanguageModelSession` over a scripted model. It gives an end-to-end check of the three conditions of the card.
  timestamp: 2026-09-14T14:26:04.323837+00:00
- actor: claude-code
  id: 01m2g5phre1yy98a0b02yf2qwn
  text: |-
    BLOCKER: the change the card names conflicts with documented contracts of the mount decorators. A person must decide where the fix goes.

    What the card orders: at `RunToCompletionRunner.call` and at `ContextBindingTool.bind`, return the failure text and throw only for a cancellation.

    Why this is a conflict: the same two decorators serve TWO kinds of caller, and not only Apple's `LanguageModelSession`.
    1. The model-facing mount (`ToolMounting.makeSessionMounted`). The card is correct for this caller.
    2. Programmatic callers that call a mounted tool and depend on the throw:
       - `ToolContext.mount(_:op:as:)` (public API). Its documented return type is `any Tool<T.Arguments, T.Output>`. A `ContextBindingTool` that returns failure text cannot keep `Output`, so `mounted as? any Tool<T.Arguments, T.Output>` fails and `mount` silently returns the UNMOUNTED tool.
       - `Session/DiscoveryPriming.swift` calls the mounted tool (`textTool.call(arguments:)`) and turns a throw into a priming-failure event.
       - FoundationModelsMultitool `RunBinding.invoke` calls `context.mount(tool).call(...)`. Its doc says "Throws: whatever the wrapped tool throws, unchanged; or `ToolMountError.timedOut`". With the change, a JS snippet gets the error text as a normal return value.

    Evidence. Command: `swift test` (after the change, with every test updated for the new contract). Result: `Test run with 1288 tests in 139 suites failed ... with 21 issues`. The failures that show the conflict:
    - ToolContextMountTests.swift:111 `Expectation failed: mounted is ContextBindingTool<MountArguments, NonStringToolOutput>` (the silent unmount), and ToolContextMountTests.swift:147-156 (events lost, because the tool is not bound).
    - LostRunErrorTests.swift:76 "a run-to-completion call whose body throws a LostRunError throws it on to the caller": `an error was expected but none was thrown and "TransportDropped()" was returned`.
    - NestedGenerationReentryTests.swift:521 (2 tests): the re-entry refusal no longer reaches the caller as an error.
    - DiscoveryPrimingTests.swift:423-430, 642-648, 668-674 (3 tests): a failing discovery call no longer produces the failure event.

    What passes with the change: the new ToolCallFailureTurnTests (one failed call and three good calls: the three complete; the model reads the failure and calls again; a cancellation still stops the turn), ContextBindingToolFailureTests, RunToCompletionRunnerTests, ToolTracingTests, SurfaceParityTests.

    The question for a person: where does the "failure becomes a tool result" rule go?
    - Option A: only at the model-facing boundary. For example, a new outermost decorator that `ToolMounting.makeSessionMounted` applies (next to `TokenCappingTool`), or a flag that only the session mount sets. `ToolContext.mount`, DiscoveryPriming and Multitool keep the throw. This moves the fix off the two lines the card names.
    - Option B: keep the card's lines, and change the contracts of `ToolContext.mount`, DiscoveryPriming, LostRunError propagation, nested re-entry refusal and Multitool `RunBinding.invoke`. That is a much larger change than the card describes, and it crosses into FoundationModelsMultitool.

    State of the working tree (not committed): production files `Hosting/ToolCallFailure.swift` (new), `Hosting/RunToCompletionRunner.swift`, `Hosting/ContextBindingTool.swift` (new `ToolCallResult<Output>`), `Tracing/ToolCallSpan.swift` (`record(error:on:)`). Tests: new `ToolCallFailureTurnTests.swift`, `ContextBindingToolFailureTests.swift`; new fixtures `CancellingMarkerTool`, `ThrowingNonStringMarkerTool`, `FailingToolRow` in `Helpers/ScriptedMarkerTools.swift`; `wrappedOutput` helper in `Helpers/MountTestHelpers.swift`; updated RunToCompletionRunnerTests, ToolTracingTests, SurfaceParityTests, ToolInvocationLivenessTests, ToolMountingTests, RegisteredJournalOpTests, SessionOutboxToolWiringTests, SessionTreeRestorationToolWiringTests. The end-to-end tests stay valid for Option A, and most of the ContextBindingTool type work is only needed for Option B.

    Process note: one edit of RunToCompletionRunnerTests.swift was made with a python script instead of the file tool.
  timestamp: 2026-09-14T14:38:51.662996+00:00
- actor: claude-code
  id: 01m2g5pn3hzpj4f3jgbx212199
  text: |-
    ### implement — stuck
    - evidence: `swift test` → 1288 tests, 21 issues. ToolContextMountTests.swift:111 (ToolContext.mount silently unmounts a non-String tool, because ContextBindingTool can no longer keep `Output`), LostRunErrorTests.swift:76, NestedGenerationReentryTests.swift:521 (x2), DiscoveryPrimingTests.swift:423/642/668. These callers depend on the throw that the card removes.
    - next: a person picks Option A (apply the rule only at the model-facing session mount) or Option B (change the throw contracts of ToolContext.mount, DiscoveryPriming, LostRunError, re-entry refusal and Multitool RunBinding.invoke). See the BLOCKER comment.
  timestamp: 2026-09-14T14:38:55.089365+00:00
- actor: claude-code
  id: 01m2g5qsvs2brc50q3d6qay9ne
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — the fix at RunToCompletionRunner.swift:77 and ContextBindingTool.swift:83 breaks callers that depend on the throw
    - test: not run — swift test in the implement step gave 1288 tests, 21 issues (ToolContextMountTests.swift:111, LostRunErrorTests.swift:76, NestedGenerationReentryTests.swift:521 x2, DiscoveryPrimingTests.swift:423/642/668)
    - commit: not run — the working tree is not committed
    - review: not run
    - next: a person must select Option A (convert the failure only in ToolMounting.makeSessionMounted) or Option B (change the throw contracts of all callers)
  timestamp: 2026-09-14T14:39:32.729022+00:00
- actor: claude-code
  id: 01m2g68ph4mqy3518j18jqph28
  text: |-
    ### decision — Option A
    - source: the user sent the question to the FoundationModelsACPAgent session. That session selected Option A, and it did a check of the call paths.
    - evidence: the four surface tools (searchTools, runCode, wait, skills) all go through ToolMounting.makeSessionMounted (RoutedLLM.swift:246) to LanguageModelSession. Resume, model switch and fork use the same wiring again (SessionTreeRestoration.swift:359, ConfigOptions.swift:230-235, RoutedSessionActorForking.swift:151). MCP is not a surface tool. It is available only as tools.<verb> in a runCode snippet.
    - card correction: ContextBindingTool.swift:83 is a doc comment. The call is at :69. The card is not correct when it says that the fix must be at those two lines.
    - work: in makeSessionMounted, change a failure (not a CancellationError) into a tool result. Put back the throw in RunToCompletionRunner and ContextBindingTool, so ToolContext.mount, DiscoveryPriming, LostRunError, the re-entry refusal and Multitool RunBinding.invoke continue to throw.
    - note: the peer saw a possible cast failure at ToolContext.swift:464 for a tool whose output is not a String. It read the uncommitted ContextBindingTool with the ToolCallResult<Output> type. When the throw is put back, examine this again. If the failure is still there, make a new card for it.
  timestamp: 2026-09-14T14:48:46.372464+00:00
- actor: claude-code
  id: 01m2g7p3vehx0wd488fhww8ytv
  text: |-
    Option A is implemented. What changed:

    - New `Hosting/ToolFailureDelivery.swift`. `ToolFailureDelivery.makeWrapped(tool:)` puts an outermost decorator on a tool: `FailureDeliveringTextTool` for a String-output tool (the output stays String), `FailureDeliveringResultTool` for any other tool (the output is `ToolCallResult<Output>`, which conforms to `ConvertibleToGeneratedContent` only when `Output` conforms, so a @Generable output keeps its structure segment). `ToolCallResult.init(catching:)` holds the one rule: a CancellationError is thrown again, every other error becomes the text `String(describing: error)`. Both decorators conform to `TurnBoundaryTool` and `ToolDecorator`, so the turn boundary still walks the chain.
    - `ToolMounting.makeSessionMounted` applies it outermost, over the capping layer. It is the only site.
    - `DiscoveryPrimer.seededEntries` calls `ToolFailureDelivery.throwingTool(of:)`, so a failed discovery call still throws `callFailed`. Proof: with that call removed, DiscoveryPrimingTests.swift:423/642/668 fail; with it, they pass.
    - The earlier Option B changes are gone: `RunToCompletionRunner.swift`, `ContextBindingTool.swift` (Output type restored), `Tracing/ToolCallSpan.swift` are back to HEAD, and `Hosting/ToolCallFailure.swift` is deleted. RunToCompletionRunnerTests, ToolInvocationLivenessTests, RegisteredJournalOpTests and the call assertions in ToolMountingTests, SessionOutboxToolWiringTests, SessionTreeRestorationToolWiringTests are restored to their HEAD contracts. `ToolContext.mount`, LostRunError, the re-entry refusal and Multitool `RunBinding.invoke` (through `ToolContext.mount`) keep their throw, because they do not use the session mount.
    - Observability: the runners beneath still record the terminal `.failed` event and the span error before the error reaches the decorator. ToolTracingTests "a tool call that throws keeps its span, with the error recorded" passes for both routes.
    - Kept from the earlier step: ToolCallFailureTurnTests (one failed call and three good calls complete; the model reads the failure and calls again; a cancellation still stops the turn; both a String and a non-String tool), the SurfaceParityTests "a call that throws" row, the parametrized ToolTracingTests case, and the fixtures `CancellingMarkerTool`, `ThrowingNonStringMarkerTool`, `FailingToolRow`.
    - New unit suite ToolFailureDeliveryTests (the rule, both decorators, non-String and structured output, `throwingTool(of:)`, the session mount order).
    - Structural tests that read the first tool of a session list now peel the decorator with the test helper `failureDeliveryPeeled(_:)` (MountTestHelpers). `mountWrapped(_:)` peels it first. The fake backends in BackgroundingBackendFixtures and NestedGenerationReentryTests and the AutoCompactionTests peel it too.

    ToolContext.swift:464 check (peer note): not a defect. With the Output type of ContextBindingTool restored, the cast `mounted as? any Tool<T.Arguments, T.Output>` succeeds. ToolContextMountTests.swift:111 (`mounted is ContextBindingTool<MountArguments, NonStringToolOutput>`) passes. The failure the peer saw came only from the Option B `ToolCallResult` output type. No new card.

    Tooling note: the `replace_all` flag of the sah files edit tool replaced only the first match (checked on a scratch file), so each test site was edited one at a time.

    Architecture note: the decorator chain now has one more layer on the model-facing list. No ARCHITECTURE.md exists.
  timestamp: 2026-09-14T15:13:34.574988+00:00
- actor: claude-code
  id: 01m2g7p8q22x4kdrvbkfj00gpx
  text: |-
    ### implement — changed
    - evidence: `swift test` → 1296 tests in 139 suites passed, 0 failures, 2 known issues (the existing withKnownIssue tests in BoundedWaitTests and RealModelHarnessTests), no compiler warnings. Files: new Sources/FoundationModelsRouter/Hosting/ToolFailureDelivery.swift; Sources/.../Session/ToolOutputCapping.swift, Session/DiscoveryPriming.swift, Hosting/ToolDecorator.swift; new Tests/.../ToolFailureDeliveryTests.swift, ToolCallFailureTurnTests.swift; Tests/.../Helpers/MountTestHelpers.swift, Helpers/ScriptedMarkerTools.swift, Helpers/BackgroundingBackendFixtures.swift, AutoCompactionTests.swift, NestedGenerationReentryTests.swift, SessionOutboxToolWiringTests.swift, SessionTreeRestorationToolWiringTests.swift, SurfaceParityTests.swift, ToolMountingTests.swift, ToolOutputCappingTests.swift, ToolTracingTests.swift. Reverted to HEAD: RunToCompletionRunner.swift, ContextBindingTool.swift, ToolCallSpan.swift and the tests that changed only for Option B.
    - next: /review
  timestamp: 2026-09-14T15:13:39.554919+00:00
- actor: claude-code
  id: 01m2g8gh0gbrfcvw3f73tcpc5w
  text: |-
    ### test — green
    - evidence: command `swift package clean` then `swift test`. Result: 1380 tests ran. 0 tests failed. 0 tests did not run. 2 tests check that an issue gets recorded; this is by design, not a skip. The build gave 0 warnings in the project's own code (Sources and Tests). Warning text did show up in the vendored mlx-swift dependency code under `.build/checkouts`. That code is not part of this project, so it is out of scope for this step.
    - next: send the task to the review step.
  timestamp: 2026-09-14T15:28:00.016819+00:00
- actor: claude-code
  id: 01m2g92x0d5ec4yffh5fjg5ja6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b7323a6). 0 findings, 0 confirmed, 0 refuted. 21 runs attempted, 0 failed, 0 skipped. 17 files reviewed. 2 .kanban files not reviewed (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-09-14T15:38:02.125486+00:00
- actor: claude-code
  id: 01m2g93fq17gqqqhm8238sm67k
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — Option A: new ToolFailureDelivery decorator in ToolMounting.makeSessionMounted; RunToCompletionRunner, ContextBindingTool and ToolCallSpan are back to HEAD
    - test: green — swift package clean && swift test, 1380 passed, 0 failed, 0 warnings in the package
    - commit: b7323a6
    - review: clean — review sha HEAD~1..HEAD, 0 findings
  timestamp: 2026-09-14T15:38:21.281544+00:00
position_column: done
position_ordinal: ffffd380
title: One failed tool call cancels the other calls of the turn, and ends the turn
---
## The problem

One tool call that fails kills the other tool calls of the same turn, and it
ends the turn. The model gets no chance to read the failure and go on.

From a SWE-bench run of `FoundationModelsACPAgent` on 2026-09-13. The model
made four tool calls in one turn. One of them failed:

```
skills        failed     "This operation failed while executing."
searchTools   cancelled  "CancellationError()"
searchTools   cancelled  "CancellationError()"
searchTools   cancelled  "CancellationError()"
```

The three `searchTools` calls were correct. They died because a sibling threw.
The turn then ended with the `_error` stop reason of the host, and the agent
did no work at all. This happened on 3 of 16 instances, and each one lost its
whole turn in 20 to 141 seconds.

## Where the throw comes from

The fan-out is NOT in this package. Apple's `LanguageModelSession` runs the
calls of a turn, and it cancels the children that are pending when one child
throws. This package cannot change that.

What this package DOES own is the line that lets the throw reach Apple's task
group:

```swift
// Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:77
return try settlement.result.get()
```

`settle(...)` has already reduced the call to a `Result`, and it has already
recorded the terminal `.failed` event. Line 77 then makes that `Result` a
throw again, and the throw crosses the `Tool.call` boundary.

Each cancelled sibling then resolves at `Hosting/ToolRun.swift:212`, which
answers `.cancelled` for a `CancellationError`. That is what the transcript
shows.

The turn ends from the same throw. There is no second decision. It goes
`RunToCompletionRunner:77` to Apple's session to `backend.respond` to
`Session/RoutedSessionActorTurnExecution.swift:17` and out to the host.

## The work

Give the failure to the model as a tool result. Throw for a cancellation
only.

```swift
switch settlement.result {
case .success(let output):
    return output
case .failure(let error):
    if error is CancellationError { throw error }
    return "<the text of the failure>"
}
```

A true cancellation must stay a throw. If it does not, cancellation stops
working.

Apply the same shape at `Hosting/ContextBindingTool.swift:83`
(`return try settlement.outcome.get()`), or a tool whose output is not a
`String` keeps the old behaviour.

This package is the correct owner. It holds the mount boundary, it is the one
layer that sees the `Result` before the throw crosses into Apple's runtime,
and a fix here covers every tool at one time: Skills, Multitool and MCP.

Observability does not change. `ToolRun.execute` and `settle` record the
terminal `.failed` event and the tracing outcome before this line.

## When it is complete

- A turn with one failed tool call and three good ones completes the three.
- The model reads the failure as a tool result, and it can make another call.
- A true cancellation still stops the turn.
- A test proves each of the three conditions above.

## A related card, and it is not this one

`FoundationModelsExtras` throws the cause away at
`Sources/Operations/AnyOperation.swift:81`, so the text this change gives the
model will say only "This operation failed while executing." That is a card of
its own, and it is filed. This card is the cancellation.
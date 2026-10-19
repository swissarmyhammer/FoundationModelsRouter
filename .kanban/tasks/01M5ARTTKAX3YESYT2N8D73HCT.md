---
comments:
- actor: claude-code
  id: 01m5b142k4v56fr508tdpeb0rt
  text: |-
    Research done. Discoveries:
    - The SDK tool list is `SessionCheckedTool(wrapped: ToolFailureDelivery decorator(capping(mount(tool))))`. The failure-delivery decorator of Extras is the outermost mount layer. It changes each throw (except a cancel of the task of the call) into failure text. Thus `SessionCheckedTool` never sees a throw of the tool body. To send `PostToolUse(succeeded: false)`, the hook layer must sit beneath the failure delivery. Plan: `Tool.sessionChecked` takes the throwing tool (`ToolFailureDelivery.throwingTool(of:)`), puts a hook layer on it, and puts a new failure-delivery decorator on the hook layer. The checks stay outermost, so PreToolUse still comes after the no-op check and the repetition check.
    - The SDK records a `String` output as a text segment, and each other output as a structure. Thus a `String` tool keeps `String` as its output (a replaced output is text). A tool with another output gets a wrapper output (`.original` or `.replaced(text)`) that gives the same prompt and the same generated content as the original, so the transcript does not change when no visitor replaces the output.
    - The tool call ID: `ToolCallRunJoin` already reads the live transcript inside the tool call (safe inside a tool body, see the memory note on transcript reads). The hook layer gets the `Transcript.ToolCall` (id and argumentsJSON) of the call the same way, with a claim set of its own. The id is the id of the `toolCall` session event. Note: the card says the id is also the `correlationID` of `toolCallReport`, but `SessionEvent.toolCallReport` documents that its correlationID is the run completion token, never a `Transcript.ToolCall.id`. The acceptance criterion names only the `toolCall` session event, so the test checks that id.
  timestamp: 2026-10-19T21:29:45.316646+00:00
- actor: claude-code
  id: 01m5b1wtq2axj5fhnwnsapddec
  text: |-
    Implementation landed (TDD: 14 new tests, 11 failed RED for the expected reasons, all 14 pass GREEN).

    Design as built:
    - `Session/ToolCallHooks.swift` (new): `ToolCallHooks` (task-local `current`, the `SessionHooks` of the session, and a claim closure for the SDK tool call), the hook flow (`PreToolUse` -> body -> `PreToolResult` -> `PostToolUse`), `HookedOutputForm`, `HookedToolOutput` (`.original` / `.replaced(text)`, same prompt and generated content as the original), the hook layers `HookedTextTool` (String output stays String) and `HookedResultTool`, and `ToolCallHooking.hooked(_:)`.
    - `ToolCallHooking.hooked(_:)` takes the throwing tool beneath the Extras failure delivery (`ToolFailureDelivery.throwingTool(of:)`), puts the hook layer on it, and puts a new failure delivery over it. Reason: the failure delivery changes each throw into failure text, so a hook layer over it cannot see a throw. The checks of `SessionCheckedTool` stay outermost, so PreToolUse comes after the no-op and repetition checks. The new failure delivery gives the final (replaced) text to the tool-result append boundary.
    - `ModelCallToolChecks` has a new `hooks: ToolCallHooks?`. `bound(_:)` also binds `ToolCallHooks.$current` and `HookSession.$current` (both nil for a router with no dispatcher). `RoutedSessionActorAnswerExecution` passes `makeToolCallHooks()`.
    - Tool call ID: `RoutedSessionActor.claimHookedToolCall(named:)` (new file `RoutedSessionActorToolHooks.swift`) claims the first open call of the live transcript with the tool name, with its own claim set `toolHookClaims`. The claim logic moved out of `ToolCallRunJoin` into `OpenToolCallClaims`, which both use. PreToolUse/PreToolResult/PostToolUse carry the id and `arguments.jsonString` of that `Transcript.ToolCall`, so they equal the `toolCall` session event.

    Decisions not on the card: a block on `PreToolResult` gives the model the reason, and `PostToolUse` then has `succeeded: false`. A block or a decode failure on `PreToolUse` gives `PostToolUse(output: reason or decode error, succeeded: false)`. A replaced output is not capped by `ToolOutputCapping` (the capping layer is beneath the hook layer, so `PreToolResult` sees the capped output).

    Discoveries: the SDK records a replaced output of a structured tool (`HookedToolOutput.replaced`, generated content of kind string) as a text segment, not a structure. The card asks the id to equal the `correlationID` of `toolCallReport`, but that correlationID is the run completion token by contract (`SessionEvent.toolCallReport` docs), so the test checks the `toolCall` event id only. The shared helper `ToolContext.startAgentCall(of:)` (`Tests/.../Helpers/SubagentParentCall.swift`) replaces the private copy in `HookLineageTests`; `CatalogNoticeDeliveryTests` and `SessionWorkRegistryTests` still hold their own copies (not touched). `ScriptedSessionFixture.make` got a `hooks:` parameter.
  timestamp: 2026-10-19T21:43:16.450503+00:00
- actor: claude-code
  id: 01m5b1x0r156nhx24pfnxpnr7h
  text: |-
    ### implement — changed
    - evidence: `swift test --filter FoundationModelsRouterTests.ToolHookTests` 14 tests passed (RED run before: 11 of 14 failed); full `swift test`: 1895 tests in 235 suites passed (9 known issues are the existing withKnownIssue tests), 0 warnings. Files: Sources/FoundationModelsRouter/Session/{ToolCallHooks.swift (new), RoutedSessionActorToolHooks.swift (new), SessionCheckedTool.swift, ToolCallRunJoin.swift, RoutedSessionActor.swift, RoutedSessionActorAnswerExecution.swift}; Tests/FoundationModelsRouterTests/{ToolHookTests.swift (new), Helpers/SubagentParentCall.swift (new), Helpers/ScriptedSessionFixture.swift, Helpers/ScriptedToolCallingModel.swift, HookLineageTests.swift}
    - next: /review
  timestamp: 2026-10-19T21:43:22.625807+00:00
- actor: claude-code
  id: 01m5b20630cfbhg4xwgjvvt7jw
  text: |-
    ### test — green
    - evidence: touched changed Swift files, then ran `swift test` one time in the root package. Result: 1895 tests in 235 suites passed, 0 failed, 0 skipped. The run has 9 known issues. They come from existing tests of wait helpers and the RealModelHarness embedding slot, which use withKnownIssue on purpose. Two more targets passed: 26 tests and 19 tests.
    - evidence: `cd IntegrationTests && swift build --build-tests` finished with Build complete, 0 errors.
    - warnings: the only warning in both builds is the known mlx "missing creator for mutated node" line. The change added no new warning.
    - next: review.
  timestamp: 2026-10-19T21:45:06.400400+00:00
- actor: claude-code
  id: 01m5b29ze61bnbktwz1b8t6w4s
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (2bd35d78): 3 findings (3 confirmed, 7 refuted) — Sources/FoundationModelsRouter/Session/ToolCallHooks.swift:72, Tests/FoundationModelsRouterTests/ToolHookTests.swift:46, Tests/FoundationModelsRouterTests/ToolHookTests.swift:570
    - next: implement the 3 open items in "Review Findings (2026-10-19 16:45)", then review again.
  timestamp: 2026-10-19T21:50:27.270798+00:00
- actor: claude-code
  id: 01m5b2ak6x67e4am9ytbnfp4v1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files
    - test: green — swift test, 1895 passed, 0 failed; IntegrationTests build complete
    - commit: 2bd35d78
    - review: findings — Sources/FoundationModelsRouter/Session/ToolCallHooks.swift:72, Tests/FoundationModelsRouterTests/ToolHookTests.swift:46, Tests/FoundationModelsRouterTests/ToolHookTests.swift:570
  timestamp: 2026-10-19T21:50:47.517689+00:00
- actor: claude-code
  id: 01m5b2mhxrw4b9pbx5yy7605d7
  text: |-
    Review findings (2026-10-19 16:45) fixed:
    1. Reuse: new `ToolArgumentsContent.of(_:)` (`Sources/FoundationModelsRouter/Session/ToolArgumentsContent.swift`) holds the one conversion of tool arguments to `GeneratedContent`. `SessionCheckedTool.call`, `ToolCallHooks.identify` and `ToolCallIdentity.init?(toolName:arguments:)` (a third copy in `IdenticalToolCallRun.swift`) call it.
    2. Duplication: new `HookEventRecorder<Event>` (`Tests/FoundationModelsRouterTests/Helpers/HookEventRecorder.swift`) holds the locked event list, the hook session of each event, a `ChangeSignal`, and `record(_:of:)`. `PromptRecordingVisitor` and `ToolRecordingVisitor` hold one `recorder` and keep their decision closures. Call sites read `visitor.recorder.events` / `.sessions` / `.changes`. `HookLineageTests.RecordingHookVisitor` and `CompactionHookTests.CompactionRecordingVisitor` have the same shape; they are existing tests outside the finding and were not changed.
    3. Duplication: `checkReplacedOutput(of:)` holds the shared body of the two replaced-output tests. The same cause (withHookedSession + collectEvents prefix) was in 8 tests of `ToolHookTests`; a new `withAnswer(calling:visitor:_:)` helper holds it, and `ToolRecordingVisitor.posts` replaces an inline post filter.
    Note: a single-expression check closure with `#expect(... try ...)` did not compile ("errors thrown from here are not handled"); the `try` moved to a `let` before the `#expect`.
  timestamp: 2026-10-19T21:56:13.880816+00:00
- actor: claude-code
  id: 01m5b2mr8xpwz6bme4ecp2khp2
  text: |-
    ### implement — changed
    - evidence: `swift test --filter 'FoundationModelsRouterTests.(ToolHookTests|PromptHookTests|ToolCallRepetitionStopTests|NoOpToolCall|IdenticalToolCall)'` 51 tests in 7 suites passed (Tool hooks and Prompt hooks suites included), 0 failed. The build compiled the changed source and test files fresh; the only warning is the known mlx "missing creator for mutated node" line. Files: Sources/FoundationModelsRouter/Session/{ToolArgumentsContent.swift (new), ToolCallHooks.swift, SessionCheckedTool.swift, IdenticalToolCallRun.swift}; Tests/FoundationModelsRouterTests/{Helpers/HookEventRecorder.swift (new), ToolHookTests.swift, PromptHookTests.swift}. All 3 findings flipped to [x].
    - next: /review
  timestamp: 2026-10-19T21:56:20.381230+00:00
- actor: claude-code
  id: 01m5b2qxhv0aak60rk9p22h8wn
  text: |-
    ### test — green
    - evidence: Changed files touched. Root `swift test` ran one time: 1895 tests in 235 suites passed, 0 failed, 0 skipped. Two more small runs passed (26 tests in 14 suites, 19 tests in 3 suites). 9 known issues come from `withKnownIssue` in unchanged files (PromptWaitTests, TaskEndEventWaitTests, ManualRunClockWaitTests, RealModelHarnessTests). Each test there expects the issue, and each passed. `cd IntegrationTests && swift build --build-tests`: Build complete, 0 errors. Only warning in both builds: the known mlx "missing creator" line.
    - next: none. No code was changed by the test step. No commit was made. `swift format` was not run.
  timestamp: 2026-10-19T21:58:04.091428+00:00
depends_on:
- 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1
position_column: doing
position_ordinal: '80'
title: Router emits the tool events at SessionCheckedTool (PreToolUse, PreToolResult, PostToolUse)
---
## Context
This card is a Router change for the hook system that was designed in a FoundationModelsACPAgent session (2026-10-19). The user approved this change on 2026-10-19. It needs the Router card "Router holds a HookDispatcher, gives it to each session, and emits SessionStart and SessionEnd". Use symbol names, not line numbers.

## What
Emit the tool events at the tool boundary, `SessionCheckedTool.call(arguments:)` (`Session/SessionCheckedTool.swift`). `LiveModelLoader.checkedTools` wraps each tool of each session with it, on each slot. The sequence is:

```
pre PreToolUse → tool body → pre PreToolResult → output to the model → post PostToolUse
```

- **Binding.** `SessionCheckedTool` does not know its session, and the tools are wrapped at backend level. Bind the dispatcher (a Router task-local) and `HookSession.$current` (the public task-local of FoundationModelsHooks) for each model call, next to the no-op and repetition checks in `ModelCallToolChecks.bound(_:)` (built in `RoutedSessionActorAnswerExecution`). Tools read `HookSession.current` at call time; the Multitool `snapshots` capability uses it to find its session key. When nothing is bound (a call outside a model call), no hook runs.
- **pre** `PreToolUse` after the no-op check and the repetition check, before `wrapped.call`. `.blocked(reason)`: do not run the body; the model gets the reason as the tool output. `.proceed(e)` or `.approved(e)`: when `e.argumentsJSON` is different, decode it to `Wrapped.Arguments` and call the body with it. If the decode fails, do not run the body, and the model gets the decode error as the tool output. For now, approve has the same effect as proceed.
- **pre** `PreToolResult` after the body returns. A replaced `output` is what the model gets.
- **post** `PostToolUse` with the final output and `succeeded`. Also emit it when the body throws, with `succeeded: false`.

Implementation notes (implementation details; the implementer chooses, inside these constraints):
1. **Tool call ID.** `Tool.call(arguments:)` does not get the ID of the tool call. Get it at call time through the task-local binding of the model call, or by a match with the tool-call entry of the live transcript. The ID must be equal to the `id` of the `toolCall` session event and to the `correlationID` of `toolCallReport`, and the test checks this.
2. **Output type.** `SessionCheckedTool` returns `Wrapped.Output`. A replaced output is text, so the wrapper needs an output type that holds the original output or a string. Keep `ToolOutputCapping` and `ToolCallOutputPairing` correct for both, and do not change the output when no visitor replaces it.
3. **Verbs in `runCode`.** One `runCode` snippet is one tool call here. Hooks for one verb inside a snippet need a Multitool change (`MultiTool.performInvocation`) and are out of scope.

## Acceptance Criteria
- [x] With no dispatcher, the Router tests pass unchanged.
- [x] A tool call outside a model call (nothing bound) runs no hook.
- [x] Inside a tool body, `HookSession.current` is the `HookSession` of the session that made the call, also for a fork and a sub-agent.
- [x] A recording visitor gets `PreToolUse`, `PreToolResult` and `PostToolUse` in order for one tool call, with the same `toolCallID` as the `toolCall` session event.
- [x] A block on `PreToolUse` does not run the tool body, and the model gets the reason as the output.
- [x] A replaced `argumentsJSON` is what the tool body gets. A replacement that does not decode gives the decode error as the output.
- [x] A replaced `output` on `PreToolResult` is what the model gets, and what the transcript records.
- [x] A tool body that throws gives `PostToolUse` with `succeeded: false`.
- [x] A sub-agent session (`parentCall`) also emits the tool events.

## Tests
- [x] `Tests/FoundationModelsRouterTests/ToolHookTests.swift` (Swift Testing): each criterion above, with a scripted model that makes tool calls to a test tool.
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks

## Review Findings (2026-10-19 16:45)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsRouter/Session/ToolCallHooks.swift:72` `reuse/reuse` — The new identify function repeats the expression that turns tool arguments into GeneratedContent. The same expression already exists in SessionCheckedTool.call. Two copies of this conversion can drift apart, for example if one later handles a new argument type and the other does not. Move the conversion into one shared helper, for example a static function or an extension on the arguments type, and call it from both SessionCheckedTool.call and ToolCallHooks.identify.
- [x] `Tests/FoundationModelsRouterTests/ToolHookTests.swift:46` `duplication/duplication` — ToolRecordingVisitor copies the recording scaffolding of PromptRecordingVisitor: a Mutex-guarded event list, a private record function, and pre and post methods that append one event each. The copies must stay in step, and each one adds maintenance cost. Pull the locked event list and the record function into one shared recorder type with a generic event, and have both visitors use it. Keep the decision closures in each visitor. If that cannot be done in this change, extract the recorder into a new helper file in Tests/FoundationModelsRouterTests/Helpers and use it from ToolRecordingVisitor only.
- [x] `Tests/FoundationModelsRouterTests/ToolHookTests.swift:570` `duplication/duplication` — aReplacedStructuredOutputIsRecorded repeats the body of aReplacedOutputReachesTheModelAndTheTranscript (line 514). Both mount a tool, run the outputReplacingVisitor, and assert that deliveredToolOutputs and recordedToolOutputs equal [replacedOutput]. Only the tool differs (StructuredMarkerTool instead of MarkerEmittingTool). If the expectation changes, one copy can drift from the other. Extract one helper that takes the tool and the expected output, for example checkReplacedOutput(of tool: some Tool). Call it from both tests, and delete the second copy's body.

---
depends_on:
- 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1
position_column: todo
position_ordinal: '8180'
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
- [ ] With no dispatcher, the Router tests pass unchanged.
- [ ] A tool call outside a model call (nothing bound) runs no hook.
- [ ] Inside a tool body, `HookSession.current` is the `HookSession` of the session that made the call, also for a fork and a sub-agent.
- [ ] A recording visitor gets `PreToolUse`, `PreToolResult` and `PostToolUse` in order for one tool call, with the same `toolCallID` as the `toolCall` session event.
- [ ] A block on `PreToolUse` does not run the tool body, and the model gets the reason as the output.
- [ ] A replaced `argumentsJSON` is what the tool body gets. A replacement that does not decode gives the decode error as the output.
- [ ] A replaced `output` on `PreToolResult` is what the model gets, and what the transcript records.
- [ ] A tool body that throws gives `PostToolUse` with `succeeded: false`.
- [ ] A sub-agent session (`parentCall`) also emits the tool events.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ToolHookTests.swift` (Swift Testing): each criterion above, with a scripted model that makes tool calls to a test tool.
- [ ] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79qwbaerrkgycdka2dq737h
  text: 'Research: both identity paths (SessionCheckedTool -> IdenticalToolCallRun, and ToolResultAppend.arguments -> noteToolCallProgress) read `generatedContent.jsonString` of the tool''s Arguments value. Discoveries: (1) a @Generable Arguments type re-serializes in property declaration order, so the bug only shows for tools whose Arguments is GeneratedContent (dynamic-schema tools such as ACP `agents`); tests therefore use a new `CountingContentRunCodeTool` (GeneratedContent args, name `runCode`). (2) `GeneratedContent(json:).jsonString` does NOT reliably keep the model''s key order, nor reliably normalize it: `{"code","language"}` in either order printed the same, but nested `{"limit","follow"}` kept each input order. So a flat two-key pair is not a reliable RED; tests use a nested object. RED confirmed for all three new tests before the fix.'
  timestamp: 2026-11-13T06:00:24.142590+00:00
- actor: claude-code
  id: 01m79r1ax2mbeg62f7gvz0x845
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Session/IdenticalToolCallRun.swift (ToolCallIdentity.canonicalJSON via JSONSerialization .sortedKeys/.fragmentsAllowed, raw-text fallback), Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift and SessionCheckedTool.swift (docs), Tests/.../IdenticalToolCallLimitTests.swift (stop test + parametrized identity equal/unequal unit tests incl. nested, 1/true/"1", array order, unparseable), Tests/.../ConsecutiveRecoveryBudgetTests.swift (key-reordered repeat is no progress), Tests/.../Helpers/{IdenticalToolCallModel,RepeatingToolCallModel,RepeatingReasoningModel}.swift (raw-arguments scripts, CountingContentRunCodeTool with GeneratedContent args). RED observed for all three new behaviours, then GREEN. Full root `swift test`: 2652 + 41 + 19 tests passed, 0 failures (only the SwiftPM build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which predates this change). IntegrationTests not run (known unrelated ^5hjddsq).
    - next: /review
  timestamp: 2026-11-13T06:03:07.554765+00:00
- actor: claude-code
  id: 01m79r60anzge40wmsn9fq15xw
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (e47249a7) — 3 findings (3 confirmed, 2 refuted): Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:41, Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift:387, Tests/FoundationModelsRouterTests/IdenticalToolCallLimitTests.swift:38
    - next: implement the three reuse/reuse findings (share the reordered-key fixture between the two suites; reuse IdenticalToolCallScript.arguments(code:) in sendToolCall(running:)), then re-review
  timestamp: 2026-11-13T06:05:40.565591+00:00
- actor: claude-code
  id: 01m79r6d43r2qxxd8fcw96py3q
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test 2652+41+19
    - commit: e47249a7
    - review: findings — ConsecutiveRecoveryBudgetTests.swift:41, Helpers/RepeatingReasoningModel.swift:387, IdenticalToolCallLimitTests.swift:38
  timestamp: 2026-11-13T06:05:53.667603+00:00
- actor: claude-code
  id: 01m79rc6z3e6x6pm7t98gx9vzp
  text: |-
    Review findings fixed. New shared test helper `Tests/FoundationModelsRouterTests/Helpers/RunCodeArgumentsJSON.swift` (enum `RunCodeArgumentsJSON`) owns all three runCode argument shapes: `running(_:)` (`{"code": ...}`, moved from `IdenticalToolCallScript.arguments(code:)`, which is removed), `keysInOneOrder(running:)` and `keysInOtherOrder(running:)`. Both suites dropped their private fixture copies and call the shared builders; `RepeatingReasoningModel.sendToolCall(running:)` and `IdenticalToolCallModel` call `running(_:)`. Dead end: the first name, `RunCodeArguments`, collides with the existing @Generable `struct RunCodeArguments` in Helpers/RepeatingToolCallModel.swift (invalid redeclaration), so the enum is named `RunCodeArgumentsJSON`. Not touched: `NoOpToolCallModel.runCodeArguments(code:)` builds the same shape too, but that copy was there before this change.

    ### implement — changed
    - evidence: 6 files — Tests/FoundationModelsRouterTests/Helpers/RunCodeArgumentsJSON.swift (new), Helpers/IdenticalToolCallModel.swift, Helpers/RepeatingReasoningModel.swift, IdenticalToolCallLimitTests.swift, ConsecutiveRecoveryBudgetTests.swift, .kanban task (3 findings checked). Full root `swift test`: 2652 + 41 + 19 tests passed, 0 failures. The only warning is the SwiftPM build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which was there before this change.
    - next: /review
  timestamp: 2026-11-13T06:09:03.971661+00:00
position_column: doing
position_ordinal: '80'
title: Tool-call identity ignores the key order of the arguments
---
Reported by FoundationModelsACPAgent from hint24 django-13925 (root session 01M79M4CY92C4FVT7CW8YW5JT3).

The root session called `agents` check agent about 80 times. The stop "You called `agents` with the same arguments 3 times in a row" fired only once.

The model alternates the key order of the same arguments: {"op":"check agent","id":"X"} and {"id":"X","op":"check agent"}. `ToolCallIdentity` (Sources/FoundationModelsRouter/Session/IdenticalToolCallRun.swift:34) compares the raw `argumentsJSON` (`GeneratedContent.jsonString`), so the run of identical calls resets.

## Rule
Compare tool-call arguments in a canonical form: parse the JSON, ignore key order (sort keys at every depth), and ignore whitespace. If the text does not parse, fall back to the raw text. Two places use this identity:
- the repeated-tool-call stop (`IdenticalToolCallRun`);
- progress for the recovery budget (`toolCallsThisAnswer`, ^0jbps9v). A call that repeats an earlier one in canonical form is not progress.

There is no guard specific to check agent; this is the generic comparison.

## Subtasks
- [x] RED test: three calls with the same arguments in different key orders trigger the repeated-call stop.
- [x] RED test: a call that repeats an earlier one in a different key order does not reset `recoveriesSinceProgress`.
- [x] Canonicalize in `ToolCallIdentity`, nested objects included.
- [x] Full suite green. #recovery

## Review Findings (2026-11-13 00:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:41` `reuse/reuse` — `keysInOtherOrder` is a second copy of the reordered-key fixture in `IdenticalToolCallLimitTests`, so the key-order case is defined twice. Define the reordered-key fixture once in a shared helper and reference it from both suites.
- [x] `Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift:387` `reuse/reuse` — `sendToolCall(running:)` rebuilds the `{"code": "<code>"}` arguments inline, but `IdenticalToolCallScript.arguments(code:)` already builds the same JSON object for the same purpose. Two helpers now own the same argument shape, so a change to the shape would need to be made in both. Call `IdenticalToolCallScript.arguments(code:)` from `sendToolCall(running:)`, or move the helper to a shared location both models can call.
- [x] `Tests/FoundationModelsRouterTests/IdenticalToolCallLimitTests.swift:38` `reuse/reuse` — `keysInOtherOrder` duplicates the reordered-key JSON fixture that `ConsecutiveRecoveryBudgetTests` already defines, so the same key-order case lives in two files. Move the reordered-key fixture next to `keysInOneOrder` in one shared location and reference it from both suites, as with `keysInOneOrder`.

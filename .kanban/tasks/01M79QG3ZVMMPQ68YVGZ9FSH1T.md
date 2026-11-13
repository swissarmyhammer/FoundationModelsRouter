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
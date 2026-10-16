---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Relay: use the holding run identity for the work flag of a mounted call'
---
## Problem
A tool body in the session task tree can call `ToolContext.mount(tool)` (the default synchronous mount), and the mounted tool can start a `SubagentQuestionRelay`. Then the inner context has `completionToken` T1, but its `holdingRunToken` is the outer run T0 (Extras ToolContext.swift:145-146). The question is held under T0, and its `correlationID` is T0. The relay work flag uses T1 (SubagentQuestionRelay.swift:152). Thus the idle rule (RoutedSessionActorIdle.swift:189-192) does not remove T0, and the parent is idle while its child works.

The relay table is correct: it uses `elicitationId` as the key. E2, complete, finish and close do not use the run token.

An inner `tools.*` call of a Multitool `runCode` snippet cannot be the relaying run, because `SubagentQuestionTarget.current` is nil there.

## Condition
Start only after Extras pushes the public holding run identity (`holdingRunToken` or an equal value) and its CI is green. Then update Extras with `swift package --manifest-cache local update FoundationModelsExtras` (Router and IntegrationTests).

## Work
- [ ] Write a fixed-order test that is red first: a tool calls `ToolContext.mount` with a tool that starts a relay. The parent is not idle while the child works, and it is idle when the child waits only for the user.
- [ ] Use the public holding run identity in `openRelay`.
- [ ] Correct the docs that say "completion token of the run": SubagentQuestionRelay.swift:21-23, RoutedSessionActorRelayedQuestions.swift:84-86, 106, 129-131, 281, RoutedSessionActorIdle.swift:176-179.
- [ ] Run the full suite one time, and build IntegrationTests. #elicitation-phase-4
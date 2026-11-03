---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: An answer at the child ends the relayed copy of the question in the parent
---
## What
When a host answers a question through the child session (`child.respond(elicitationId:response:)`), the relayed copy of the question stays open in the parent until the relay ends (the child closes). It then ends once, as a cancel with reason "run cancelled". Found by the tests of card 01M6GJJKPTESHZGW7N2AAY83G3 (`SubagentSessionAccessTests`).

If both levels answer, the parent still takes its answer and sends it down, but the child keeps the first answer.

Do (design first, in a task comment): the `SubagentQuestionRelay` ends the relayed copy in the parent as soon as the child question ends, with an outcome that says it was answered at the child. Check `RoutedSessionActorRelayedQuestions.swift` and `SubagentQuestionRelay.swift`.

Low priority. It blocks nothing: the host suppresses the relayed copy.

## Acceptance Criteria
- [ ] An answer through the child ends the parent copy at once, once.
- [ ] A later answer at the parent for the same id changes nothing.
- [ ] No change when the parent answers first.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/SubagentSessionAccessTests.swift` or add a relay test file.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents
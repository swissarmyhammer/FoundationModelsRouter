---
assignees:
- claude-code
depends_on:
- 01M5AS7RT8YA6KWDKXHQHWVD8S
position_column: todo
position_ordinal: '8580'
title: A replace signal of a queued mail skips its PrePrompt
---
## Context
Found while doing ^qhwvd8s (Router emits PrePrompt and PostPrompt for each mail).

The session screens each `userMessage` and `agentMessage` mail with one `PrePrompt` when `mail(_:)` puts it in the queue (`RoutedSessionActorPromptHooks.swift`). The signal `replace(_:with:)` (`performReplace(_:with:)` in `RoutedSessionActorCancellation.swift`) changes the body of a queued mail in place, and the model then gets the new text.

## Problem
- A replace of a mail after its screen ended: the model gets the new text, and no `PrePrompt` chain saw that text.
- A replace of a mail while its chain runs: when the chain also changes the text, `admitScreenedPrompt` builds the new body from the body that the chain read, so the replace is lost. When the chain does not change the text, the new body goes to the model with no `PrePrompt` for it.

## What to decide
Decide one rule, for example: a replace of a `userMessage` or `agentMessage` body screens the mail again (one more `PrePrompt` with the same mail id, and still exactly one `PostPrompt`), or a replace of a screening mail waits for the chain.

## Acceptance Criteria
- [ ] A test holds the rule for a replace after the screen ended.
- [ ] A test holds the rule for a replace while the chain runs.
- [ ] Each mail still gets exactly one `PostPrompt`.

#hooks
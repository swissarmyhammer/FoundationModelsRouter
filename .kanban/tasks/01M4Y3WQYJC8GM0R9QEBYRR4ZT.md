---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Put the decline or cancel reason in the prompt text of a mailed elicitation answer
---
Do not start this task until the reviewer says so.

SessionMessage.promptText (Sources/FoundationModelsRouter/Session/SessionMessage.swift) makes the text of a mailed elicitation answer from the action and the content only. Thus a model that gets a mailed decline or cancel does not see the reason.

Change: the prompt text of a mailed elicitation answer includes the reason of a decline or a cancel (ElicitationResponse.reason, Extras task 16, Extras commit cada984), so that the model sees it. An answer with no reason gives the same text as before.

Tests: a decline with a reason, a cancel with a reason, and a decline and a cancel with no reason (the text does not change). #elicitation-phase-1
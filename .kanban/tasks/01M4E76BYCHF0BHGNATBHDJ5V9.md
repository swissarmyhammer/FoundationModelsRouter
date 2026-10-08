---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Turn thinking off only for the recovery pass after a stop, not for the full tool loop
---
## Origin

foundationmodelsacpagent-19 found this in a SWE-bench run of FoundationModelsACPAgent (2026-10-08). The user decided the behavior: only the recovery pass runs with thinking off.

## Problem

After a repeat stop or a reasoning-limit stop, `RoutedSessionActorRepetitionWatch` runs the continuation with `reasoningOff: true` (`RoutedSessionActorRepetitionWatch.swift:579, 583, 613`). `ReasoningOffRequest.requested(around:)` binds `ReasoningOffRequest.isRequested = true` around the full continuation body. The doc comment of `ReasoningOffRequest.reasoningLevel` says: "The level applies to the one call that states it, with each pass of its tool loop." Thus, after one stop, each later pass of the tool loop runs with thinking off until the next submission.

Evidence: in django__django-14155 (session 01M4E1KW6GVA1KPVRD411G7SFQ), a reasoning-limit stop at 10:30:30 (`reasoning.limit=8192 reasoning.tokens=8217 recovery=1`) was followed by 297 generations with 0 reasoning entries, until the timeout at 11:50:33. Before the stop, there were 10 generations, and each had a reasoning entry. Thus one stop turned thinking off for the last 80 minutes of the instance.

## Change

- Only the first model pass after the stop (the recovery pass) runs with thinking off.
- When that pass calls a tool, the next passes of the same tool loop run with thinking on.
- This applies to each path that uses `reasoningOff: true`: the continuation after a repeat stop, the continuation after a reasoning-limit stop, and the final pass (`runFinalPass`). For each path, examine if the rule applies. Record the decision for each path on this card.
- If the model stops again, the existing repetition watch and the recovery count control it. Do not add a new limit.
- Update the doc comments of `ReasoningOffRequest` to state the new scope.

## Related

Task ^v3dt28p keeps the Qwen 3.5 system block the same when thinking goes off and on. Thus a change between off and on during the tool loop does not cause a prompt-cache rebuild for Qwen 3.5. This task does not depend on ^v3dt28p for correct behavior, but without ^v3dt28p each change between off and on causes a full prefill on Qwen 3.5.

## Acceptance

- A scripted test: after a stop, the recovery pass runs with thinking off. The pass calls a tool. The next pass of the tool loop runs with thinking on.
- A scripted test for the final pass, as the card decision for that path states.
- Router `swift test` passes. #session #real-model
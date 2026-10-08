---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4e7ysppcjsbekjxchbvg0mt
  text: |-
    Research:
    - The SDK gives the `contextOptions` of one SDK call (`liveSession.respond` / `streamResponse`) to each pass of its tool loop. `LiveModelLoader.contextOptions(includingSchema:)` sets `reasoningLevel` on those options, so each pass of the tool loop gets "no_think".
    - The one place that sees each pass is `SessionLanguageModel.Executor.respond(to:model:streamingInto:)`. `LanguageModelExecutorGenerationRequest.contextOptions` is a `var` in the macOS 27 SDK interface, so the wrapper can set the level on one pass only.
    - Plan: the backend states a one-shot level on `SessionLanguageModelState` at the start of each SDK call (the "no_think" level, or nil). The first pass takes it and clears it, and sets it on its request. The SDK call itself gets no reasoning level. Each call start writes the value (nil too), so a call that ends before its first pass leaves no stale request. No numeric limit.

    Decision for each `reasoningOff: true` path in RoutedSessionActorRepetitionWatch.swift:
    - `recover` -> `runContinuation` (repeat stop or reasoning-limit stop, no compaction): the rule applies. Only the recovery pass runs with thinking off. The next passes of its tool loop run with thinking on.
    - `recover` -> `compactAndContinue(..., reasoningOff: true)` (stop with compaction first): the rule applies, the same as above. The continuation after the compaction is one SDK call; its first pass is the recovery pass.
    - `runFinalPass` -> `runContinuation(..., reasoningOff: true)`: the rule applies. The first pass of the final pass runs with thinking off. When it calls a tool, the next passes run with thinking on. Reason: the evidence of this card shows that a full tool loop with thinking off is bad, and the existing watch controls a new stop: `finalPassRan` is true, so a stop in or after the final pass gives `WatchStop.stoppedAnswerText`. No new limit.
    - The summarizer call (`respondWithoutReasoning`) has no tools, so it has one pass. No change of behavior.
  timestamp: 2026-10-08T17:11:13.878584+00:00
- actor: claude-code
  id: 01m4e8e6rh1zer4hfgjmf922h2
  text: |-
    Build blocker found and worked around (no tracked file changed):
    - Router HEAD (a149511a) uses `ToolMount.defaultInlineSettleGrace`. That symbol is only in FoundationModelsExtras commit c18a9aa, which is local and not pushed (origin/main of Extras is 5c1c638). The router pins Extras `branch: "main"`, so a clean `swift test` fails with "type 'ToolMount' has no member 'defaultInlineSettleGrace'".
    - `swift package edit FoundationModelsExtras --path ../FoundationModelsExtras` failed with a permission error and removed part of `.build/checkouts/FoundationModelsExtras`. I restored the checkout with `git checkout -- .` and removed the `Packages/` symlink. Do not use `swift package edit` here.
    - Workaround used: in the build cache `.build/checkouts/FoundationModelsExtras`, `git fetch ../FoundationModelsExtras main` and `git checkout --detach c18a9aa`. The build then compiles. Push Extras c18a9aa so that a clean build works again.

    RED: the two new tests in ReasoningStopRecoveryTests fail only on `fixture.log.reasoningLevels == [nil, ReasoningOffRequest.reasoningLevel, nil]` (today the pass after the tool call also gets "no_think").
  timestamp: 2026-10-08T17:19:38.769017+00:00
- actor: claude-code
  id: 01m4e8tm6f8pm7gk928bbpd6dg
  text: |-
    Implementation landed:
    - `SessionLanguageModelState` holds a one-shot reasoning level (`setFirstPassReasoningLevel(_:)`). `SessionLanguageModel.Executor.respond` calls `passRequest(from:)`: the first pass of an SDK call takes the level and sets it on `request.contextOptions.reasoningLevel`; each later pass of the tool loop gets the SDK request unchanged.
    - `LiveModelLoader.prepareCall(includingSchema:)` (was `contextOptions(includingSchema:)`) states the first-pass level ("no_think" or nil) at the start of each SDK call, and gives context options with no reasoning level. The stream path with no request states nil. No numeric limit added.
    - Doc comments updated: `ReasoningOffRequest` (type, `isRequested`, `reasoningLevel`, `requested(around:)`), `ReasoningSwitchable`, the repetition watch, `recover`, `runFinalPass`, `finalPassRan`, `runSubmission`/`runContinuation`/`compactAndContinue` parameters, `RepetitionDetection`, `ReasoningStop`, `RepetitionStop`, `ExecutorPassthrough`, generation-queue.md.
    - Not changed: the log text "a final pass with the reasoning off follows" in `RepetitionDetection.followingStepDescription` (runtime log string; still true for the first pass).
    - GREEN: the two new tests pass. Full `swift test`: 1555 tests in 195 suites passed (2 known issues are existing `withKnownIssue` tests), plus 23 and 19 in the other runs. The one warning is the build-system line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which is in each build and is not from code.
    - Build cache note: `.build/checkouts/FoundationModelsExtras` is at local commit c18a9aa (see the earlier comment). Push Extras c18a9aa, or a clean resolve fails to compile HEAD.

    ### implement — changed
    - evidence: 14 files — Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/ReasoningOffRequest.swift, Sources/FoundationModelsRouter/Core/ExecutorPassthrough.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompactionYield.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorReasoningStop.swift, Sources/FoundationModelsRouter/Session/RepetitionDetection.swift, Sources/FoundationModelsRouter/Session/ReasoningStop.swift, generation-queue.md, Tests/FoundationModelsRouterTests/ReasoningStopRecoveryTests.swift, Tests/FoundationModelsRouterTests/Helpers/StagedReasoningModel.swift, Tests/FoundationModelsRouterTests/Helpers/RepeatingReasoningModel.swift; `swift test` 1555 + 23 + 19 passed, 0 failures
    - next: /review
  timestamp: 2026-10-08T17:26:25.743593+00:00
- actor: claude-code
  id: 01m4e922v9efa35qsw8sk89axm
  text: |-
    ### test - green
    - evidence: swift test - 1555 tests in 195 suites passed with 2 known issues, plus 23 tests in 11 suites and 19 tests in 3 suites passed. 0 failures, 0 skipped. No compiler warnings. The only warning line is the SwiftPM message "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from the tool, not from this code.
    - environment: swift build --build-tests --package-path IntegrationTests fails with 5 errors "type 'ToolMount' has no member 'defaultInlineSettleGrace'" in RoutedLLM.swift, RoutedSessionActor.swift (2) and SessionConfiguration.swift. Cause: IntegrationTests/.build/checkouts/FoundationModelsExtras is at 5c1c638 (remote main). Commit a149511a needs c18a9aa, which is local only. The main checkout .build/checkouts/FoundationModelsExtras is at c18a9aa and builds. I did not change any checkout, and I did not run package update, reset or edit. Not counted against this task.
    - next: review. The IntegrationTests build must be run again after FoundationModelsExtras c18a9aa is pushed and the IntegrationTests checkout is updated.
  timestamp: 2026-10-08T17:30:30.121379+00:00
position_column: doing
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
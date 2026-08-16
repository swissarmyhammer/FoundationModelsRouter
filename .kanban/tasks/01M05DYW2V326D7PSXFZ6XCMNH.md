---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m05e5adqv02s8nvmm80k75kh
  text: |-
    ### What the consumer actually needs — a signal, not a limit

    The `FoundationModelsMultitool` session agrees that the design stays open, and that "no bound" is an acceptable recorded decision.

    They add the useful property: from outside, **a stuck decode is indistinguishable from a slow one**. That is why their search took three sessions.

    Something of the form "this generation has produced no token in N seconds" would have ended the search immediately. It commits us to no kill, no cancellation, and no change to the result.

    So prefer a diagnostic before a limit. A signal is useful even if we decide to bound nothing.
  timestamp: 2026-08-16T14:03:41.879224+00:00
- actor: claude-code
  id: 01m05qq7073w2q5jcbg66a1xmh
  text: |-
    ### Research — where a stall signal can attach, and what it can see

    Picked up the card. Read the generation path.

    **The one chokepoint.** `RoutedSessionActor.runCancellableModelCall(composedPrompt:_:)` (`Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`) is the single place *every* model call crosses:

    - `respond(to:maxTokens:)` -> `generate` -> `runTurn` -> `runTurnAttempt` -> `runCancellableModelCall`, with `respondBody(grammar:maxTokens:)` as the body.
    - `streamResponse` / `streamEvents` -> `streamGenerating`/`streamEventsGenerating` -> `generate` -> ... -> `runCancellableModelCall`, with `streamGeneratingBody(...)` as the body.
    - A fold's summarizer call (`CancellableCompactionSummarizer`) routes through the same method on purpose.

    So one watch installed there covers every generation, guided and unguided.

    **What the watch can see on each path — the honest answer.**

    - Streaming (`streamResponse`, `streamEvents`): `streamGeneratingBody` iterates `backend.streamResponseFragments(to:maxTokens:)`. Each `ResponseFragment` is a real increment. So Router CAN measure "no fragment for N seconds".
    - Non-streaming (`respond`, `dispatchNextPrompt`): the body is `backend.respond(to:maxTokens:)`, which returns one `String`. There is NO increment at all. Router can measure only "this model call has been in flight for N seconds". It cannot say whether a token moved.

    That difference is real and must be stated in the payload, not papered over.

    **Where the signal can travel.** `runTurn` installs `currentTurnEventSink` for the whole turn (`RoutedSessionActor.currentTurnEventSink`), and `turnEventSink(_:)` fans every event out to both the turn's own stream and `streamSessionEvents()`. `streamSessionEvents()` reaches a `respond` caller, which holds no stream of its own. So a `SessionEvent` case is deliverable on every path. An `os_log` line is deliverable with no subscription at all, which matters for the consumer who lost 15 minutes with no instrumentation.

    **Existing bounds, confirmed as the card states.** `DetachingTool.waitSeconds`/`timeout` bound a tool call. `ToolContext.waitSecondsCeiling` bounds a run-plane wait. `parkedRunDrainRoundLimit` bounds the post-turn drain. None bounds a decode.
  timestamp: 2026-08-16T16:50:45.383928+00:00
- actor: claude-code
  id: 01m05rp3fbjwyy8fevev8k66gb
  text: |-
    ### Implementation landed — a stall report, and no bound at all

    The decision is now on the card description under "## The recorded decision", and stated for a caller in `RoutedSession.respond(to:maxTokens:)`'s own documentation.

    **What shipped**

    - `Sources/FoundationModelsRouter/Session/GenerationStall.swift` (new): `GenerationStall` (a `timeWithoutProgress`, a `timeInFlight`, a `visibility`, and a `description` the log line reuses), `GenerationProgressVisibility` (`.fragments(observed:)` / `.wholeAnswer`), the internal `GenerationStallWatch`, the `Generation` logger, and the `RoutedSessionActor` methods that open, feed, report and close a watch.
    - `SessionEvent.generationStalled(GenerationStall)`, delivered through the turn's composed sink, so it reaches the turn's own `streamEvents` stream AND `streamSessionEvents()` — the route a `respond` caller has.
    - The watch is opened and its watchdog started in `runCancellableModelCall`, the single chokepoint every generation crosses (plain, guided, streaming, and a fold's summarizer call). Both are torn down by that method's own `defer`.
    - `streamGeneratingBody` calls `observeGenerationFragments()` before its loop and `noteGenerationFragment()` per fragment. That is the only place a real increment exists.

    **What the report can and cannot observe — the finding the card asked for**

    A fragment counter is possible ONLY on the streaming path. `respond` hands `backend.respond(to:maxTokens:)` a prompt and gets one `String` back; there is no increment anywhere between those two points, so nothing Router adds can time a token there. The report on that path is honest about it: `.wholeAnswer` says the figure is the model call's own duration and nothing more. The alternative — reporting `.fragments(observed: 0)` on a non-streaming turn — would claim coverage Router does not have, so the visibility is declared by the streaming body rather than inferred from "no fragment has arrived yet".

    An explicit `compact(prompt:budget:)` opens no turn frame, so its summarizer call has no event sink and reports to the log alone. Documented on `reportGenerationStall(id:)`.

    **Decisions taken along the way**

    - The reporting interval is an internal `var` on the actor with a `setGenerationStallReportInterval(_:)` method, reached from the suite through the existing `SessionPlumbingAccess` helper. A cross-actor property cannot be written directly, so a method is required. Making the cadence a public `SessionConfiguration` knob was rejected: it drags in the persistable envelope, the nine-parameter `makeSession`, the sidecar restore path, and the configuration round-trip test, none of which this card asks for.
    - The test helper had to be named `installGenerationStallReportInterval(_:)`. A `RoutedSession` protocol-extension member sharing the actor's method name wins overload resolution against the concrete type too, and the first version recursed until the runtime aborted with "Object was retained too many times". Noted in the helper's doc comment so it is not undone.

    **Blast radius: every exhaustive `switch` over `SessionEvent`**

    Adding a case broke five of them, all now handling it explicitly rather than by `default`: `TurnOutcomeFold.apply`, `SessionProjection.apply` (both group it with `discoveryPrimingFailed` as a live-driver diagnostic that changes no state), `Examples/CompactionDemo/main.swift` (prints it), and the two tool-turn comparison suites. `docs/Usage.md` also claimed `streamSessionEvents()` "currently carries a single event type", which was already stale and is now corrected.

    **RED was verified.** With `watchGenerationForStalls` short-circuited, the four stall tests failed (no report observed, no log line) and the negative test still passed. The short-circuit was then removed.
  timestamp: 2026-08-16T17:07:37.579173+00:00
- actor: claude-code
  id: 01m05rpaqhn1tv6yj12mvf7rcd
  text: |-
    ### implement — changed
    - evidence: 14 files — 2 new (Sources/FoundationModelsRouter/Session/GenerationStall.swift, Tests/FoundationModelsRouterTests/GenerationStallDiagnosticTests.swift) and 12 changed (Session/RoutedSession.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorGeneration.swift, Session/RoutedSessionActorTurnExecution.swift, Session/SessionEvent.swift, Session/SessionProjection.swift, Session/TurnOutcome.swift, Examples/CompactionDemo/main.swift, Tests/.../Helpers/SessionPlumbingAccess.swift, Tests/.../ScriptedToolTurnComparisonTests.swift, Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift, docs/Usage.md). `swift build --build-tests` clean, zero warnings. `swift test`: 946 tests in 90 suites passed, 27 in 11 suites passed, 24 in 5 suites passed; 1 pre-existing known issue, zero failures.
    - next: /review
  timestamp: 2026-08-16T17:07:45.009993+00:00
- actor: claude-code
  id: 01m05rqcyvsaepr18v2v1n6f5b
  text: |-
    ### Adding a SessionEvent case is a source break for consumers

    The `FoundationModelsMultitool` session hit this while their build read our working tree live:

    ```
    ScenarioRunner.swift:511: error: switch must be exhaustive
    note: add missing case: '.generationStalled(_)'
    ```

    `SessionEvent` is public, and this package does not build with library evolution. So a public enum is effectively frozen for a consumer: a new case breaks every exhaustive `switch` over it at compile time. The five internal switches this change fixed are our own; a consumer gets no such repair.

    The peer is one such consumer, and they report it as a fact rather than a complaint — a working tree is for exactly this, and they moved to a frozen clone.

    Decide deliberately whether this matters here:

    - If `SessionEvent` is to stay open to new cases, say so in its documentation, so a consumer knows to write a `default` rather than an exhaustive `switch`.
    - If it is to be source-stable, a new case needs a different carrier.

    This does not block the change. It is the kind of break that should be a decision rather than a surprise.
  timestamp: 2026-08-16T17:08:20.059321+00:00
- actor: claude-code
  id: 01m05rvs8jkc8s71y8n2jf6zhj
  text: |-
    ### test — green
    - evidence: `swift build` clean (0 warnings, 5.3s); `swift test` — 946 tests/90 suites passed (1 known issue, pre-existing in `BoundedWait ends every wait on a wall clock...` test, unrelated to this change) + 27 tests/11 suites passed + 24 tests/5 suites passed = 997 tests total, 0 failed, 0 skipped
    - `swift build --target CompactionDemo` builds clean; the executable target compiles
    - confirmed all 5 exhaustive `switch` sites over `SessionEvent` handle `.generationStalled` by name (no `default:` anywhere): `TurnOutcome.apply(_:)`, `SessionProjection.apply(_:)`, `ScriptedToolTurnComparisonTests`, `RealToolTurnComparisonTests`, `Examples/CompactionDemo/main.swift`
    - timing note on `GenerationStallDiagnosticTests.swift`: tests install a 50ms report interval and poll for the stall event through `BoundedWait.conditionReached` (5s ceiling, established helper pattern). This is real wall-clock timing, not a virtual clock — the watcher does a genuine `Task.sleep(for: interval)` before it can report, so the test's pass depends on 50ms of real time elapsing and being observed inside a 5s bound (100x margin). It is not deterministic in the strict sense; it is a generously-bounded, real-time-dependent wait consistent with the suite's existing `BoundedWait` convention. One run was green; no flake was observed, but the mechanism itself is not clock-free.
    - next: none — build and tests clean, ready for review
  timestamp: 2026-08-16T17:10:43.730358+00:00
position_column: doing
position_ordinal: '80'
title: Generation has no timeout, no stall detector, and no diagnostic
---
A decode that never progresses hangs the caller of `respond(to:)` with no signal of any type.

## What exists today

There is no wall-clock timeout, no deadline, no watchdog, and no token-progress or stall detector on the generation path. A sweep of `Sources/` for `timeout|deadline|watchdog|sleep(|ContinuousClock|DispatchTime` gives hits in only two subsystems, and neither one bounds a decode:

- `DetachingTool` — `waitSeconds` (default 5, `Hosting/DetachingTool.swift:59`) and `timeout` (default 120, `:65`). These bound a **tool call**.
- `SessionMailbox` / `ToolContext.waitSecondsCeiling` (86400, `Hosting/ToolContext.swift:42`) — this bounds a **run-plane wait**.

`parkedRunDrainRoundLimit` bounds only the drain that runs after the turn. It never bounds generation.

Router cannot see a stall on the `respond` path, because `liveSession.respond` gives back one string. Only `streamResponseFragments` sees increments, and nothing times them.

## Cancellation is advisory only

`cancelCurrentTurn()` records flags and calls `inFlightModelCall?.cancel()` (`Session/RoutedSessionActorTurnGating.swift:65`). This is cooperative `Task.cancel()` on the task inside the backend call. Whether it unwinds belongs to `MLXLanguageModel`'s `Executor`. `RoutedSessionActorTurnExecution.swift:508-510` says the constrained decode "runs entirely inside `MLXLanguageModel`'s `Executor`, invoked by FoundationModels, never by a loop of our own".

`Tests/FoundationModelsRouterTests/TurnCancellationTests.swift:1274` asserts the limit as intended behaviour: "a turn whose model work ignores cancellation still completes — Router stopped listening, the work did not stop."

## Why this matters

A consumer that hits a stuck decode gets an indefinite hang at 0.0% CPU with no log, no event, and no error. The `FoundationModelsMultitool` session lost 15 minutes on one run before they stopped the process. They had to instrument their own code with `os_log` spans to find where the call stopped.

This card is about the missing signal, not about the deadlock. The deadlock has its own card, but a bound or a diagnostic would have made it visible in seconds instead of hours.

## The recorded decision

**Router bounds nothing, and reports a stall.**

- **No timeout, no deadline, no kill.** A limit small enough to catch a stuck decode kills slow ones, and a decode's honest duration is a property of the model, the prompt, and the machine — three things this package does not know. Reporting a failure for work that was only slow is worse than reporting nothing.
- **A stall watch reports instead.** Every model call opens one (`beginGenerationStallWatch()` inside `runCancellableModelCall`, the single chokepoint every generation crosses). On each interval the call goes with no observable progress, the session writes one `os_log` warning under the `Generation` category and emits `SessionEvent.generationStalled(GenerationStall)`. It repeats, so `timeWithoutProgress` grows — that growth is what separates a stuck decode from a slow one.
- **The default interval is 30 seconds** (`RoutedSessionActor.defaultGenerationStallReportInterval`), changed per session by `setGenerationStallReportInterval(_:)`.
- **What a report may claim differs by path, and the payload says so.** `GenerationProgressVisibility.fragments(observed:)` on the streaming surfaces, where each `ResponseFragment` is a real increment, so the report means "no fragment in N seconds". `GenerationProgressVisibility.wholeAnswer` on `respond`/`dispatchNextPrompt` and on a fold's summarizer call, where the backend hands back one whole `String`, so the report means only "this model call has run N seconds" and never says a token did or did not move.

## Acceptance Criteria

- [x] Recorded which bound the Router gives: a timeout, a stall detector, a diagnostic only, or a documented decision to give none
- [x] A turn that makes no progress produces some signal a consumer can see
- [x] The chosen behaviour is stated in `respond(to:)`'s documentation
- [x] Tests cover the chosen behaviour

Reported by the `FoundationModelsMultitool` session. #bug #long-running #nested-generation
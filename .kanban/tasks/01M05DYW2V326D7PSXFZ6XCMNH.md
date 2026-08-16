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
- actor: claude-code
  id: 01m05s1a5zjv1cf25rsvfcvsdr
  text: |-
    ### commit — changed
    - evidence: `a33b3ae` feat(session)!: report a generation stall instead of bounding generation (^z6xcmnh) — 16 files (2 new), 921 insertions(+), 33 deletions(-)
    - also: `bebd697` chore(kanban): record the ^1zt7vyg completion — a separate, unrelated board update found in the working tree, split out so it does not mix with this task's diff
    - next: none — commit is local only, not pushed
  timestamp: 2026-08-16T17:13:44.895913+00:00
- actor: claude-code
  id: 01m05sbwhk4a8z170rb0cr0n8m
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 1 finding, 1 confirmed, 0 refuted, 9 validators attempted, 0 failed. `Sources/FoundationModelsRouter/Session/GenerationStall.swift:194` `code-hygiene/magic-numbers-swift`
    - scope note: the engine reviewed the diffs only — 13 files reviewed, 2 skipped by `.reviewignore` (`.kanban/`)
    - the three areas the review was pointed at produced no confirmed finding: the stall watch's lifetime and cancellation in `runCancellableModelCall`, the wall-clock timing in `GenerationStallDiagnosticTests.swift`, and the `SessionEvent` source break. The source break stays a recorded decision on this card (comment `01m05rqcyvsaepr18v2v1n6f5b`); no validator asks for a change there.
    - the finding samples one cause. Read the `code-hygiene/magic-numbers-swift` rule text and remove that cause from the whole of `GenerationStall.swift`, not the one line.
    - next: /implement — fix the finding, then re-review
  timestamp: 2026-08-16T17:19:31.379079+00:00
- actor: claude-code
  id: 01m05sccmpec3wnhv62mkbh74n
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 14 files, 2 new; decision recorded as "bound nothing, report a stall"; `SessionEvent.generationStalled` added; visibility declared per path
    - test: green — swift test, 997 tests, 0 failures; CompactionDemo builds; all 5 exhaustive switches handle the new case by name, none by `default`
    - commit: a33b3ae
    - review: findings — Sources/FoundationModelsRouter/Session/GenerationStall.swift:194 (`code-hygiene/magic-numbers-swift`)
    - note: the engine confirmed nothing on the three pointed concerns — the watch's lifetime and cancellation, the wall-clock test timing, and the `SessionEvent` source break.
  timestamp: 2026-08-16T17:19:47.862119+00:00
- actor: claude-code
  id: 01m05srs2hrqcyznpw5zh5xc56
  text: |-
    ### The magic-numbers finding — the rule text, the cause, and the sweep

    **What the rule says.** `code-hygiene/magic-numbers-swift` runs swiftlint's `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`, `severity: warning` and `test_parent_classes: ["QuickSpec", "XCTestCase"]`. Two facts of that rule decide the fix:

    - The rule does NOT report a number that a declaration names. Measured by the rule's own probe: a variable declaration, a stored property, a `static let`, an enumeration raw value and a default parameter are all silent.
    - It DOES report a number inside a call, even when that call is the value of a named declaration.

    So the cause is not "a `30` in the source". The cause is **a number written inside a call, where the declaration names the `Duration` but nothing names the number**. `static let ... : Duration = .seconds(30)` puts `30` in a call argument, so it reports.

    **The sweep of the whole file.** Every numeric literal in `GenerationStall.swift` was read against that cause:

    | site | shape | reports |
    |---|---|---|
    | `defaultGenerationStallReportInterval` | `.seconds(30)` — a call argument | yes, the finding |
    | `attosecondsPerSecond: Double = 1e18` | a `static let` value | no — a declaration names it |
    | `fragmentsObserved: Int = 0` | a stored property, and `0` is allowed | no |
    | `lastGenerationStallWatchId += 1`, `watch.fragmentsObserved += 1` | `1` is allowed | no |

    One site carried the cause. It is fixed by a named `private static let defaultGenerationStallReportIntervalSeconds = 30`, and the interval is now built from that name. The value is unchanged.

    **The other files of `a33b3ae`.** All 13 reviewed files were run through the same rule at the same settings — the 9 sources plus `Examples/CompactionDemo/main.swift` and the 3 test files. Before the fix: 1 finding, the one on the card. After the fix: 0 findings.

    **A test pins the value.** `swiftlint` cannot tell a rename from a value change, so `defaultReportIntervalIsThirtySeconds()` was added to `GenerationStallDiagnosticTests`. It states its own `30` and never reads the source it checks. RED was verified before the fix: with the source temporarily set to `.seconds(31)` the test failed with `31.0 seconds` against `30.0 seconds`; the source was then restored to `30` through the named constant and the test passed.

    **One note for a later reader.** The test's own expectation had to be a named constant too. This suite is a swift-testing `struct`, not an `XCTestCase`, so the rule's test carve-out does not reach it and a bare `.seconds(30)` in the test would have made a second finding.
  timestamp: 2026-08-16T17:26:33.809637+00:00
- actor: claude-code
  id: 01m05srzwynjphy64ktws3sa9e
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Session/GenerationStall.swift, Tests/FoundationModelsRouterTests/GenerationStallDiagnosticTests.swift. `swiftlint no_magic_numbers` at the rule's own settings over all 13 files of `a33b3ae`: 1 finding before, 0 after. `swift build` clean — the one `warning: missing creator for mutated node` line names the vendored `mlx-swift_Cmlx.bundle` and is present on a stashed tree too, so it is pre-existing and not from source. `swift test`: 947 + 27 + 24 = 998 tests, 0 failed, 0 skipped, 1 known issue (the pre-existing `BoundedWait` one). The new test is `the shipped default reporting interval is thirty seconds`.
    - next: /review
  timestamp: 2026-08-16T17:26:40.798277+00:00
- actor: claude-code
  id: 01m05swx7d0ec1tbys028t7m00
  text: |-
    ### test — green
    - evidence: `swift build` clean (no errors, no Swift compiler warnings). `swift test` — 947 tests in 90 suites passed (1 pre-existing intentional known issue in BoundedWaitTests), 27 tests in 11 suites passed, 24 tests in 5 suites passed. Zero failures, zero unintentional skips (the `.enabled(if: integrationEnabled)` real-model suites are pre-existing gated infrastructure, unrelated to this diff).
    - next: ready for review
  timestamp: 2026-08-16T17:28:49.133027+00:00
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

Reported by the `FoundationModelsMultitool` session.

## Review Findings (2026-08-16 12:14)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Session/GenerationStall.swift:194` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants. #bug #long-running #nested-generation
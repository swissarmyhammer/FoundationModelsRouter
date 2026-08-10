---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzp6am61ahqjbrea17qedv1t
  text: |-
    Picked up. Research notes before writing the red test.

    Seams found (all hermetic, no GPU):
    - `LoadedLLMContainer.makeSession(instructions:tools:)` is the factory `RoutedModel.makeSession(...)` calls with its already-elevated `instancedTools` (RoutedLLM.swift). A test container can vend any `LanguageModelSessionBackend`, so a scripted model can be mounted behind a real `RoutedSession`.
    - `Tests/.../Helpers/RouterTestFixtures.swift` + `StubModelLoader` + `PlainTranscriptStubContainer` is the existing pattern for router+profile+session over a stub container (see `RoutedSessionToolContextBindingTests`).
    - `LanguageModelBoundaryProbeTests.swift` already shows how to write a deterministic `LanguageModel` conformer with its own `Executor`. The FoundationModels v2 channel can emit tool calls: `channel.send(.toolCalls(action: .toolCall(id:name:action: .appendArguments(json, tokenCount:))))`, and text via `.response(action: .appendText(...))`. Verified against the macOS 27 SDK swiftinterface.
    - `request.transcript` is the FULL accumulated transcript on every executor call (proved by the boundary-probe suite), so a scripted model can branch on how many `.toolOutput` entries it can see — that is how a multi-call turn (call -> output -> call again -> output -> answer) is scripted deterministically.

    Constraint that shapes the test: `MLXFoundationModelsSessionBackend.init` takes `model: MLXLanguageModel` concretely, so the live backend cannot be built over a scripted model without a production signature change. Red-first discipline forbids touching implementation before a failing test, and the card forbids adjacent refactoring, so the test vends a test-only backend that drives a real `LanguageModelSession` over the scripted model and honours `LanguageModelSessionBackend`'s documented contracts. That keeps `RoutedSession` -> `RoutedSessionActor.generate` -> prompt composition -> backend -> real SDK tool loop under test (where H5 lives), but does NOT cover `LiveModelLoader.pumpStream`'s snapshot-delta code (H1/H2), which the card's own CORRECTION already rules out as the primary cause.
  timestamp: 2026-08-10T15:58:10.625496+00:00
- actor: claude-code
  id: 01kzp6teyv90wy7d94ksmm8dmm
  text: |-
    ## The test PASSES on first write. Stating that plainly, as the card asks.

    New file: `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift`. Both surfaces are green:

    ```
    ✔ respond(to:) answers with every mounted tool output the turn produced
    ✔ streamEvents(to:) answers with every mounted tool output the turn produced
    ```

    Full suite: `swift test` — 780 tests / 73 suites, 24 / 9, 24 / 5. All pass. The only build warning is SwiftPM's pre-existing `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, which names a vendored dependency's resource bundle and is unrelated to this change.

    ### What the test does

    - A scripted `LanguageModel` (`ScriptedToolCallingModel`) with its own `Executor`, emitting real SDK events: `.toolCalls(action: .toolCall(id:name:action: .appendArguments(...)))` and `.response(action: .appendText(...))`.
    - One mounted tool (`MarkerEmittingTool`) whose output is `MARKER-7F3A-<step>`.
    - A **multi-call turn**: the model branches on how many `.toolOutput` entries the transcript it is handed already carries — 0 outputs -> call step ONE, 1 output -> call step TWO, 2 outputs -> answer. So the turn is call -> output -> call again -> output -> answer.
    - The final answer is **composed from the tool output text read back out of the transcript**, never from a canned string. Both tests assert the answer `contains` both markers, and that the tool recorded both steps in order. By content, not by event count.
    - Both surfaces run through one shared assertion (`expectEveryToolOutputReachedTheAnswer`), so the two are held to a single contract by construction.

    ### It went red first — but for a fixture reason, not the bug

    The first run failed with `The selected model does not support tool calling.` The scripted model declared `LanguageModelCapabilities([])`. Declaring `[.toolCalling]` fixed it. That is a defect in my fixture, not evidence about Router, and it is recorded here so it is not mistaken for one.

    ### Proof the test can fail (two deliberate falsifications, both reverted)

    Because a pass on first write proves nothing unless the test has teeth, both failure modes the card names were injected and observed:

    1. **Tool output does not reach generation.** Made the model's transcript reader return a placeholder instead of the tool output's text. Result: **both** tests red, **2 issues each** — both markers missing.
    2. **A loop delivers only the first output.** Made the reader repeat the first tool output in place of the second. Result: **both** tests red, **1 issue each** — `MARKER-7F3A-TWO` missing, `MARKER-7F3A-ONE` still present.

    Both mutations were reverted; the file in the tree is the honest version.

    ### What this rules in and out

    The test drives the real path `RoutedSession.respond/streamEvents -> RoutedSessionActor.generate (prompt composition, outbox drain) -> backend -> a real tool-mounted `LanguageModelSession` -> the SDK's own tool loop`. Everything in that span carries tool output correctly on **both** surfaces.

    So **H5 is not the cause as stated**: `generate`'s prompt composition with an empty outbox does not break the turn, and a tool-eligible user turn survives it on both surfaces.

    **H1 is NOT confirmed reachable by this test.** The scripted model emits no text before its tool calls, so the snapshots are `"" -> answer` and stay monotonic. The non-monotonic branch was never taken here. This test says nothing about it either way.

    ### What is NOT covered, and why

    `MLXFoundationModelsSessionBackend.init` takes a concrete `MLXLanguageModel`, so the live backend cannot be built over a scripted model without a production signature change — which red-first discipline and the card's no-adjacent-refactoring scope both forbid at this point. The suite therefore vends a test-only `ScriptedToolCallingBackend` of the same shape. Consequence: `LiveModelLoader.pumpStream`'s snapshot-delta code (H1/H2) is **not** under this test. The card's own CORRECTION already rules that region out as the primary cause, since `respond(to:)` never touches it and is also 0/4.

    ### Gated suites: NOT RUN, deliberately

    `FM_ROUTER_INTEGRATION_TESTS=1` and `MULTITOOL_INTEGRATION=1` were not run. They load a 27B model and take 8-11 minutes of GPU and network this step is not the place to spend, and the acceptance-criteria line that mentions the gated suite is conditional ("green if that suite touches this path"). Reported as not-run rather than run.

    ### The next step the card names

    Diff the transcript entries each surface actually hands the SDK, on a **real** model rather than a scripted one. This hermetic test proves the plumbing carries tool output; the 0/4 real-model result therefore points at something the scripted model does not reproduce — most plausibly the content of the transcript a real model is handed (instructions/priming/tool schema rendering), not the delivery of tool output. `^vhjhaey`'s parity harness is the instrument.

    Not filed as a separate task — say the word and it will be.

    ### Acceptance criteria, item by item

    - [x] scripted model + streamEvents, asserted by content
    - [x] the same claim through respond(to:), one shared contract
    - [ ] "failed before the fix and passes after" — **unsatisfiable as written, and that IS the result**: there is no fix, because there is no red to fix. Both outcomes are stated above: red only under fixture error and under deliberate falsification; green as written. The card's own "If the hypothesis is wrong" clause governs this case.
    - [x] multi-call turn: call -> output -> call again -> output -> answer
    - [x] `swift test` green; gated suite not run, for the reason above

    The description's checkboxes are left untouched on purpose: `update task` is known in this repo to flatten description newlines, and this card's description is the whole investigation record. Its status is recorded here instead.
  timestamp: 2026-08-10T16:06:49.563930+00:00
- actor: claude-code
  id: 01kzp6tptpm6nhm3q8h3qqhmqc
  text: |-
    ### implement — changed
    - evidence: 1 file added — `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift` (419 lines). No production file touched. Red first: the first run failed with "The selected model does not support tool calling" — a fixture defect (the scripted model declared no `.toolCalling` capability), not the defect under test. Once fixed, **both surfaces pass on first write**. Teeth proved by two reverted falsifications: redacting tool-output text reddens both tests on both markers; repeating the first output reddens both tests on the second marker only. `swift test` green — 780/73 + 24/9 + 24/5, zero failures, no new warnings. NOT RUN: `FM_ROUTER_INTEGRATION_TESTS=1` and `MULTITOOL_INTEGRATION=1` (27B model, 8-11 min).
    - next: `/review`. The card's own "If the hypothesis is wrong" branch applies — the next investigative step is to diff the transcript entries each surface hands the SDK against a real model.
  timestamp: 2026-08-10T16:06:57.622366+00:00
- actor: claude-code
  id: 01kzp6vc9k52nmzpk4s1v14k3d
  text: |-
    ### H4's premise looks false for the `RoutedSession` path — worth checking before spending a gated run on it

    The card says "Router hands the SDK a *wrapped* model handle". Read against the source, that is not what the `RoutedSession` path does:

    - `RoutedModel.makeSession(...)` (`Sources/FoundationModelsRouter/RoutedLLM.swift`) builds its backend through `container.makeSession(instructions: instructions, tools: instancedTools)`.
    - The live container's `makeSession(instructions:tools:)` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`) is literally `LanguageModelSession(model: model, tools: tools, instructions: instructions)` where `model` is the **raw `MLXLanguageModel`** stored on `MLXFoundationModelsContainer`. The transcript-seeded factories and `makeFork(tools:)` go through `makeSessionBackend(model:...)`, also typed `model: MLXLanguageModel`.
    - `RecordingLanguageModel` is vended **only** by `RoutedModel.makeLanguageModel()` / `makeLanguageModel(resuming:registry:)` — a separate public factory for a host that builds its own `LanguageModelSession`. Nothing on the `RoutedSession` path constructs one.

    So unless FoundationModelsMultitool's runner calls `makeLanguageModel()` and builds its own session (worth confirming on that side), a `RoutedSession` turn already runs against the raw model handle — the same handle the passing plain-session configuration uses. That would make the recording wrapper not the mechanism, and H4's "run it twice, raw vs wrapped" test would compare the raw handle against a handle the failing path never uses.

    Stated as a reading of the source, not as a measurement. It is cheap to confirm on the consumer side and it would save a gated run.
  timestamp: 2026-08-10T16:07:19.603707+00:00
- actor: claude-code
  id: 01kzp7189srfjfe4y8j4e73w8c
  text: '### test — green\n- evidence: `swift test` — 780 tests / 73 suites passed (2.733s); 24 tests / 9 suites passed; 24 tests / 5 suites passed. Zero failures anywhere in the run, zero skipped tests (all \"skip\"/\"failed\" hits are test-name text, not outcomes). One warning, pre-existing and unrelated: `missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS` (vendored dependency resource bundle). New suite \"Mounted tool output reaches the model''s next generation\" ran both tests, both passed: `respond(to:) answers with every mounted tool output the turn produced` and `streamEvents(to:) answers with every mounted tool output the turn produced`.\n- `git diff -- Sources` confirmed empty: no production code changed.\n- New file confirmed untracked (`?? Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift`) via `git status --porcelain`; will need `git add` at commit time.\n- H4 claim independently verified by reading source, not by trusting the report: `RoutedLLM.swift` builds the `RoutedSession` backend via `container.makeSession(instructions:tools:)`. `LiveModelLoader.swift`''s `MLXFoundationModelsContainer.makeSession(instructions:tools:)` builds `LanguageModelSession(model: model, tools: tools, instructions: instructions)` over the stored `model: MLXLanguageModel` — the raw handle, never wrapped. `RecordingLanguageModel` is constructed only inside `RoutedModel.makeLanguageModel()` and `makeLanguageModel(resuming:registry:)`, both separate public factories nothing on the `makeSession`/`RoutedSession` path calls. So the report''s claim holds: H4''s premise (\"Router hands the SDK a wrapped model handle\") is false for the `RoutedSession` path as written; `RecordingLanguageModel` does not reach it by any route found.\n- Teeth confirmed by inspection (no re-run of the injections): `ScriptedToolCallingModel.Executor.respond` composes the final answer from `toolOutputTexts(in: request.transcript)` — text read out of `.toolOutput` transcript entries — never a canned string, and only emits the answer once `toolOutputs.count` reaches `steps.count`. `expectEveryToolOutputReachedTheAnswer` asserts `tool.calledSteps == steps` (both calls happened, in order) and then loops over `ToolOutputFeedbackFixture.markers`, asserting each marker separately with its own `#expect` — so a loop delivering only `MARKER-7F3A-ONE` would fail on the `TWO` assertion independently.\n- Both surfaces confirmed on one contract: both `respondFeedsToolOutputBackIntoGeneration` and `streamEventsFeedsToolOutputBackIntoGeneration` call the same `Self.expectEveryToolOutputReachedTheAnswer(answer, tool: tool)`, no divergent copies.\n- Gated suites (`FM_ROUTER_INTEGRATION_TESTS=1`, `MULTITOOL_INTEGRATION=1`) intentionally NOT run, per instructions.\n- next: hand back to caller for review/commit decision.'
  timestamp: 2026-08-10T16:10:32.121689+00:00
position_column: doing
position_ordinal: '80'
title: '[Router] TDD: prove streamEvents feeds tool output back into generation'
---
FOR THE ROUTER AGENT. Filed from FoundationModelsMultitool, where a real-model suite scores **0/4 on a `RoutedSession`** and **1/4–3/4 on a plain `LanguageModelSession`** with the same tools, same prompts, same model, same commit.

## The symptom, from three gated runs

```
toolCalls=4  failedCalls=0  invoked=[]  reply="I don't have access to real-time weather data"
toolCalls=3  failedCalls=0  invoked=[]  reply="I don't have access to your trip itinerary"
toolCalls=19 failedCalls=0  invoked=[]  reply="I don't have access to your trip itinerary"
toolCalls=8  failedCalls=0  invoked=[]  reply="the system does not have a function available to look up or confirm bookings"
```

The model **issues** tool calls. **None fail.** And it then answers as though it had never learned anything — in one case asserting no such function exists, when the function is mounted and its typed signature is exactly what the tool it called returns.

That is the signature of a turn where tool output does not reach the model's context for continued generation. If a `searchTools` call returns typed signatures and the model never sees them, it cannot know the paths, and "there is no such function" is the correct conclusion from its point of view.

## What has already been eliminated — do not re-investigate

Verified from the consumer side with no model in the loop (`RouterSessionMountTests`, FoundationModelsMultitool commit `b46b372`), driving `ToolElevation.wrapping(configuration: .nativeSessionMount)` directly:

- **The mount is transparent.** `searchTools` returns 593 bytes direct and 593 through the mount, byte-identical. `runCode` returns `"3"` both ways.
- **The model-facing surface is untouched.** Same `name`, same `description`; `ElevatingTool` forwards `parameters` and `includesSchemaInInstructions` too.
- **Argument decoding is intact.** The wrap resolves to `ElevatingTool<SearchToolsArguments>` and `ElevatingTool<RunCodeArguments>` — the concrete `Arguments` type survives, not erased.
- **Elevation never fires in these scenarios.** `waitSeconds` defaults to 5; none of the four fixtures sleeps. (The only sleeping fixture is a deep-scan tool at 8s, used by a different suite.)
- **Capping is off.** `sessionMounted` caps "only when `cappedToTokenLimit` is set", and the runner sets no limit.

So the tools and their wiring are fine. What differs is how the session drives the tool loop: `RoutedSession.streamEvents` versus `LanguageModelSession.respond(to:)`.

## TDD

**Red first. Do not touch the implementation until a test fails for this reason.**

1. **Write the failing test.** A deterministic model (Router already has `RecordingLanguageModel` and the scripted-model machinery) plus one mounted tool whose output carries a distinctive token — say `"MARKER-7F3A"`. Script the model to call that tool, then, on its next turn, to answer with whatever it was told. Drive it through `RoutedSession.streamEvents(to:)` and assert the **final answer contains `MARKER-7F3A`**.

   If the tool output never re-enters generation, this fails. That failure is the bug, pinned, in under a second and with no GPU.

2. **Assert the same claim through `respond(to:)`** in the same test file. Both surfaces must pass it. If `respond(to:)` passes and `streamEvents` fails, that difference is the defect and the diff is small.

3. **Then fix**, and both go green.

## Acceptance Criteria

- [ ] A test drives a scripted model through `streamEvents` and asserts a mounted tool's output reaches the model's next generation, by content, not by event count
- [ ] The same claim is asserted through `respond(to:)`, so the two surfaces are held to one contract
- [ ] The test failed before the fix and passes after — state both outcomes in the task record
- [ ] A multi-call turn is covered: call → output → call again → output → answer, so a loop that delivers only the first output is caught
- [ ] `swift test` green; `FM_ROUTER_INTEGRATION_TESTS=1` green if that suite touches this path

## If the hypothesis is wrong

Then this test passes on the first write, and that is a real result worth recording — say so on the task rather than deleting the test. The next candidate is the transcript the session hands the SDK: build the same two-tool turn on both surfaces and diff the transcript entries the model is actually given. The consumer-side evidence above rules out the tools themselves, so the difference is somewhere between `streamEvents` and the SDK.

## Reproduction, if a live check is wanted

FoundationModelsMultitool at `b46b372`, `MULTITOOL_INTEGRATION=1 swift test --filter SearchThenCallTests`. ~11 minutes, 4 scenarios. It currently points at Router by local path, so a Router fix is picked up with no push. Flip `scenarioDiscoveryPriming` in `ScenarioRunner.swift` to compare primed and unprimed; both are 0/4 today.
## Ranked hypotheses, from reading Router's own two paths

Added after tracing both backend entry points. The split is real and narrow:

```
respond(to:)   -> respondBody          -> LiveModelLoader.respond
                                       -> liveSession.respond(to:options:)
streamEvents   -> streamGeneratingBody -> LiveModelLoader.streamResponse
                                       -> liveSession.streamResponse(to:options:) -> pumpStream
```

Apple's `respond` drains the tool loop internally and hands back only the final, post-tool answer. `streamResponse` hands back **cumulative snapshots**, and `pumpStream` converts them to fragments. Every hypothesis below lives in that conversion.

### H1 — the snapshot delta breaks across a tool boundary (most likely, and it is a one-line read)

`LiveModelLoader.swift:395`:

```swift
private static func suffix(of current: String, after previous: String) -> String {
    guard current.hasPrefix(previous) else { return current }
    return String(current.dropFirst(previous.count))
}
```

Its own doc calls the non-prefix branch *"a defensive fallback for a non-monotonic snapshot, not expected in practice."*

**In a tool-using turn it is expected, every time.** The model generates a first pass, a tool runs, and generation resumes on a *new* answer. The post-tool snapshot does not have the pre-tool text as a prefix, so the guard fails, the whole snapshot is returned as if it were a delta, and `streamGeneratingBody`'s `response += chunk` concatenates rather than extends. `previous` is also never reset at a turn boundary — it is `var previous = ""` for the life of one `pumpStream`.

**Test:** scripted model, one tool, snapshots that deliberately go non-monotonic across the call. Assert the accumulated response equals the final answer exactly — no duplicated prefix, no stitched-together halves. A char-level equality assertion, not `contains`.

### H2 — the stream ends at the first tool boundary, so the answer is the pre-tool text

If Apple's snapshot stream finishes at the tool-call boundary and a *new* stream carries the continuation, `pumpStream` returns at that first `finish()` and the accumulated text is the model's first pass.

This matches the consumer evidence better than anything else: every failing reply is a *plausible first-pass refusal* — "I don't have access to real-time weather data" — while `toolCalls` reads 3–19 and `failedCalls=0`. Apple keeps looping; Router already returned.

**Test:** scripted model whose pre-tool text is `"BEFORE"` and post-tool answer is `"AFTER-42"`. Drive `streamEvents`; assert the final answer is `"AFTER-42"` and does **not** equal or contain `"BEFORE"`. If it yields `"BEFORE"`, H2 is confirmed and the fix is to keep pumping until generation is genuinely complete.

### H3 — tool output never re-enters generation on the streaming path

The original hypothesis, now third. Weaker than H1/H2 because it would require Apple's own session to behave differently under `streamResponse` than under `respond`, which is a stronger claim than a splicing bug in our own delta code.

**Test:** the `MARKER-7F3A` test in the Acceptance Criteria above.

### Ruled out from the consumer side — do not spend time here

`RouterSessionMountTests` in FoundationModelsMultitool (`b46b372`), no model in the loop, driving `ToolElevation.wrapping(configuration: .nativeSessionMount)`:

- mount is byte-transparent (593 bytes in, 593 out for `searchTools`; `"3"` for `runCode`)
- `name`, `description`, `parameters`, `includesSchemaInInstructions` all forwarded
- concrete `Arguments` type survives (`ElevatingTool<SearchToolsArguments>`)
- elevation cannot fire — `waitSeconds` is 5 s and no fixture in these scenarios sleeps
- capping is off — `sessionMounted` caps only when `cappedToTokenLimit` is set

### Suggested order

H2 first — it is the cheapest to falsify and it best fits the observed replies. Then H1, which is a real defect regardless of whether it is *this* defect: the non-monotonic branch is reachable and its doc says it should not be. Then H3.

Whichever lands, `^vhjhaey`'s parity harness is what stops the next one.

## CORRECTION — `respond(to:)` is also 0/4. The hypotheses above are wrong.

Measured after filing them. The four scenarios were re-run through `RoutedSession.respond(to:)` instead of `streamEvents`, everything else identical:

```
RESULT [singleCallWeather]         invoked=[] overRefusal=1  "I'm unable to retrieve the current weather information for Austin"
RESULT [composeChain]              invoked=[] overRefusal=1  "I don't have access to your trip itinerary"
RESULT [discoveryUnderDistractors] invoked=[] overRefusal=1  "I don't have access to your trip itinerary"
RESULT [repairFromTripProneTool]   invoked=[] overRefusal=1  "I do not have access to your booking system or database"
```

**0/4 on both Router surfaces.** So this is not a streaming defect, and H1/H2/H3 above — all of which live in `pumpStream`'s snapshot-delta handling — cannot be the primary cause. H1 is still a real latent bug worth fixing (the non-monotonic branch its own doc calls "not expected in practice" is reachable), but it is not this.

Note also `overRefusal=1` on all four here versus `0` on the streaming runs: on `respond` the model refuses having made **no tool call at all**. That is a cleaner, earlier failure than the streaming arm showed.

## Where to look instead — what both surfaces share and the plain session does not

Both funnel through `RoutedSessionActor.generate(grammar:prompt:body)` and both run against Router's own persistent backend session. The plain `LanguageModelSession(model:tools:)` that scores 1/4–3/4 shares neither.

Confirmed while narrowing, so do not re-check: tools **do** reach the SDK. `LiveModelLoader.swift:159` is `LanguageModelSession(model: model, tools: tools, instructions: instructions)`, and `ToolElevation.wrapping` is byte-transparent when called directly.

### H4 — the recording model wrapper changes tool-calling behaviour (check first)

`RecordingLanguageModel`'s own doc says a host would otherwise "build a `LanguageModelSession(model:tools:instructions:)` over directly". Router hands the SDK a *wrapped* model handle; the passing configuration hands it a raw `MLXLanguageModel`. If that wrapper does not faithfully forward whatever the SDK needs to drive a tool call, no tool ever runs — which is exactly `invoked=[]` with a refusal.

**Test:** one scripted-model turn with one mounted tool, run twice — once against the raw model handle, once against the recording-wrapped handle — asserting the tool executed and its output reached the answer. If only the raw handle passes, this is it.

### H5 — `generate`'s prompt composition drops or reshapes the turn

`generate` "composes `prompt` with whatever the outbox drains for this turn". If composition alters the prompt such that the SDK no longer treats it as a tool-eligible user turn, the model answers from priors — again `invoked=[]` plus a refusal.

**Test:** assert the exact string handed to the backend equals the caller's prompt when the outbox is empty. No queued prompts, no compaction — byte equality.

### H6 — instructions

Router passes `instructions:` through; this consumer passes `nil`, and the plain session omits the parameter entirely. If `instructions: nil` and *no* instructions argument are not equivalent under the SDK, that is a difference in exactly the right place.

**Test:** same turn, three sessions — no instructions argument, `instructions: nil`, `instructions: ""` — assert all three execute the tool.

### Suggested order

H4, then H5, then H6. H4 is the only one that explains the failure on *both* surfaces with a single mechanism, and it is the one structural difference between Router's session and the plain session that has not been eliminated.

Reproduction unchanged: FoundationModelsMultitool, `MULTITOOL_INTEGRATION=1 swift test --filter SearchThenCallTests`, ~8–11 min. It points at Router by local path. The runner currently drives `respond(to:)`; `streamTurn` is still in the file to switch back to.

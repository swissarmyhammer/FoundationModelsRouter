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
- actor: claude-code
  id: 01kzp7kv0p3fe6c10j3e61qa2q
  text: |
    ### review — findings
    - scope: review sha HEAD~1..HEAD (4f1da63) — one new test file, no Sources change
    - evidence: 3 findings, 3 confirmed, 13 refuted, 9 attempted, 0 failed — Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift:284, :296, :300
    - all three findings ask for documentation comments on new LanguageModelSessionBackend conformance methods in the new scripted-backend fixture
    - the file is ALL new code, so the "do not refactor tests that already existed" exception does not apply to it
    - no acronym-casing finding was returned, so no waiver was needed
    - next: add the three documentation comments, then re-review
  timestamp: 2026-08-10T16:20:41.110815+00:00
- actor: claude-code
  id: 01kzp7nwjh9cb47zk7xmbd51e4
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 1 new file, `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift` (419 lines). No production file touched (`git diff -- Sources` empty).
    - **HEADLINE: the test PASSES on first write.** The hypothesis it was written to pin is wrong at this level. Per the card's own "If the hypothesis is wrong" branch, this is recorded rather than deleted. The only red seen first was a fixture defect (the scripted model declared `LanguageModelCapabilities([])`, so the SDK refused a tool-mounted session); declaring `[.toolCalling]` fixed that and both surfaces went green immediately. That does not count as the red the card wanted.
    - **Teeth proved by two injections, both reverted.** Redacting the tool-output text the model reads back → both tests red on both markers. Repeating the first tool output in place of the second → both tests red on `MARKER-7F3A-TWO` only, which is what demonstrates the multi-call coverage actually works.
    - **What the investigation eliminated.** H5 is not the cause as stated: prompt composition with an empty outbox carries a tool-eligible turn through intact on both surfaces. **H4's premise is FALSE for the `RoutedSession` path** — verified independently by reading source: `RoutedLLM.swift` goes through `container.makeSession(instructions:tools:)`, and `MLXFoundationModelsContainer.makeSession` builds `LanguageModelSession(model:tools:instructions:)` over the raw `MLXLanguageModel`; `RecordingLanguageModel` is constructed only in `RoutedModel.makeLanguageModel()` / `makeLanguageModel(resuming:registry:)`, which nothing on the session path calls. H4 was the card's top-ranked remaining hypothesis, so this saves a gated run. **H1 was NOT confirmed reachable** (the scripted model emits no pre-tool text, so snapshots stayed monotonic) and was deliberately NOT fixed.
    - **Known limitation:** `MLXFoundationModelsSessionBackend.init` takes a concrete `MLXLanguageModel`, so the live backend cannot be built over a scripted model without a production signature change. `LiveModelLoader.pumpStream`'s snapshot-delta code is therefore outside this test — which the card's own CORRECTION already ruled out as the primary cause.
    - test: green — swift test 780/73 + 24/9 + 24/5, 0 failures, no new warnings. Teeth re-confirmed by inspection: the answer is composed from `toolOutputTexts(in: request.transcript)` and only emitted once `toolOutputs.count == steps.count`; each marker is asserted in its own `#expect`; both surfaces call the one shared `expectEveryToolOutputReachedTheAnswer`.
    - **NOT RUN:** `FM_ROUTER_INTEGRATION_TESTS=1` and `MULTITOOL_INTEGRATION=1` (27B model, 8–11 min). The acceptance-criteria line naming the gated suite is conditional and is reported as not-run. The criterion "failed before the fix and passes after" is unsatisfiable as written, because there is no fix — both outcomes are stated instead.
    - commit: 4f1da63 — 3 files, +698, local only. `ToolOutputFeedbackTests.swift` confirmed present via `git show --stat HEAD`.
    - review: findings — ToolOutputFeedbackTests.swift:284 (`makeFork`), :296 (`transcriptEntries`), :300 (`usageTokenCounts`), all undocumented `LanguageModelSessionBackend` conformance methods. Engine: 9 attempted, 0 failed, 3 confirmed, 13 refuted. Nothing filed contesting the passing diagnostic result or calling the test redundant. All new code, so the pre-existing-test exception shields none of it.
    - next: iteration 2 — document those members, sweeping the whole file rather than the three cited lines.
  timestamp: 2026-08-10T16:21:48.241375+00:00
- actor: claude-code
  id: 01kzp822k929j55kqdn4pbhfgj
  text: |-
    ## Iteration 2 — the rule text, read before writing

    Pulled the applicable rules with `dump validators` on the file, then read the two that govern this work word for word (`get validator missing-docs`, `get validator swift`).

    **What `missing-docs` actually requires** — it exempts "functions explicitly marked as tests by attribute or framework convention", but it carries an explicit yield clause: *"These exemptions yield to stricter language-specific documentation rules. Where a language validator requires documentation on every public item (e.g. the Swift and Rust documentation rules), that rule wins and the 'obvious implementation' / 'simple getter' carve-outs above do not apply."* So the "simple getter with a self-explanatory name" escape does NOT shield `name`/`description` on the tool. That is why the sweep documented them.

    **What `swift/documentation` requires** — every `public`/`open` declaration carries a `///`; `///` never `/** */`; a single-sentence summary ending in a period, elaboration after a blank `///` line; **"Document exactly the parameters, return, and throws the signature has — no more, no less"**; `- Returns:` iff the result is non-`Void`; `- Throws:` iff the function `throws`. Its first line is also the one exemption used here: **"There is NO NEED to put doc comments on test methods."**

    **The distinction this repo keeps getting bitten by, stated as the rule states it** — `swift/doc-parameter-naming`: *"`- Parameter` / `- Parameters:` entries name the internal (local) parameter, never the external argument label"*, and *"DocC symbol links follow the declaration, not this rule — a cross-reference like ``capped(text:)`` uses the function's external argument labels because that is the symbol's name."* The direction is fixed in both places; flagging a correct internal name toward the external label is a validator error.

    Applied both ways, deliberately:
    - Every `- Parameter` key is the **internal** name — `prompt` (not `to`), `transcript` (on `replacingTranscript(_ transcript:)`, whose label is `_`), plus `arguments`, `grammar`, `maxTokens`, `instructions`, `tools`.
    - Every DocC symbol link is the **external** label form — ``makeFork(tools:)``, ``makeSession(instructions:tools:)``, ``pumpStream(prompt:options:into:)``, ``RoutedSession/respond(to:)``, ``RoutedSession/streamEvents(to:)``, ``RoutedSessionActor/compact(prompt:budget:)``.

    Prevailing pattern followed from `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift`, the repo's other `LanguageModelSessionBackend` fixture: conformance methods carry a summary saying what this conformer does differently, not a restatement of the protocol.
  timestamp: 2026-08-10T16:28:27.625054+00:00
- actor: claude-code
  id: 01kzp8305ree12wt35xm7v002e
  text: |-
    ### The file-wide sweep — 12 more undocumented members beyond the 3 cited

    A finding shows one example of a cause. The cause here is "a member of this new fixture carries no doc comment", and the review engine sampled three of them. Sweeping the whole file found **15** undocumented members, not 3:

    **Cited by the review (3)**
    - `ScriptedToolCallingBackend.makeFork()`
    - `ScriptedToolCallingBackend.transcriptEntries()`
    - `ScriptedToolCallingBackend.usageTokenCounts()`

    **Found by the sweep, same cause, not cited (12)**
    - `MarkerEmittingTool.name`
    - `MarkerEmittingTool.description`
    - `MarkerEmittingTool.call(arguments:)`
    - `ScriptedToolCallingBackend.respond(to:maxTokens:)`
    - `ScriptedToolCallingBackend.streamResponse(to:maxTokens:)`
    - `ScriptedToolCallingBackend.respond(to:following:maxTokens:)` (the guided entry point)
    - `ScriptedToolCallingBackend.makeFork(tools:)`
    - `ScriptedToolCallingBackend.replacingTranscript(_:)`
    - `ScriptedToolCallingContainer.makeSession(instructions:)`
    - `ScriptedToolCallingContainer.makeSession(instructions:tools:)`
    - `ScriptedToolCallingContainer.makeSession(transcript:)`
    - `ScriptedToolCallingContainer.makeSession(transcript:tools:)`

    So the review's three were a **quarter** of the actual violations of the same rule. Fixing only the cited lines would have left nine more `LanguageModelSessionBackend`/`LoadedLLMContainer` conformance methods and the whole mounted-tool surface bare, and the next review round would have found them.

    **Left undocumented on purpose (2), with the rule that permits it:** `respondFeedsToolOutputBackIntoGeneration` and `streamEventsFeedsToolOutputBackIntoGeneration`. `swift/documentation`'s first line is "There is NO NEED to put doc comments on test methods", and `missing-docs` exempts items marked by test attribute. Both carry `@Test` display names that already state the claim.

    Everything else in the file was documented when it was written in iteration 1 — the fixture constants, the scripted model and its `Executor` (including `Configuration`, `emittedTokenCount`, and `toolOutputTexts(in:)`), both backend initializers, `pumpStream`, `FixtureError`, the container's `model`/`languageModel`, and the suite's own helpers. Those were re-read, not rewritten.

    ### What the docs say, and why that mattered here

    Written to carry the fixture's reasoning forward, since the card notes other harnesses will copy this file:
    - `call(arguments:)` states **why** the marker is the assertion's whole basis — it is the only place that step's marker exists in the turn, so an answer carrying it can only have come from the output reaching generation.
    - The two generation entry points name which Router surface each one actually serves (`RoutedSession/respond(to:)` vs `RoutedSession/streamEvents(to:)`) — the two surfaces this card exists to hold to one contract.
    - `makeFork()`/`makeFork(tools:)` and the container's `tools:` overloads state why the protocol's tool-dropping defaults are **not** taken: dropping the tools would leave the turn nothing to call, and the test would then be asserting on a fixture defect rather than on Router. That is the exact trap iteration 1 already fell into once, with `LanguageModelCapabilities([])`.
    - The guided `respond` says why failing loudly beats returning unconstrained text.
    - `transcriptEntries()`/`usageTokenCounts()` say plainly that nothing in this suite reads them and they exist because the protocol requires them — an honest note is worth more to the next author than an invented purpose.

    ### Verification

    - `swift test` — 780 tests / 73 suites, 24 / 9, 24 / 5. **Zero failures.** Both tests of the new suite still pass (`respond(to:) answers with every mounted tool output the turn produced`, `streamEvents(to:) answers with every mounted tool output the turn produced`). The only warning is the pre-existing SwiftPM `missing creator for mutated node ... mlx-swift_Cmlx.bundle`, a vendored dependency's resource bundle.
    - `git diff -- Sources` — **empty**. No production file touched.
    - No test behaviour or assertion changed. The scripted model, the shared assertion `expectEveryToolOutputReachedTheAnswer`, and the marker checks are byte-identical; only `///` lines were added.
    - `swift format`/`swiftformat` NOT run, per the project constraint.

    ### Lint counts before/after — reported plainly rather than guessed

    I could not run a deterministic linter for this rule, and I am saying so rather than inventing numbers.

    - There is **no `.swiftlint.yml`** anywhere in this repo (`find . -maxdepth 2 -name ".swiftlint*"` returns nothing). `swiftlint` is installed at `/opt/homebrew/bin/swiftlint`, but with no project config it would run its own default rule set, which is not what produced these findings and would report unrelated noise.
    - The repo's `.validators/` directory is **empty**; `missing-docs` resolves to the user-layer LLM validator at `/Users/wballard/.validators/missing-docs` (`source_layer: user`). It is a model-driven validator run by the `review` engine, not a static linter with a violation count.
    - **Before:** 3 confirmed findings, from the recorded iteration-1 review run (9 attempted, 0 failed, 3 confirmed, 13 refuted) — `:284`, `:296`, `:300`.
    - **After:** not measured here. `/implement` is explicitly barred from self-reviewing, so the after count is the `/review` step's to produce.
  timestamp: 2026-08-10T16:28:57.912893+00:00
- actor: claude-code
  id: 01kzp83c1c9fz54sxbw1gg6npj
  text: |-
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift` (419 -> 554 lines, `///` comments only). All 3 review findings (`:284` `makeFork`, `:296` `transcriptEntries`, `:300` `usageTokenCounts`) fixed and checked off in the description. The file-wide sweep found **12 more members with the same cause** and documented them too: `MarkerEmittingTool.name`/`.description`/`.call(arguments:)`; `ScriptedToolCallingBackend.respond(to:maxTokens:)`, `.streamResponse(to:maxTokens:)`, the guided `.respond(to:following:maxTokens:)`, `.makeFork(tools:)`, `.replacingTranscript(_:)`; all four `ScriptedToolCallingContainer.makeSession` overloads. The 2 `@Test` methods are left bare under `swift/documentation`'s "There is NO NEED to put doc comments on test methods". Rule text obeyed in both directions: `- Parameter` keys are internal names (`prompt`, `transcript`, `arguments`, `grammar`, `maxTokens`, `instructions`, `tools`), DocC symbol links are external labels (``makeFork(tools:)``, ``pumpStream(prompt:options:into:)``, ``RoutedSession/respond(to:)``). `swift test` green — 780/73 + 24/9 + 24/5, 0 failures, no new warnings. `git diff -- Sources` EMPTY. No behaviour or assertion changed. Gated suites NOT RUN. No swift format run. Lint before/after: no deterministic linter exists for this rule in this repo (no `.swiftlint.yml`, empty repo `.validators/`; `missing-docs` is the user-layer LLM validator) — before = 3 confirmed from iteration 1's review, after is `/review`'s to measure.
    - next: `/review`.
  timestamp: 2026-08-10T16:29:10.060746+00:00
- actor: claude-code
  id: 01kzp8a30tg7mamh2kv33cvxnk
  text: |-
    ### test — green
    - evidence: `swift test` — Test run with 780 tests in 73 suites passed; 24 tests in 9 suites passed; 24 tests in 5 suites passed. 0 failures. Only warning present is the pre-existing baseline (`mlx-swift_Cmlx.bundle` missing-creator-for-mutated-node line). Gated suites (FM_ROUTER_INTEGRATION_TESTS, MULTITOOL_INTEGRATION) correctly report skipped, not run. New suite "Mounted tool output reaches the model's next generation" (both tests) passed.
    - doc-only check: `git diff --numstat` on ToolOutputFeedbackTests.swift = 135 insertions, 0 deletions. Confirmed no deletions or modifications anywhere in the file — every changed line is a pure `+` addition of a doc comment.
    - Sources check: `git diff -- Sources` is empty.
    - DocC direction check: `replacingTranscript(_ transcript:)` doc key is `transcript` (not `_`) — correct. `respond(to prompt:...)` (both overloads) doc key is `prompt` (not `to`) — correct. Symbol links `` `makeFork(tools:)` ``, `` `RoutedSession/respond(to:)` ``, `` `RoutedSession/streamEvents(to:)` ``, `` `pumpStream(prompt:options:into:)` ``, `` `RoutedSessionActor/compact(prompt:budget:)` ``, `` `makeSession(instructions:tools:)` `` all use external argument labels matching their real declarations. No keys are backwards.
    - Checker: `python3 Scripts/check-doc-links.py` — exit 0, symbol links scanned 1283, declarations indexed 2356, total stale 0, total unresolved 0.
    - Comment-quality spot check: read the fork/container overload comments in full. Confirmed against source: `LanguageModelSessionBackend`'s default extension (`makeFork(tools:)`) ignores `tools` and forwards to `makeFork()` unchanged; `LoadedLLMContainer`'s default extension does the same for `makeSession(instructions:tools:)`/`makeSession(transcript:tools:)`. The fixture's own doc comments state it implements these overloads "rather than left to the protocol's tool-dropping default" because this fixture's model can really call tools — this is accurate, not restating the member's name, and documents a real near-miss (a stub-shaped default would silently drop tools from a fork/child session).
    - No lint before/after count produced: repo has no `.swiftlint.yml`, `.validators/` is empty, and missing-docs is model-driven, not a static linter — this cannot be measured, so none is reported.

    step: test
    outcome: green
    evidence: swift test — 780/73 + 24/9 + 24/5 suites, 0 failures, only pre-existing baseline warning; numstat 135/0 on the doc file; Sources diff empty; DocC Parameter keys and symbol-link labels verified correct in both directions; check-doc-links.py exit 0 (0 stale, 0 unresolved)
  timestamp: 2026-08-10T16:32:50.202353+00:00
- actor: claude-code
  id: 01kzp8ga0kan0enyyzsbxk1ed1
  text: |-
    ### commit — changed
    - evidence: 4a32675 docs(tests): document remaining ToolOutputFeedbackTests helpers (^cvtfem3); 3 files changed, 275 insertions(+) (Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift 135 ins/0 del, plus the task's own kanban card)
    - next: none — commit done, not pushed
  timestamp: 2026-08-10T16:36:13.971910+00:00
- actor: claude-code
  id: 01kzp8v4w5cqcm6g0bgmpc2ryx
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (4a32675) — 0 findings, 0 confirmed, 1 refuted, 9 validators attempted, 0 failed, 0 skipped. All 3 prior findings from the 2026-08-10 11:13 section verified closed in the file, not accepted on claim: `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift` now documents `makeFork(tools:)`, `transcriptEntries()`, and `usageTokenCounts()`. The `usageTokenCounts` doc claim "Never `nil`" matches the code — the body returns an unconditional tuple from the non-optional `liveSession.usage`.
    - scope: documentation only, 135 insertions and 0 deletions, one file plus the task card. No existing line changed, so the test behaviour and assertions stay byte-identical to iteration 1.
    - waivers: none applied. The engine raised no acronym-casing finding, so the project's `RAM`/`JSON`/`LLM`/`ULID` rule was not needed this pass.
    - next: task moved to done. No open findings.
  timestamp: 2026-08-10T16:42:09.157155+00:00
- actor: claude-code
  id: 01kzp8wzh0dt34fn98yqgfbvv8
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift`, 419 → 554 lines. **135 insertions, 0 deletions**, so no existing line was modified and the fault-injection-validated behaviour and assertions are byte-identical to iteration 1.
    - **The review cited 3 violations; the file had 15.** Beyond `makeFork`, `transcriptEntries`, `usageTokenCounts`, the sweep documented `MarkerEmittingTool.name`/`.description`/`.call(arguments:)`, five more backend methods, and all four `makeSession` overloads. The two `@Test` methods stay bare, which the rule permits.
    - Rule read before writing, and it mattered: `missing-docs` exempts test functions but has a yield clause — its exemptions give way to stricter language rules, so the "simple getter" carve-out does not shield `name`/`description`. The DocC distinction was applied in BOTH directions: `- Parameter` keys use internal names (`transcript` on `replacingTranscript(_ transcript:)`, `prompt` on `respond(to prompt:)`), symbol links keep external labels (``makeFork(tools:)``, ``RoutedSession/respond(to:)``).
    - test: green — swift test 780/73 + 24/9 + 24/5, 0 failures, no new warnings. `git diff -- Sources` empty. `numstat` 135/0 confirms documentation-only. `check-doc-links.py` exit 0 — 1283 links scanned, 0 stale, 0 unresolved. Comment quality spot-checked against `LanguageModelSessionBackend.swift` and `ModelLoader.swift`: both protocols' default extensions genuinely DO drop `tools`, so the fixture's note that its overrides exist "rather than left to the protocol's tool-dropping default" documents a real trap — the same class of fixture defect iteration 1 hit once with `LanguageModelCapabilities([])`.
    - **No lint before/after count is available and none was invented** — this repo has no `.swiftlint.yml`, `.validators/` is empty, and `missing-docs` is the review engine's model-driven validator rather than a static linter.
    - commit: 4a32675 — 3 files, +275, local only
    - review: clean — zero new findings; all 3 prior items verified closed rather than accepted. Engine: 9 validators, 0 failed, 1 refuted. Checked specifically for a comment asserting behaviour the code lacks: the one falsifiable claim, `usageTokenCounts`'s "Never `nil`", holds — the body reads the non-optional `liveSession.usage` and returns unconditionally.
    - next: task moved to done. The diagnostic result stands: the hypothesis is wrong at this level, H4's premise is false on the `RoutedSession` path, H5 is not the cause, H1 is unreachable in this harness, and the test remains as a regression guard on both surfaces.
  timestamp: 2026-08-10T16:43:09.216232+00:00
position_column: done
position_ordinal: fe80
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

## Review Findings (2026-08-10 11:13)

- [x] `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift:284` — Public method `makeFork` lacks documentation comment — implements LanguageModelSessionBackend protocol requirement. Add a documentation comment explaining this method's behavior.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift:296` — Public method `transcriptEntries` lacks documentation comment — implements LanguageModelSessionBackend protocol requirement. Add a documentation comment explaining this method's behavior.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift:300` — Public method `usageTokenCounts` lacks documentation comment — implements LanguageModelSessionBackend protocol requirement. Add a documentation comment explaining this method's behavior.

## Two concrete streaming defects, read off the code — fix these to make streaming work

Found after the scripted-model test came back green. Neither needs a live model to see; both need the live backend to *reproduce end to end*, which is why the harness missed them.

### D1 — `.toolStatus(.completed)` is keyed by the wrong id, so completion cannot be correlated to its call

`RoutedSessionActorRecording.swift:365-379`:

```swift
case .toolCalls:
    for call in entry.toolCalls ?? [] {
        onEvent(.toolCall(id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON))
        onEvent(.toolStatus(id: call.id, status: .running, summary: nil))
    }
case .toolOutput:
    onEvent(.toolStatus(id: entry.entryId, status: .completed, summary: partial.text))
```

`.toolCall` and the `.running` status carry `call.id`. The `.completed` status carries **`entry.entryId`** — a different identifier space. Any consumer that correlates a completion to its call by id (which is the only thing the id is for) never matches, so tool output is unattributable: a client sees N calls start and N unrelated completions.

This is not theoretical — a consumer in FoundationModelsMultitool built exactly that mapping (`callIndexByID` from `.toolCall`, then attach `summary` on `.toolStatus`) and it silently attached nothing.

**Test:** one scripted tool-using turn; assert every `.toolStatus(.completed)` id matches a previously emitted `.toolCall` id, and that the set of completed ids equals the set of called ids. Then the multi-call shape, where mis-keying is invisible with one call.

**Fix:** emit the completion under the originating `call.id`. `completedToolCallIds` and `dispatchedToolCallIds` are already threaded through this function, so the correlation is available.

### D2 — the snapshot delta corrupts text across a tool boundary

`LiveModelLoader.swift:395`:

```swift
private static func suffix(of current: String, after previous: String) -> String {
    guard current.hasPrefix(previous) else { return current }
    return String(current.dropFirst(previous.count))
}
```

Its doc calls the non-prefix branch "a defensive fallback for a non-monotonic snapshot, not expected in practice". With tools it is expected: the model produces a first pass, a tool runs, generation resumes on a new answer, and that snapshot does not extend the old text. The guard fails, the **whole** snapshot is returned as if it were a delta, and `streamGeneratingBody`'s `response += chunk` concatenates it. `previous` is also never reset — it is `var previous = ""` for the life of one `pumpStream`.

So a streamed tool-using turn can hand the caller pre-tool text followed by the entire post-tool answer, or repeated snapshots. A caller accumulating fragments gets duplicated prose.

**Test:** feed a snapshot sequence that goes non-monotonic across a tool call and assert the accumulated text equals the final answer exactly — char equality, not `contains`.

### D3 — the live backend cannot be tested, which is why D1 and D2 survived

`MLXFoundationModelsSessionBackend.init` takes a concrete `MLXLanguageModel`, so no scripted model can drive `LiveModelLoader.pumpStream` or the live `respond` path. Every hypothesis has now been eliminated *except* this region, and it is the one region with no test coverage.

**This is the highest-value change on the card.** Widen that initializer to accept the backend protocol (or inject a snapshot source), then D1 and D2 get real tests and the remaining 0/4 becomes diagnosable in one second instead of eleven minutes.

### Status of the consumer

FoundationModelsMultitool is 0/4 on both Router surfaces and 1/4–3/4 on a plain `LanguageModelSession(model:tools:)` over the same MLX model. It builds against Router by local path, so its build is currently broken by the Detach rename — that is expected and being handled on that side, not a Router problem.

## Correction to D3 — "no test can reach it" is wrong, and it is not an excuse

Human ruling: *"i reject the assertion that 'no test can reach it' — if that is true it cannot possibly work — meaning works and tests prove it works."*

That is correct and it retracts the framing above. Untestable is not a property of the code; it is a defect in the seam, and it is the defect to fix first. Three tests reach this region **today**:

1. **Router's own gated suite.** `FM_ROUTER_INTEGRATION_TESTS=1` builds the live backend against a real model. A tool-using turn there exercises `pumpStream` and the live `respond` path directly. If no gated Router test asserts that a streamed tool-using turn returns the correct final answer, that is the first test to write — and it is the one that would have caught D1 and D2.
2. **The consumer's gated suite.** FoundationModelsMultitool's `SearchThenCallTests` reaches this region every run and has been **failing** on it — 0/4 across five runs on both surfaces. It has been reporting the defect the whole time; what was missing was a Router-side test that localises it.
3. **A scripted-model test, once the seam is widened.** `MLXFoundationModelsSessionBackend.init` taking a concrete `MLXLanguageModel` is what forces every check into the slow path. Widening it to the backend protocol (or injecting the snapshot source) is a production signature change, and it is the right one: it converts an eleven-minute GPU run into a one-second assertion.

So the order is: **write the slow test that proves it works, then widen the seam so the fast test can prove it too.** Not "cannot be covered."

The standard: streaming works when a test says a streamed tool-using turn returns the same final answer as the same turn through `respond`, and every `.toolStatus(.completed)` correlates to its `.toolCall`. Until such a test exists and passes, streaming is not known to work — and right now the evidence from two independent gated suites is that it does not.

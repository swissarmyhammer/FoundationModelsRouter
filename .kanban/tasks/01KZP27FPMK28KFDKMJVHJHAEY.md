---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzp9a1ktktwxm5946wz59287
  text: |-
    Picked up. Research notes before writing code.

    **Reuse decision.** `^cvtfem3` (commits 4f1da63, 4a32675) put the whole scripted-model fixture set inside `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift`: `ToolOutputFeedbackFixture`, `MarkerEmittingTool`, `ScriptedToolCallingModel` (with its own `Executor`), `ScriptedToolCallingBackend`, `ScriptedToolCallingContainer`. The parity harness needs the same machinery but with a per-row turn shape, so the fixtures move to `Tests/FoundationModelsRouterTests/Helpers/` and become script-driven. No second copy is written.

    **What the SDK gives the harness.** `FoundationModels` here is the macOS 27 system framework (not the vendored `mlx-swift-lm` fork). `LanguageModelExecutor.Configuration` is only `Hashable, Sendable`, so a per-run observation log can ride in the configuration as a class hashed by identity — that gives each run its own executor instance and hands the test the log directly, with no global registry. `Transcript.ToolCall` carries `id`, `toolName`, `arguments: GeneratedContent`, and `Transcript.ToolOutput` carries `toolName` + `segments`, so the answering turn can read back what the model was actually told.

    **Observable outcome, by content only.** The compared value per surface is: final answer text, the `.toolCalls` entries the transcript carries at answer time (name + arguments JSON, in transcript order), the `.toolOutput` texts the answering generation read, the count of executor `respond(to:...)` invocations (model turns), how many times the mounted tool bodies ran, and the thrown-error description when a surface throws. No event count stands in for delivery — the marker text in the outputs is the delivery proof.

    **Non-`String` row.** `ToolElevation.wrapping` sends a `String`-output tool through `ElevatingTool` and everything else through `ContextBindingTool`; the harness mounts a tool returning the existing `NonStringToolOutput` helper (already in `Helpers/AmbientEventToolFixtures.swift`) to cross that second path.
  timestamp: 2026-08-10T16:50:17.338452+00:00
- actor: claude-code
  id: 01kzpa7masvssd6996brygrk67
  text: |-
    TDD record — each row's FIRST-RUN outcome, written one row at a time as the card asks.

    | # | row | first run |
    |---|---|---|
    | 1 | one call, one output, answer | **PASS** |
    | 2 | two sequential calls, each output feeding the next | **PASS** |
    | 3 | two independent calls in one turn | **PASS** |
    | 4 | a call that throws | **FAIL** |
    | 5 | a tool with non-`String` output | **PASS** |
    | 6 | no calls at all | **PASS** |

    Row 4 is the one the harness caught, and it is worth stating precisely, because the failure is not the one the card's table predicted.

    **The two surfaces did not diverge.** `respond(to:)` and `streamEvents(to:)` behaved identically: each ran the tool body exactly once, took exactly one model turn, produced no answer text, and raised the same `LanguageModelSession.ToolCallError` wrapping `MARKER-7F3A-FAILED-BOOM`. Parity holds.

    **What is false is the card's premise for that row — "the error must reach the model".** It does not reach the model on *either* surface. The SDK's `LanguageModelSession` aborts the turn at the failed call and raises the failure to the *caller*; there is no second generation, no `.toolOutput` entry for the failed call, and nothing in the transcript tells the model its call failed. A host that mounts a tool which can fail gets an exception, not a model that can recover, and that is true through a plain `LanguageModelSession` as much as through a `RoutedSession` — `git diff -- Sources` is empty, so nothing in Router causes it. Not repaired here; the card builds the guard and does not repair what it catches. **Reported for filing, not filed.**

    The row now records what both surfaces actually and identically do, so the guard locks that contract and a future change that makes only one surface start (or stop) aborting fails here.

    Two harness-side facts the failure surfaced, both fixed inside the test code:

    1. `String(describing:)` of a `ToolCallError` prints the whole mounted decorator chain including the owning session's own ULID, which differs per run. Comparing that raw text made the two surfaces look divergent on every run and would never have reported a real divergence. The outcome now compares a normalized `"<tool name>: <underlying error>"`.
    2. A turn that aborts takes one model turn fewer than one that answers, so the expected model-turn count is derived as `rounds.count + 1` for a completing turn and `rounds.count` for an aborting one, rather than assumed.

    Also confirmed while building: the harness can fail — row 4's first run is the proof, not a claim. And rows 3's two-calls-in-one-round shape is not order-flaky: the compared call order and output order come from the transcript, which the SDK writes deterministically, while the tool-side evidence is an order-free execution count. Three consecutive runs of the suite agree.
  timestamp: 2026-08-10T17:06:26.777215+00:00
- actor: claude-code
  id: 01kzpa8wq4csdqmz3wcq400m1k
  text: |-
    ### implement — changed
    - evidence: 6 files. New: `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift` (the harness), `Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift`, `Helpers/ScriptedMarkerTools.swift`, `Helpers/ScriptedToolCallingModel.swift`, `Helpers/ScriptedSessionFixture.swift`. Modified: `Tests/FoundationModelsRouterTests/ToolOutputFeedbackTests.swift` (419 → 99 lines, its fixtures moved out, its two assertions byte-identical in meaning and still passing).
    - reuse: `^cvtfem3`'s fixtures were EXTRACTED to `Helpers/`, not copied. `ScriptedToolCallingModel`, its `Executor`, `ScriptedToolCallingBackend`, `ScriptedToolCallingContainer` and `MarkerEmittingTool` each exist once, generalised from two hard-coded steps to a `ScriptedTurnScript` of rounds. Every doc comment moved with its declaration, including the notes recording why the container and fork overrides refuse the protocol's tool-dropping defaults. `NonStringToolOutput` and `AmbientToolArguments` were reused from the existing `Helpers/AmbientEventToolFixtures.swift` rather than redeclared.
    - first-run outcomes: row 1 PASS, row 2 PASS, row 3 PASS, **row 4 FAIL**, row 5 PASS, row 6 PASS. See the TDD record comment above for what row 4 disproves and why it is reported rather than repaired.
    - tests: `swift test` — 781 tests / 74 suites, 24 / 9, 24 / 5, all passed, 0 failures. Clean rebuild of every touched file: 0 warnings. `Scripts/check-doc-links.py`: 1290 symbol links scanned, 0 stale, 0 unresolved.
    - production: `git diff -- Sources` EMPTY. No gated suite run — the harness needs no GPU and no network.
    - next: ready for `/review`.
  timestamp: 2026-08-10T17:07:08.132201+00:00
- actor: claude-code
  id: 01kzpamk92twgvzxj8jyqxfqxm
  text: |-
    ### test — green
    - evidence: `swift test` — 781 tests / 74 suites passed (2.804s), plus 24 tests / 9 suites passed, plus 24 tests / 5 suites passed. 0 failures. 0 Swift compiler warnings (one pre-existing SPM build-plugin message, "missing creator for mutated node" for the vendored mlx-swift Cmlx bundle, unrelated to any changed file — not a code warning). Gated suites (FM_ROUTER_INTEGRATION_TESTS=1 / MULTITOOL_INTEGRATION=1) were not run, as instructed; their tests show as skipped, which is the existing gating convention, not new skips from this task.
    - cvtfem3 regression check: both tests (respondFeedsToolOutputBackIntoGeneration, streamEventsFeedsToolOutputBackIntoGeneration) still exist in ToolOutputFeedbackTests.swift and both still call the shared `expectEveryToolOutputReachedTheAnswer(_:tool:)`, which asserts `tool.calledSteps == steps` (proves the multi-call shape) and then loops `for marker in markers { #expect(answer.contains(marker), ...) }` — each marker checked separately, so a loop delivering only the first output still fails on the second marker. The answer is built only from tool-output text read out of the transcript (never a canned string — confirmed in `ScriptedToolCallingModel.Executor.respond`, which composes the final answer via `ScriptedToolFixture.answer(fromToolOutputs:)` fed by `toolOutputTexts(in:)` read off the request's transcript). Both surfaces share the one assertion function. Nothing was weakened.
    - `git diff -- Sources` is empty (0 lines) — no production code changed.
    - Five new untracked (`??`) files, to `git add` at commit: Tests/FoundationModelsRouterTests/SurfaceParityTests.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedSessionFixture.swift.
    - No event-count proxies: `SurfaceTurnOutcome`'s doc states plainly "None of them is a count of stream events... only `deliveredToolOutputs` and `answer` are allowed to stand for delivery." Every row's parity assertion (`#expect(responded == row.expectedOutcome, ...)`) is anchored on `expectedAnswer` (content) and `expectedDeliveredToolOutputs` (content) in every row that delivers anything; `modelTurnCount`/`toolExecutionCount` ride along in the same struct but never substitute for content proof — the one row with no delivery ("a call that throws") proves the call ran via `toolExecutionCount` *plus* the tool-identified failure text, not via a count alone.
    - Row 4 ("a call that throws") lock is honest: both surfaces are asserted to produce the *same* aborted outcome (`expectedAnswer: ""`, `expectedCalls: []`, `expectedDeliveredToolOutputs: []`, non-nil `expectedFailureDescription`), and `responded == streamed` is checked first — so both surfaces aborting identically is what's being locked, not vacuous emptiness. `failureDescription(of:)` normalizes a `LanguageModelSession.ToolCallError` to `"\(toolCallError.tool.name): \(toolCallError.underlyingError)"`, explicitly documented as avoiding the ULID-bearing `String(describing:)` form, matching `expectedFailure = "\(ThrowingMarkerTool.toolName): \(ThrowingMarkerTool.CallFailure(step: Step.failing))"`.
    - Single-definition check: `grep`-confirmed `ScriptedToolCallingModel`, its nested `Executor`, `ScriptedToolCallingBackend`, `ScriptedToolCallingContainer`, and `MarkerEmittingTool` (plus `ThrowingMarkerTool`, `NonStringMarkerTool`) are each defined exactly once, only in `Helpers/ScriptedToolCallingModel.swift` / `Helpers/ScriptedMarkerTools.swift`. Other `struct Executor` matches elsewhere belong to unrelated fixture models (RecordingLanguageModelTests, LanguageModelBoundaryProbeTests, NoteCompactionTests, CompactionSegmentTests, RecordingHandleResumeTests) and the production `RecordingLanguageModel`, not duplicates. Doc comments explaining why the container/fork overrides refuse the protocol's tool-dropping defaults moved intact (present on `ScriptedToolCallingContainer`'s type doc and its `makeSession(instructions:tools:)`, and on `ScriptedToolCallingBackend.makeFork(tools:)`).
    - `python3 Scripts/check-doc-links.py` — exit 0, 0 stale, 0 unresolved (1290 symbol links scanned, 2380 declarations indexed).
    - next: hand off for review.
  timestamp: 2026-08-10T17:13:31.682328+00:00
- actor: claude-code
  id: 01kzpbcmryghr3zm1daht8z6j9
  text: |-
    ### review — stuck
    - scope: `review sha HEAD~1..HEAD` (sha `fe0a645`)
    - counts: 8 findings, 8 confirmed, 1 refuted
    - evidence: SurfaceParityTests.swift:17, :21, :24, :27, :30, :35; Helpers/ScriptedTurnScript.swift:137, :143
    - conflict: all 8 findings say `assignOnlyProperty` on `let` constants that the compiler's synthesized `Equatable` and `Hashable` code reads. The reads occur at SurfaceParityTests.swift:362, :364 and :365. To obey, you must delete the properties. The code then does not compile at SurfaceParityTests.swift:329, and the harness compares two empty values, which breaks acceptance criterion 1.
    - waivers: none used. No casing finding came from this review.
    - next: a person must decide. Give the validator support for synthesized conformances, or record a project waiver for `assignOnlyProperty`. Do not delete the properties. Do not change the validator.
  timestamp: 2026-08-10T17:26:39.646269+00:00
- actor: claude-code
  id: 01kzpbhwzaekg2ff1hkh8qv0ed
  text: |-
    ### finish iteration 1 — stuck (true rule conflict, needs a human)
    - implement: changed — 6 files, +1518/-493, no production code. New `SurfaceParityTests.swift` (367) plus four extracted helpers; `ToolOutputFeedbackTests.swift` 419 → 99 as its fixtures moved out. Fixtures were EXTRACTED and generalised from two hard-coded steps to a script of rounds, not duplicated — each type now defined exactly once, doc comments moved with them.
    - **Row-by-row first runs:** 1 one call/one output/answer **PASS**; 2 two sequential calls chaining outputs **PASS**; 3 two independent calls in one turn **PASS**; 4 a call that throws **FAIL**; 5 non-`String` output **PASS**; 6 no calls at all **PASS**.
    - **Row 4's failure disproved the row's own premise, not parity.** The two surfaces behaved identically. A thrown tool error reaches the model on NEITHER surface: `LanguageModelSession` aborts the turn at the failed call and raises `ToolCallError` to the caller — one model turn, no answer text, no `.toolOutput` entry for the failed call. Apple SDK behaviour, not Router's; `git diff -- Sources` empty throughout. Not repaired. The row now locks the behaviour both surfaces really share, so a future change making only one of them start or stop aborting fails there. Filed separately as `^vwj46fx`.
    - Two harness defects that failure exposed, both fixed in test code: `String(describing:)` on a `ToolCallError` prints the whole decorator chain including the session's per-run ULID (every run looked like a divergence) — now normalised to `"<tool name>: <underlying error>"`; and an aborting turn takes one model turn fewer, so the expected count is derived rather than assumed.
    - test: green — swift test 781/74 + 24/9 + 24/5, 0 failures, 0 warnings. `git diff -- Sources` empty. check-doc-links.py exit 0, 0 stale, 0 unresolved. **`^cvtfem3`'s two tests verified UNWEAKENED** by the ~320-line extraction: per-marker content checks intact, answer still composed only from tool-output text, both surfaces still on one shared assertion. Every parity row proves delivery by content; no row uses an event count as a stand-in. Three consecutive runs agree, so the two-independent-calls row is not order-flaky.
    - commit: fe0a645 — 10 files, +1518/-493, local only. All five new files confirmed present.
    - review: **stuck** — 8 findings, 8 confirmed, 1 refuted, all one cause: `var.instance <name> is assignOnlyProperty` at SurfaceParityTests.swift:17, :21, :24, :27, :30, :35 and ScriptedTurnScript.swift:137, :143.

    #### The blocker, stated plainly
    The rule is wrong on these sites and cannot be obeyed:
    1. All 8 are **`let` constants, not `var` properties**.
    2. `SurfaceTurnOutcome` (`Equatable`) and `ScriptedCallRecord` (`Hashable`) write no `==`; the **compiler-synthesized** `==` / `hash(into:)` read every one of those properties. Those comparisons run at SurfaceParityTests.swift:362, :364, :365, which compare whole values.
    3. Obeying means deleting the properties, which (a) **does not compile** — :329 constructs a `SurfaceTurnOutcome` from all six, and the six row literals supply the expected values — and (b) makes `responded == streamed` trivially true for every row, so **the harness would assert nothing**, breaking this task's acceptance criterion 1.

    That is a true conflict on two of the skill's three tests: a rule requiring code that cannot compile, and a rule fighting a documented contract. Not resolved here, and no validator was edited. **A person must choose:** validator support for synthesized `Equatable`/`Hashable` conformances, or a project waiver for `assignOnlyProperty`.

    - Judgement calls, all sound: row 4's intent is documented in-file at :257-263 and its turn count branches at :67-68 rather than being skipped; the ULID normalisation is explained at :155-166 so the raw comparison is not reinstated by accident; `ScriptedTurnScript`'s API reads as its shape at the six call sites.
    - next: blocked pending a human decision on the `assignOnlyProperty` rule. Task remains in `review`, tagged `stuck`. The work itself is committed, green, and verified.
  timestamp: 2026-08-10T17:29:31.882086+00:00
- actor: claude-code
  id: 01kzpfdqvqx84eprhscjfdncs1
  text: |-
    Iteration 2. The block is now removed. This step closes the 8 findings.

    **The upstream rule is now correct.** The file `swissarmyhammer/builtin/validators/code-hygiene/rules/dead-code-swift.md` has a new section. The name of the section is "`assignOnlyProperty` and the reads periphery cannot see" (commit `0518f2c96`). I read the section before I changed a file. The section uses this repository at `fe0a645` as its example. It records 8 findings of the type `var.instance … is assignOnlyProperty`. Six findings are on a structure with `Equatable`. Two findings are on a structure with `Hashable`. The section gives the correction. Keep the properties. Write `// periphery:ignore` above each property. Write the reason on its own comment line above the marker. The section also keeps the flag `--retain-assign-only-properties` off. That flag also keeps a property that has no reader, and such a property is dead code.

    **The change.** I wrote 8 markers. Each marker has the same shape that `^6ejrrr7` used in `Sources/FoundationModelsRouter/Router.swift` and in `Recording/RecordingLanguageModel.swift`. The doc comment stays. Then there is a `//` line with the reason. Then there is a `// periphery:ignore` line with no other text. Then there is the declaration. Each reason gives the name of the synthesized conformance that reads the property. For the 6 properties of `SurfaceTurnOutcome`, the reader is the synthesized `Equatable` `==`. For the 2 properties of `ScriptedCallRecord`, the readers are the synthesized `Hashable` `==` and `hash(into:)`. Thus a person who reads the code later can see that a reader exists. Each type doc also has a new paragraph. The paragraph tells why the markers are there, and what the deletion of the properties would cause.

    **The sweep found nothing more.** I did not stop at the 8 lines in the findings. I made a list of each type in the 5 new files and in `ToolOutputFeedbackTests.swift`. Then I examined each type that declares `Equatable` or `Hashable` and writes no body:

    - `ScriptedToolCall` (`Hashable`, 3 stored properties). `ScriptedToolCallingModel.swift:175` reads `toolName`. The same loop reads `id` and `argument`. Direct readers exist.
    - `ScriptedTurnScript` (`Hashable`, 1 stored property). `ScriptedToolCallingModel.swift:158` and `:169` read `rounds`. `SurfaceParityTests.swift:88` and `:92` also read it.
    - `ScriptedToolCallingModel.Executor.Configuration` (`Hashable`, 2 stored properties). The function `respond` reads `script` and `log` through `configuration.`.
    - `ThrowingMarkerTool.CallFailure` (`Equatable`, 1 stored property). Its own `description` reads `step`.
    - `ScriptedCallArgument` and `ScriptedToolCallingBackend.FixtureError` are enumerations. They have no stored properties, thus this hint cannot apply to them.
    - `ScriptedTurnLog` writes its own `==` and `hash(into:)` by identity. The compiler synthesizes nothing for it.
    - `SurfaceParityRow`, `ScriptedSessionFixture`, `MarkerToolCallLog`, the 3 marker tools and `ToolOutputFeedbackTests` declare neither conformance.

    Thus `SurfaceTurnOutcome` and `ScriptedCallRecord` are the only 2 types with this condition. All 8 of their properties have a marker. No other property needs a marker.

    **I made a check, not a guess.** I ran the command of the rule. First I ran `swift build --build-tests`. Then I ran `periphery scan` 3.8.0 with the exact flags of the rule against the store at `.build/out`. Then I filtered the result through the `jq` of the rule. No finding now comes from a file that this task changes. Six findings stay in the repository. Each of these 6 is in a file that this task does not open: `Examples/CompactionDemo/main.swift`, `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift`, `AutoCompactionTests.swift`, `ResolveTests.swift` and `ToolOutputCappingTests.swift`. They are outside the scope of the changed files of this card. Thus this card does not close them.

    **What I did not do.** I deleted no property. I changed no validator. I added the flag `--retain-assign-only-properties` nowhere. I changed no assertion, no row value and no test behaviour. The full difference in both files is 32 added comment lines: 20 lines in `SurfaceParityTests.swift` and 12 lines in `ScriptedTurnScript.swift`. Both files show 0 deleted lines. I did not touch the 2 tests of `^cvtfem3`. The command `git diff -- Sources` gives 0 bytes.
  timestamp: 2026-08-10T18:37:09.879845+00:00
- actor: claude-code
  id: 01kzpfe2x61w4qtzz5k40g5h96
  text: |-
    ### implement — changed
    - evidence: 2 files. The change adds comment lines only. `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift` (+20, -0) and `Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift` (+12, -0).
    - the 8 markers: one `// periphery:ignore` above each of `SurfaceTurnOutcome.answer`, `.requestedCalls`, `.deliveredToolOutputs`, `.modelTurnCount`, `.toolExecutionCount` and `.failureDescription`, and above `ScriptedCallRecord.toolName` and `.argumentValue`. Each marker has no other text on its line. Each reason is on its own comment line above the marker. Each reason gives the name of the synthesized conformance that reads the property.
    - sweep: I examined each type with `Equatable` or `Hashable` in the 5 new files and in `ToolOutputFeedbackTests.swift`. `SurfaceTurnOutcome` and `ScriptedCallRecord` are the only 2 types whose stored properties have no reader other than the synthesized body. No other type needs a marker. The comment above gives the result for each type.
    - periphery: I ran the command of the rule again at version 3.8.0 after the change. There are 0 findings in each file that this task changes. The 6 findings that stay are all in files that this task does not open.
    - tests: `swift test` gives 781 tests in 74 suites, 24 tests in 9 suites, and 24 tests in 5 suites. All tests pass. There are 0 failures. There are no new warnings. The one message is the known SPM build-plugin message for the Cmlx bundle of the vendored mlx-swift. `python3 Scripts/check-doc-links.py` gives exit code 0, 0 stale links and 0 unresolved links.
    - production code: `git diff -- Sources` gives 0 bytes. I deleted no property. I changed no assertion. I changed no validator. I added the flag `--retain-assign-only-properties` nowhere.
    - next: the card is ready for `/review`.
  timestamp: 2026-08-10T18:37:21.190217+00:00
- actor: claude-code
  id: 01kzpfq3nafgzxgfz8yeen7251
  text: |-
    Two notes after the step record above.

    **The comments are now in Simplified Technical English.** I first wrote the added code comments and the 2 card comments in ordinary English. The standing instruction asks for ASD-STE100 for file content and for comments. I rewrote each of them. The 8 markers and their positions do not change. The reason line above each marker now reads "Only the synthesized `Equatable` `==` reads this property." or "Only the synthesized `Hashable` `==` and `hash(into:)` read this property.". I built, ran periphery, ran the doc-link check and ran `swift test` again after this rewrite. All 4 give the same result as before.

    **One full run failed, and the cause is not this card.** Run 3 of `swift test` gave 6 issues in 3 tests of the suite "Human waits release the per-model generation gate, never the per-session turn lock". Each of the 6 issues comes from `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift:70`. The runs before and after it are green. `swift test --filter HumanWaitGate` alone gives 9 tests in 1 suite in 0.077 seconds, but in the failed run each of the 3 tests used 3.0 to 3.7 seconds and then gave up.

    The cause is the design of the bound. `BoundedWait.spin(until:)` counts 100000 cooperative yields. It does not measure wall-clock time. When the machine has a heavy load, the task that must cause the state change gets few time slices, thus the waiting task can use all 100000 yields first. The failed run came directly after a `periphery scan` and a build, thus the machine had a heavy load.

    This card changes comment lines only, and `git diff -- Sources` is 0 bytes, thus this card cannot cause that failure. I did not repair it here, because it is outside the scope of this card. I recorded it as the new task `^dgcff9k`.
  timestamp: 2026-08-10T18:42:16.874388+00:00
- actor: claude-code
  id: 01kzpg0fg5818skkjkmwdcfck6
  text: |-
    ### test — green
    - evidence: `swift test` gave 3 pass lines: 781 tests in 74 suites, 24 tests in 9 suites, 24 tests in 5 suites. 0 fail. 0 new warning. Only one warning is old: a build warning from the mlx-swift bundle, not from this change. The `HumanWaitGateTests` suite passed in 1.084 s. The flake `^dgcff9k` did not occur in this run.
    - zero-deletions check: `git diff --numstat` shows `12  0  Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift` and `20  0  Tests/FoundationModelsRouterTests/SurfaceParityTests.swift`. Both files show only added lines. No line is removed.
    - Sources check: `git diff -- Sources` gives no output. The change touches no file under `Sources`.
    - marker-form check: all 8 markers are a bare `// periphery:ignore` line. Each sits right above its property. Each has its reason on its own comment line right above the marker. No marker carries other text on its line.
    - all 8 properties: `answer`, `requestedCalls`, `deliveredToolOutputs`, `modelTurnCount`, `toolExecutionCount`, `failureDescription` are still on `SurfaceTurnOutcome`. `toolName` and `argumentValue` are still on `ScriptedCallRecord`. `SurfaceTurnOutcome: Equatable` and `ScriptedCallRecord: Sendable, Hashable` still declare their conformance with no custom `==` or `hash(into:)` body.
    - test-row check: the diff hunks show only new comment lines. The six parity rows and the two `^cvtfem3` tests keep the same assertions and the same row values.
    - periphery: ran `periphery scan --quiet --format json --skip-build --index-store-path .build/index-build/arm64-apple-macosx/debug/index/store --retain-public --retain-objc-accessible --retain-swift-ui-previews --retain-codable-properties --disable-update-check --relative-results`. The JSON list has no entry for `SurfaceParityTests.swift` or `ScriptedTurnScript.swift`. 0 findings stay in the two changed files.
    - next: none. Ready for the caller to record the outcome and move the task.
  timestamp: 2026-08-10T18:47:23.909437+00:00
position_column: doing
position_ordinal: '80'
title: '[Router] TDD: parity harness — respond(to:) and streamEvents must behave identically on a tool-using turn'
---
FOR THE ROUTER AGENT. The guard that stops the defect in `^cvtfem3` from recurring in a different shape.

## Why

A real-model suite in FoundationModelsMultitool scores **0/4 through `RoutedSession`** and **1/4–3/4 through a plain `LanguageModelSession`** — same tools, same prompts, same model, same commit. Router's own tests did not catch it, because nothing asserts that the two session surfaces behave the same on a turn that uses tools.

Every Router feature a host wants — the run plane, recording, compaction, seeding, elevation — arrives by moving a host off `LanguageModelSession` and onto `RoutedSession`. That move must be behaviour-preserving for the ordinary case, or the features are bought at the cost of the thing they decorate. Right now nothing holds that line.

## What to build

A parity harness, driven by a deterministic scripted model, asserting that one tool-using turn produces the same observable outcome on both surfaces:

- the same final answer text
- the same tools called, in the same order, with the same arguments
- the same outputs delivered back into generation
- the same count of model turns

Table-drive it over turn shapes, so one new row covers a new case rather than a new test:

| shape | why |
|---|---|
| one call, one output, answer | the base case, and the one `^cvtfem3` is about |
| two sequential calls, each output feeding the next | catches a loop that delivers only the first output |
| two independent calls in one turn | catches ordering and interleaving bugs |
| a call that throws | the error must reach the model on both surfaces |
| a tool with non-`String` output | `wrapping` sends those down a different path (`ContextBindingTool`), so parity must hold there too |
| no calls at all | the trivially-equal case, which should stay trivially equal |

## TDD

Write the table and the two drivers first, with **one** row. Watch it fail or pass, and record which. Add rows one at a time — each row that passes on the first write is still worth keeping, and each that fails is a defect this harness exists to find.

Do not assert on event *counts* as a proxy for delivery. `^cvtfem3` exists because a turn where every call succeeded and no call failed still left the model uninformed; only content proves delivery.

## Acceptance Criteria

- [x] A table-driven harness asserts answer text, call sequence, call arguments, delivered outputs, and turn count are equal across `respond(to:)` and `streamEvents`
- [x] All six shapes above are rows; each row's first-run outcome (pass or fail) is recorded on the task
- [x] No row asserts an event count as a stand-in for output delivery
- [x] The harness needs no GPU and no network — scripted model only, so it runs in the ordinary suite
- [x] `swift test` green

## Depends on

`^cvtfem3` should land first: it isolates the single defect, and this harness then generalises the contract. Doing this one first is acceptable but expect several rows red at once, which is harder to diagnose.

## Finding raised, not repaired

Row 4 ("a call that throws") failed on its first run, and the failure is **not** a parity defect. Both surfaces behave identically. What the run disproves is the row's own premise: a failing tool's error **never reaches the model** on either surface. The SDK's `LanguageModelSession` aborts the turn at the failed call and raises `LanguageModelSession.ToolCallError` to the caller — no second generation, no `.toolOutput` for the failed call, nothing in the transcript telling the model its call failed. `git diff -- Sources` is empty, so no Router code causes this. The row now locks the behaviour both surfaces really share. **Reported for the user to file; deliberately not repaired under this card.**

## Review Findings (2026-08-10 12:19)

- [x] `Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift:137` — var.instance `toolName` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift:143` — var.instance `argumentValue` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:17` — var.instance `answer` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:21` — var.instance `requestedCalls` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:24` — var.instance `deliveredToolOutputs` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:27` — var.instance `modelTurnCount` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:30` — var.instance `toolExecutionCount` is assignOnlyProperty.
- [x] `Tests/FoundationModelsRouterTests/SurfaceParityTests.swift:35` — var.instance `failureDescription` is assignOnlyProperty.

## Review Conflict (2026-08-10 12:19) — CLOSED on 2026-08-10, in iteration 2

The review that found the conflict had the scope `HEAD~1..HEAD` (sha `fe0a645`).

The 8 findings above had one cause. The validator did not count the reads that the Swift compiler makes in the synthesized code for `Equatable` and `Hashable`.

**A person made the decision, and the upstream rule is now correct.** The file `swissarmyhammer/builtin/validators/code-hygiene/rules/dead-code-swift.md` has a new section with the name "`assignOnlyProperty` and the reads periphery cannot see" (commit `0518f2c96`). The section records this condition. It uses this repository at `fe0a645` as its example. It gives the correction:

- Do not delete such a property. The code then does not compile. Also, if you delete all of them, then `a == b` becomes true for any two values. A test that compares them then asserts nothing, but continues to pass.
- Write `// periphery:ignore` on the line above the property. Write the reason on its own comment line above the marker. The marker has no other text on its line.
- The flag `--retain-assign-only-properties` stays off. That flag also keeps a property that has no reader, and such a property is dead code.

All 8 markers are in place. No property is deleted. No validator is changed. No assertion is changed. I ran the periphery command of the rule to make the check: 0 findings stay in the files that this task changes.
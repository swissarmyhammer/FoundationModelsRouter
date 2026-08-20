---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ad11qhfcv8b35wp9vekafy
  text: |-
    Picked up. Research done, before any edit.

    ## The cached models on this box

    `~/.cache/huggingface/hub` holds 47 repositories. The small real instruct models present, by size on disk:

    | repository | size |
    |---|---|
    | `mlx-community/SmolLM-135M-Instruct-4bit` | 75 MB |
    | `mlx-community/LFM2-1.2B-4bit` | 633 MB |
    | `mlx-community/Llama-3.2-1B-Instruct-4bit` | 680 MB |
    | `mlx-community/gemma-3-1b-it-qat-4bit` | ~700 MB |
    | `mlx-community/Qwen3-1.7B-4bit` | 937 MB |
    | `mlx-community/granite-3.3-2b-instruct-4bit` | 1.3 GB |
    | `mlx-community/Qwen2.5-3B-Instruct-4bit` | 1.6 GB |

    Nothing needs downloading. `Llama-3.2-1B-Instruct-4bit` is the pick: a real instruct model, complete snapshot on disk, and it writes NO `<think>` block — which is the whole reason `Muse-Glimmer-30B-4bit` needs a 4096-token reasoning headroom. `Qwen3-1.7B-4bit` is rejected because it reasons.

    `Muse-Glimmer-30B-4bit` is what `RealModels` and `CompactionEvalRealModel` both name, and it is 18 GB. It is not used here.

    ## Where the gate goes

    The repository has exactly two environment gates, and both use one shape: a file-private `let` naming the variable, a file-private computed `var` doing a `!= nil` lookup, and a SUITE-level `.enabled(if:)` trait. No `@Test` carries `.enabled(if:)`.

    - `FM_ROUTER_INTEGRATION_TESTS` — read in 12 files, each re-declaring its own file-private constant because Swift `private` at top level is file-scoped.
    - `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` — read beside it in `CompactionEvaluationTests.swift`, composed with `&&` and `&& !` to make the two eval tiers exclusive.

    So the new gate is a third variable read the same way, in its own file, with its own suite trait. Nothing else changes.

    ## What the fold arithmetic actually measures

    `Compactor.estimatedTokenCount(of:)` sums the UTF-8 CONTENT bytes of each entry and divides by `charsPerTokenEstimate = 4.0`, rounding up. `contentByteCount` keeps entry ids, segment ids, `"type"` discriminators and JSON punctuation OUT of the sum.

    The did-not-shrink guard is `if tokensAfter < tokensBefore` in `Compactor.compact`. When it does not hold, the function falls through to `shortfallResult` — `stagesApplied: []`, `summary: nil`, `tokensAfter == tokensBefore` — and returns the ORIGINAL transcript. That is the exit `^fm5ddk9` hit on 7 of 7 seeds.

    `Summarization` output ceiling is `summaryTokenAllowance(condensing:) + reasoningTokenHeadroom`, where the allowance is `min(maximumSummaryTokens, max(128, ceil(spanTokens * 0.25)))` and `maximumSummaryTokens` is what a full `maxChunkTokens = 2000` earns, so 500. `reasoningTokenHeadroom` defaults to 4096 and is a public initializer knob — a non-reasoning model needs almost none of it.

    `^fm5ddk9` measured the real 30B model writing summaries of 450 to 840 estimated tokens against spans of 345 to 444 estimated tokens — 1.30x to 2.07x. The fix for a smoke test is a span far larger than any summary the model can write under its own character directive, not a change to the directive.

    ## The plan

    - Fixture: one seed, one chunk. Span sized so a single summarizer call covers it (under `maxChunkTokens`) and so the summary cannot fail to shrink it.
    - One generation: `Compactor.compact` only. No resumed session and no answering turn.
    - `reasoningTokenHeadroom` cut down for a model that writes no reasoning, which bounds the worst-case generation.
    - The suite reuses `MetalLibraryTestBootstrap` through the target's existing `.exclusiveRealModel` trait rather than reading the bootstrap directly.
  timestamp: 2026-08-18T12:20:05.489660+00:00
- actor: claude-code
  id: 01m0adtq29hf06z6yqdnpmzpsm
  text: |-
    Implementation landed, measured, and green. What follows is the record a later reader needs.

    ## The red step, and what it proved

    The test was driven RED before it was driven green, on purpose, because a smoke test that passes on its first run has proved nothing about its own assertions.

    The red was made by reversing the fixture order so the folded span became the two SHORT prompts instead of the two long ones — one token of change, and the same condition `^fm5ddk9` reported. The run printed:

    ```
    summarizerCalls=1 ceilings=[256] spanTokens=33 summaryTokens=0 tokensBefore=670 tokensAfter=670 stages=[]
    ✘ Expectation failed: result.summary
    ```

    That is `Compactor.compact`'s shortfall exit, word for word: the summarizer RAN, it answered, and the fold was thrown away because it did not shrink. `tokensAfter == tokensBefore`, `stages=[]`, `summary` nil. The assertions are load-bearing.

    The fixture order was then restored, and the same run went green.

    ## The green run

    ```
    summarizerCalls=1 ceilings=[281] spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374 stages=["ToolOutputElision", "TurnTruncation", "Summarization"]
    wallClockSeconds=4.1 modelLoadSeconds=2.0
    ```

    All five facts the card asks for: one summarizer call, a summary of 304 estimated tokens against the 600-token span it replaced, `stagesApplied` ending in `Summarization`, and 670 tokens folded down to 374.

    ## The measurement

    Five runs of the test, and every one reported byte-identical fold numbers — which is `samplingMode: .greedy` doing its job, so a red run here is attributable to the change under test rather than to a sampled reply.

    | what was measured | figure |
    |---|---|
    | the test's own wall clock | 4.0 s to 4.3 s |
    | of which the model load | 1.9 s to 2.0 s |
    | `swift test --filter CompactionSmokeIntegrationTests` end to end | 10.2 s to 16.3 s |
    | `swift test` with NO filter, smoke gate set | 18.0 s |

    The 90-second budget is met with a factor of about 20 to spare on the test itself.

    The last row is the acceptance criterion about the gate, measured rather than argued: with `FM_ROUTER_COMPACTION_SMOKE=1` and no filter, the WHOLE package ran in 18.0 seconds — 978 unit tests, 28 in the integration target, 58 evals — this suite's real model included, and not one `FM_ROUTER_INTEGRATION_TESTS` suite ran.

    ## Why the fold is certain rather than lucky

    `^fm5ddk9`'s defect was a real model writing a summary LARGER than the span it replaced, 1.30x to 2.07x, on 7 of 7 seeds. That cannot happen here, and the reason is arithmetic rather than model behaviour.

    `Summarization`'s output ceiling is a HARD STOP on the whole generation, and it is `summaryAllowance + reasoningTokenHeadroom`. The suite sets the headroom to 128 rather than the default 4096, because the smoke model writes no `<think>` block. So the largest summary the fold can possibly be handed is bounded by the ceiling, whatever the model does.

    Measured: the 600-token span bought a ceiling of 281, and the model wrote to it — 304 estimated tokens, a little over half the span. The margin is the ceiling's, not the model's restraint. The fixture is sized so that bound sits under the span, and the budget is DERIVED from the fixture rather than written beside it, so a fixture that changes size carries its own budget with it.

    ## Decisions worth knowing

    - **The model is named locally, not added to `RealModels`.** `RealModels` is the target's roster of the three profile SLOTS, and a smoke model is not a slot. `CompactionEvalRealModel` in the evals target is the prevailing pattern for "a suite that needs its own model at its own context", and this follows it. `RealModels` is untouched.
    - **`Qwen3-1.7B-4bit` was rejected** although it is a comparable size: it reasons, which is the exact property that made the 4096-token headroom necessary in the first place.
    - **Nothing was downloaded.** Every candidate was already in the Hugging Face cache.
    - **The length directive in `Summarization` was not changed**, and no existing assertion was weakened. The only production knob touched is `reasoningTokenHeadroom`, through its own public initializer parameter, at this suite's call site.

    ## Something a reviewer should not attribute to this card

    The working tree carries uncommitted changes to five files under `Tests/FoundationModelsRouterEvals/` and to two other kanban cards. Those are ANOTHER session working this repository at the same time. This card touched exactly one source file.
  timestamp: 2026-08-18T12:34:06.537613+00:00
- actor: claude-code
  id: 01m0advwgnpha9saynr848qs6x
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift (new). `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` zero diagnostics; `swift test` 978 + 28 + 58 pass with the one pre-existing `BoundedWait` known issue. Gated run `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests`: passed in 4.1 s wall clock, 1.9 s of it the model load — `summarizerCalls=1 spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374 stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`. Red step first: the same test with the fixture order reversed reported `spanTokens=33 tokensBefore=670 tokensAfter=670 stages=[]` and failed on the nil summary, which is `^fm5ddk9`'s shortfall exit.
    - next: ready for /review. 12 of 12 acceptance criteria checked. Nothing open.
  timestamp: 2026-08-18T12:34:44.885634+00:00
- actor: claude-code
  id: 01m0afp56ar0fh1bgsc96ynvfj
  text: |
    ### review — findings
    - evidence: 1 finding (1 confirmed, 2 refuted, 7 attempted) — `review sha 160ca9e~1..160ca9e` — Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift:403
    - directed checks, both verified in the file: `reasoningTokenHeadroom = 128` is tied to the chosen model in writing — the model constant records that `Llama-3.2-1B-Instruct-4bit` writes no `<think>` block and that `Qwen3-1.7B-4bit` was rejected because it reasons, and the property doc states the consequence openly, that the ceiling makes the shrink arithmetic hold by construction rather than by the model's restraint. The scope claim is written down too: the suite doc says it proves the path works and does NOT measure fact retention, and names `FoundationModelsRouterEvals` as the tier that does.
    - measured independently: `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` passed in 12.4 s of command time, of which the test body was 4.0 s and the model load 1.9 s. Identical fold numbers to the card — summarizerCalls=1 ceilings=[281] spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374.
    - next: extract `makeContainer()` into shared test support, then re-review.
  timestamp: 2026-08-18T13:06:34.314594+00:00
- actor: claude-code
  id: 01m0ag51brz141a9kgm14qhvb0
  text: |-
    Picked up for the open `reuse/reuse` finding. Research done, before any edit.

    ## Every copy, not only the four the finding named

    The finding named four sites and said "and others". There are NINE, all in `FoundationModelsRouterIntegrationTests`, all with the same three-step body:

    | file | line | `ref` | `context` | `samplingMode` |
    |---|---|---|---|---|
    | `SessionTreeRestorationIntegrationTests.swift` | 108 | `sessionTreeRestorationTinyModel` | `RealModels.context` | provider default |
    | `CompactionSpikeIntegrationTests.swift` | 61 | `compactionSpikeTinyModel` | `RealModels.context` | provider default |
    | `LanguageModelSessionBackendTests.swift` | 58 | `sessionBackendTinyModel` | `RealModels.context` | provider default |
    | `TranscriptReconstructionIntegrationTests.swift` | 54 | `transcriptReconstructionTinyModel` | `RealModels.context` | provider default |
    | `RealToolTurnComparisonTests.swift` | 144 | `realToolTurnModel` | `RealModels.context` | provider default |
    | `RecordingHandleIntegrationTests.swift` | 114 | `recordingHandleTinyModel` | `RealModels.context` | provider default |
    | `PropagationProbeIntegrationTests.swift` | 226 | `propagationProbeModel` | `RealModels.context` | provider default |
    | `CompactionRoundTripIntegrationTests.swift` | 155 | `compactionRoundTripTinyModel` | `Self.context` | `.greedy` |
    | `CompactionSmokeIntegrationTests.swift` | 403 | `compactionSmokeModel` | `compactionSmokeContext` | `.greedy` |

    ## What actually differs, and what does not

    The similarity scores below 1.00 are explained by exactly three things: the model ref, the context length, and the sampling mode. Those three become the parameters. Everything else is byte-identical in all nine: the two Hub macros, `slot: .standard`, `reporting: { _ in }`, and `try #require(loaded as? MLXFoundationModelsContainer)`.

    Two differences are real and MUST survive the merge, so neither is flattened:

    - `.greedy` on the two compaction suites. Both suites' doc comments record why (task `f80n046`): the provider default samples at temperature 0.6 from MLX's process-global PRNG, which seeds from the clock, so their fold arithmetic differed on every run of identical code. Merging that away would make both suites non-repeatable.
    - `compactionSmokeContext` and `CompactionRoundTrip.context`, each sized for its own fixture, against `RealModels.context = 8192` for the other seven.

    Eight of the nine refs are aliases of `RealModels.standard`; the smoke suite's is `Llama-3.2-1B-Instruct-4bit`. The per-file constants stay where they are — each suite keeps stating its own model.

    ## Why the shared home is this target's `Support/`, not `FoundationModelsRouterTestSupport`

    `FoundationModelsRouterTestSupport` was the first candidate, and it does not work. Two independent blockers, both verified in the source:

    1. **The return type cannot be public.** `MLXFoundationModelsContainer` is declared `struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable` in `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` — INTERNAL, with no `public`. Every one of the nine files reaches it through `@testable import FoundationModelsRouter`. `FoundationModelsRouterTestSupport` is a plain `.target`, not a `.testTarget`, and a `public` function there cannot name an internal type in its signature at all.
    2. **The macros are not linked there.** `#hubDownloader()` and `#huggingFaceTokenizerLoader()` expand to code referencing `HuggingFace.HubClient` and `Tokenizers.AutoTokenizer`. `Package.swift` gives `FoundationModelsRouterTestSupport` exactly one dependency, `.target(name: packageName)`. It links neither `MLXHuggingFace` nor the two Hub products. Adding them would also push that linkage into the ungated unit-test target, against the manifest's own written intent that "Only the integration test target links these."

    So the helper goes in `Tests/FoundationModelsRouterIntegrationTests/Support/`, beside `RealModels` and `GatedSuiteSerialGate` — the directory this target already uses for shared suite support, and the one place `@testable import` and the Hub macros both reach. That satisfies the finding's own second option word for word: "or refactor to call through an existing shared helper", and its stated goal, "so all integration tests call the same implementation". All nine callers are in this one target, so all nine reach it.

    ## A dead-import consequence

    In all nine files, `HuggingFace`, `MLXHuggingFace`, `MLXLMCommon` and `Tokenizers` are imported for the macro expansion and for nothing else — no symbol from any of the four is named anywhere else in those files. Once the macros move to the shared helper, those four imports are dead in each of the nine and go with them.

    ## Out of scope, and filed instead

    `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift:146` and `CompactionContinuityEvalRealSubjectRunner.swift:57` carry the same loader-plus-`loadLLM` sequence in the OTHER test target. They are not merged here: they cache the container in a stored property, they map the bad cast to their own domain error rather than `#require`, one emits progress lines around the load, and `git status` shows another session holds uncommitted changes under `Tests/FoundationModelsRouterEvals/`. A separate card carries them.
  timestamp: 2026-08-18T13:14:41.912263+00:00
- actor: claude-code
  id: 01m0aghx7a67gzpe1wvc3fzxxk
  text: |-
    Extraction landed in the four files handled by hand. Recording the two decisions a later reader will ask about, because neither is mechanical.

    ## The shared helper

    `Tests/FoundationModelsRouterIntegrationTests/Support/RealModelContainer.swift`, one `enum` namespace beside `RealModels` and `GatedSuiteSerialGate`:

    ```
    RealModelContainer.load(
        ref: ModelRef,
        context: Int = RealModels.context,
        samplingMode: GenerationOptions.SamplingMode? = nil
    ) async throws -> MLXFoundationModelsContainer
    ```

    Three parameters, one for each thing that differed across the nine copies. `slot: .standard` and `reporting: { _ in }` are deliberately NOT parameters: all nine passed exactly those, and the doc comment says so, so a suite that needs a different slot or real progress reporting is asking for something this function does not describe. `IntegrationTests.swift` is the file that DOES need both, and it builds its own instrumented `PhaseRecordingLoader`/`DownloadObservingLoader` stack; it was never part of this clone family and is untouched.

    `context` defaults to `RealModels.context` because that is the budget seven of the nine ask for and the constant already documents itself as "the context budget every gated suite in this target requests". `samplingMode` defaults to `nil`, mirroring `LiveModelLoader.init`'s own default.

    The helper keeps `try #require(loaded as? MLXFoundationModelsContainer)` exactly as the nine copies had it. Nothing was turned into a `guard`/`throw`, so no assertion changed.

    ## Where the greedy rationale went, and why it is not lost

    Two suites pinned `.greedy`, and each carried a paragraph on `makeContainer()` explaining what its own run loses without it. Deleting the function would have deleted the reason, so each reason moved to a named constant in its own file — the shape both files already use for every other measured fixture value:

    - `CompactionSmokeIntegrationTests.compactionSmokeSamplingMode`, beside `compactionSmokeModel` and `compactionSmokeContext`.
    - `CompactionRoundTripIntegrationTests.samplingMode`, beside `context`, `replyMaxTokens` and `foldBudget`.

    This also repaired a doc link the extraction would otherwise have broken. The smoke suite's measurement section said its three runs' identical fold numbers were "the greedy decoding of ``makeContainer()`` doing its job" — a symbol link to a function that no longer exists. It now points at ``compactionSmokeSamplingMode``, which is the thing that actually carries the property.

    The generic half of the reason — the provider default drawing from MLX's clock-seeded process-global PRNG, task `f80n046`, and what argmax buys — is stated once on the shared helper's `samplingMode` parameter. Each constant keeps only what is specific to its own suite.

    ## The other fact that was on a doc comment

    `SessionTreeRestorationIntegrationTests` and `CompactionRoundTripIntegrationTests` both said `makeContainer()` was "called once per simulated 'process' — the second call models a fresh process reloading the same model from the Hub cache". That fact is already written at the call sites in both files ("a fresh process continuing the same recording root, with a freshly (re-)loaded model container", and "Restore from disk — a fresh Router/profile over the same recording root, simulating a new process"), so it survives where it is actually load-bearing.

    ## Rules read before writing, and what they changed

    `get validator reuse`, then the whole matched rule set for `.swift`. Three of them decided something here:

    - `swift/naming` warns against abbreviations, which put the `ref:` label in question. It stays `ref:` because it is the router's own term, not a shortening invented here: the type is `ModelRef` and the function this wraps is `LiveModelLoader.loadLLM(ref:slot:context:reporting:)`. The same rule's "do not repeat the enclosing type's name in a static member" is why the method is `load` rather than `loadContainer`, and its "factory methods begin with `make`" carve-out does not apply because this call performs real I/O.
    - `swift/access-control`: the helper is `internal`, not `public`. It cannot be `public` — `MLXFoundationModelsContainer` is internal — and it must be more than `private`, since nine files call it.
    - `magic-numbers-swift` does report inside a Swift Testing suite (its `test_parent_classes` names `XCTestCase` and `QuickSpec` only, neither of which a `@Suite` is). The helper introduces no bare literal: its one default is the named `RealModels.context`.

    ## Measured so far

    `swift build` clean in 2.84 s.
  timestamp: 2026-08-18T13:21:43.658019+00:00
- actor: claude-code
  id: 01m0agq7aapr2z4ttpkf4aw38m
  text: |-
    ### implement — changed
    - evidence: 10 files — 1 new (`Tests/FoundationModelsRouterIntegrationTests/Support/RealModelContainer.swift`) and 9 modified (`CompactionRoundTripIntegrationTests.swift`, `CompactionSmokeIntegrationTests.swift`, `CompactionSpikeIntegrationTests.swift`, `LanguageModelSessionBackendTests.swift`, `PropagationProbeIntegrationTests.swift`, `RealToolTurnComparisonTests.swift`, `RecordingHandleIntegrationTests.swift`, `SessionTreeRestorationIntegrationTests.swift`, `TranscriptReconstructionIntegrationTests.swift`), all under `Tests/FoundationModelsRouterIntegrationTests/`.
    - the finding, swept whole rather than at the named line: the finding named four sites and said "and others". There were NINE. `rg -l makeContainer Tests/FoundationModelsRouterIntegrationTests/ | wc -l` now returns **0**. 23 call sites converted to `RealModelContainer.load(ref:context:samplingMode:)` — 9 in `LanguageModelSessionBackendTests`, 4 in `SessionTreeRestoration`, 2 each in `RealToolTurnComparison`/`PropagationProbe`/`CompactionRoundTrip`, 1 each in `TranscriptReconstruction`/`RecordingHandle`/`CompactionSpike`/`CompactionSmoke`. `#hubDownloader` now appears in exactly two files of the target: the shared helper, and `IntegrationTests.swift`, which was never part of the clone family because it builds its own instrumented `PhaseRecordingLoader`/`DownloadObservingLoader` stack.
    - verification: `swift build` exit 0. `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0, and a `grep -E "error:|warning:"` over the full log returns exactly one line — SwiftPM's pre-existing build-graph note `missing creator for mutated node: (…/mlx-swift_Cmlx.bundle/Contents/MacOS)`, which the same grep finds on a plain `swift build` of the unmodified tree. Zero compiler diagnostics. `swift test` exit 0: 978 + 28 + 58 tests pass with the one expected pre-existing `withKnownIssue`.
    - the extraction is proved behaviour-neutral, not argued: `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` passed in 4.284 s and reported fold numbers BYTE-IDENTICAL to this card's own record — `summarizerCalls=1 ceilings=[281] spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374 stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`, `wallClockSeconds=4.3 modelLoadSeconds=2.1`. Same model, same context, same greedy decoding: had the merge flattened any of the three parameters, those numbers would have moved.
    - one real defect the compiler found, and it is worth knowing: the shared helper first shipped without `import Foundation`. The `#hubDownloader()` / `#huggingFaceTokenizerLoader()` expansions name `Foundation.Progress` and `URL` in their own signatures, so the macro expansion failed to type-check even though nothing in the hand-written body mentions either. `--build-tests` caught it; a plain `swift build` never would, because it does not compile test targets.
    - not mine, do not attribute: `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` is modified in the working tree by the other session running the gated eval suite on this box. This card touched nothing under `FoundationModelsRouterEvals/`.
    - new work found and filed: `^we8n8nk` — the same loader-plus-`loadLLM` sequence exists twice more in `FoundationModelsRouterEvals/Support/`. It is out of this card's reach (separate test target, separate module) and out of its scope, and the card records what differs between those two copies so the next agent does not flatten their typed errors or their progress lines.
    - next: ready for /review. 12 of 12 acceptance criteria checked, 1 of 1 review finding checked. Nothing open.
  timestamp: 2026-08-18T13:24:37.834969+00:00
- actor: claude-code
  id: 01m0emv42waperqegxmvhqb7g9
  text: |-
    ### review — clean

    - evidence: `review sha d82c33e~1..d82c33e` (local backend) gave 0 findings, 1 candidate refuted. `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` passed: 2 tests, 0 failures, 13.85 s for the full command, build included.
    - The one prior finding (reuse/reuse, nine `makeContainer()` copies) is checked. Commit d82c33e made the fix. The engine found no new fault in that commit.
    - Superseded scope: card ^ryb01x7 moved the suite to `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/` and removed the env-var gate. Findings on the old paths do not apply. The review of 731a7ba (2026-08-19, clean) covered the moved code.

    Criterion evidence against the current tree (2026-08-19 run):

    1. Gate: the env-var gate is gone (^ryb01x7). The test target selects the test. The command ran with no env var.
    2. Small model: the model load took 2.0 s. The test downloaded nothing.
    3. Summarizer called: `summarizerCalls=1`, `ceilings=[291]`.
    4. Summary text not empty: `summaryTokens=330`.
    5. Summary smaller than the span: 330 < 643 (`summaryTokens` < `spanTokens`).
    6. Fold applied: `stages=["ToolOutputElision", "TurnTruncation", "Summarization"]` — the last stage is `Summarization`.
    7. `tokensAfter < tokensBefore`: 400 < 713.
    8. The test prints its times: `[compactionSmoke] wallClockSeconds=4.2 modelLoadSeconds=2.0`.
    9. Measured budget: 4.2 s and 6.3 s for the two tests, each less than 90 s.
    10. Time limit: the suite has `.timeLimit(.minutes(compactionSmokeTimeLimitMinutes))` and the doc states the measurement behind it.
    11. Doc scope: the suite doc says "It proves the PATH WORKS" and lists what it does not prove.
    12. Build and tests: the run built the package clean and all tests passed.

    - next: none. The card moves to done.
  timestamp: 2026-08-20T03:53:37.628795+00:00
- actor: claude-code
  id: 01m0emwan2w3n4w0sd8m4bcg23
  text: |-
    ### finish iteration 2 — clean
    - implement: none this iteration — the smoke test and the RealModelContainer extraction landed on 2026-08-18; the closing review never ran until now
    - review: clean — `review sha d82c33e~1..d82c33e`, 0 findings, 1 refuted; decisive check `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` 2/2 passed at 13.85 s total (test wall clock 4.2 s / 6.3 s), far under the 90-second budget
    - commit: none needed
    - outcome: task moved to `done`
  timestamp: 2026-08-20T03:54:17.122352+00:00
position_column: done
position_ordinal: ffd180
title: A compaction smoke test that answers "does compaction work at all" against a real model in under 90 seconds
---
Every present way to ask whether compaction works costs 28 minutes and gives back one bit. A run on 2026-08-17 burned 1800 seconds and measured 0 of 7 seeds. `^bgxtdk3`, `^vjf3mdm` and `^fm5ddk9` each waited a full gated run to learn a fact a fast test could have stated in a minute.

There must be a way to ask "does the compaction path work end to end against a real model" that finishes in less than 90 seconds of wall clock, model load included.

## Scope

The test proves the path WORKS. It does NOT prove fact retention quality — that stays with the slow eval tier. The test's own doc comment must say so, so nobody mistakes its scope later.

## What it proves

- The summarizer was called.
- The summarizer answered with text that is not empty (`^bgxtdk3` stored an empty summary on 19 of 19 seeds).
- The summary is smaller than the span it replaces, in the same unit `Compactor`'s did-not-shrink guard measures (`^vjf3mdm`, `^fm5ddk9`).
- The fold was APPLIED: `stagesApplied` ends with `Summarization.stageName`, not the shortfall exit.
- `tokensAfter < tokensBefore` on the returned result.

## How it stays under 90 seconds

- Do NOT load `mlx-community/Muse-Glimmer-30B-4bit`. 18 GB of weights eats the whole budget. Use the smallest real model already in the Hugging Face cache on this box.
- ONE seed, not seven. The smallest fixture whose span still clears the fold arithmetic.
- ONE generation. The fold only. No resumed session and no answering turn — that is a second generation and "works at all" does not need it.
- An output ceiling sized for this test, not the one inherited from the 30B path.

## Acceptance Criteria

- [x] The test has its own environment-variable gate, separate from `FM_ROUTER_INTEGRATION_TESTS`, so it runs without dragging in the 28-minute tiers. It follows the gate pattern the repository already uses; it does not invent a second mechanism. — `FM_ROUTER_COMPACTION_SMOKE`, read as a file-scoped constant with a `!= nil` lookup and a suite `.enabled(if:)` trait. Measured: with that variable set and NO filter, the whole `swift test` ran in 18.0 s and no `FM_ROUTER_INTEGRATION_TESTS` suite ran.
- [x] The test loads a small real model already present in the Hugging Face cache, not `Muse-Glimmer-30B-4bit`. — `mlx-community/Llama-3.2-1B-Instruct-4bit`, 680 MB, already cached. Nothing downloaded.
- [x] The test asserts the summarizer was called. — `ceilings.count == 1`, which also pins the one-generation budget.
- [x] The test asserts the summary text is not empty.
- [x] The test asserts the summary is smaller than the span it replaces, in the unit the did-not-shrink guard measures. — 304 estimated tokens against a 600-token span.
- [x] The test asserts `stagesApplied.last == Summarization.stageName`.
- [x] The test asserts `tokensAfter < tokensBefore`. — 374 against 670.
- [x] The test prints its own wall-clock duration, and the model load time as a separate number. — `[compactionSmoke] wallClockSeconds=... modelLoadSeconds=...`, from a `defer` so a red run states it too.
- [x] A measured run comes in under 90 seconds. The report states the observed figure, not an estimate. — 4.0 s to 4.3 s over five runs, of which 1.9 s to 2.0 s is the model load.
- [x] A `.timeLimit` trait bounds the test a little above the measured figure, and the constant behind it states its measurement the way `GatedRealModelBudget` states its own. — `compactionSmokeTimeLimitMinutes = 1`, the smallest `.timeLimit` Swift Testing accepts; the suite doc carries the three-run table behind it.
- [x] The doc comment says the test proves the path works and does not measure fact retention.
- [x] `swift build`, `swift build --build-tests -Xswiftc -warnings-as-errors` and `swift test` are clean: zero failures, zero warnings, one expected pre-existing `withKnownIssue`. — 978 + 28 + 58 tests pass, one known issue at `BoundedWait.swift`.

## Constraints

- Never run `swift format` or `swiftformat` in this repository.
- No `@MainActor` on tests in this target.
- Keep Swift-idiomatic acronym casing (RAM/JSON/LLM).
- Do not weaken any present assertion, and do not change the length directive in `Summarization`.
- Do not run `FM_ROUTER_INTEGRATION_TESTS=1` or `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` while working this card.

## How to run it

```
FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests
```

## Review Findings (2026-08-18 07:37)

> Scope: `review sha 160ca9e~1..160ca9e` — reviewed the diffs only — lines this change added or modified. 1 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift:403` `reuse/reuse` — The `makeContainer()` function reimplements code that already exists in multiple test files identically. Per clone-siblings probe: CompactionRoundTripIntegrationTests.swift:154 at 1.00 similarity, CompactionSpikeIntegrationTests.swift:60 at 0.99, LanguageModelSessionBackendTests.swift:57 at 0.98, and others. This function should be extracted to a shared test utility module or the existing implementation should be reused. Extract `makeContainer()` into a shared test utility (e.g., `Tests/FoundationModelsRouterTestSupport/ModelLoaderTestHelpers.swift`) so all integration tests call the same implementation, or refactor to call through an existing shared helper. — Fixed. All NINE copies in `FoundationModelsRouterIntegrationTests` (not only the four named) now call one `RealModelContainer.load(ref:context:samplingMode:)` in `Tests/FoundationModelsRouterIntegrationTests/Support/RealModelContainer.swift`. `grep makeContainer` over the target returns 0. The helper could not go in `FoundationModelsRouterTestSupport`: `MLXFoundationModelsContainer` is internal to `FoundationModelsRouter` and that plain `.target` links neither `@testable import` nor the Hub macros — see the comment thread. #compaction #eval #real-model
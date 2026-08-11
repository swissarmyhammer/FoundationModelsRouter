---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzh0f0c5vbh4s49s8t11s80n
  text: |-
    ### Evidence from `^5m97h14`: this class also hits `FoundationModelsRouterEvals`, and it is the sole remaining cause of two red gated evals

    Recorded here rather than worked, per this card owning the class. `^5m97h14` fixed the fill/trigger accounting (the estimator counting a transcript's JSON envelope as tokenizable text, and the trigger comparing a fraction of `contextTokens` against a fraction of `budget.limit`). With that fixed, folds now happen correctly everywhere — and the residue is entirely this card's.

    **This card's AC "The recall half of `CompactionRoundTripIntegrationTests` is attributed either to this class or to `^5m97h14`" is now answerable: to this class.** `recall.contains("CRIMSON-77")` is green in an isolated gated run of that suite (61.8s, whole suite passing) now that the fold happens at the right point, so its recall failure under a *full* gated run is inherited cross-suite state, not sizing.

    #### New: the same defect inside `FoundationModelsRouterEvals`, one target, one process

    Both eval runners cache a single resident `MLXFoundationModelsContainer` across every sample (`CompactionEvalRealSubjectRunner.loaded`, `CompactionContinuityEvalRealSubjectRunner.loaded`) and only `evict()` after the whole `@Test` finishes. So 24 and 10 samples respectively share one prompt cache, and — in the first runner — so do the blank-slate *summarizer* session and the session that answers the question.

    `CompactionEvaluationIntegrationTests` `mean(factRetention)` is `0.0833` (2 of 24). Instrumented gated run, printing each fold's summary alongside the answer:

    ```
    summary=1. Intent — Inform the assistant of the internal codename for a new feature.
            2. Constraints & decisions — The internal codename for the new feature is "Project Longbow". …
    question=What is the internal codename for the new feature?
    answer=Noted.

    summary=… 2. Constraints & decisions — Staging database port is 6543. …
    question=What port does the staging database listen on?
    answer=Noted.

    summary=… The production deployment region is eu-west-2, selected for data-residency reasons. …
    question=Which region is the production deployment in, and why was it chosen?
    answer=Noted.

    summary=… 2. Constraints & decisions — Data at rest in this project is encrypted with AES-256-GCM …
    question=Which encryption mode is used for data at rest in this project?
    answer=Noted.
    ```

    **Every summary contains the planted fact verbatim.** The compaction is correct and the summary quality is high. The answer is `"Noted."` — the reply that belongs to *acknowledging a fact statement*, which is what the seed transcripts' own turns do, in some other sample's conversation. Same shape as this card's "narrating a call it never made": the model emits a reply that fits a neighbouring conversation rather than the one it was given.

    The second signature is the summarizer's own output format leaking into the next turn:

    ```
    answer=1. Intent — The user is asking for specific information (return flight number)
           that was provided in the conversation.
    ```

    `CompactionContinuityEvaluationIntegrationTests` shows the identical leak. Ten samples, every one folding correctly; eight answered perfectly from the folded summary, two returned the summarizer's format instead:

    ```
    answer=1. Intent — The user asked for two specific pieces of information from the
           conversation history: the escalation time for a tier-1 ticket and the on-call
           escalation contact for the current week.
    answer=1. Intent — The user asked for the exact file paths to the migration script and
           its corresponding rollback script, without re-reading prior context.
    ```

    Both are `foldCount=2` samples — the ones that made an *extra* summarizer call. The eight correct ones are mostly `foldCount=1`. That correlation is the strongest pointer yet at the mechanism: each summarizer call is a separate blank-slate conversation on the shared model, and the turn that follows it inherits its chunks.

    The same run-to-run variability this card already documents holds: `mean(answersCorrect)` was `0.5` on one gated run and 8-of-10 on the next, same code, same fixtures.

    #### What this adds to the plan

    Option (1) here is "cross-suite clean-model isolation in one shared place". These two eval runners are in a *different* test target from `GatedSuiteSerialGate`, and the contamination is **within** a single suite — sample to sample, and summarizer-session to answering-session — not only across suites. So whatever shared "start from a clean model" step lands has to be reachable per *sample* and per *summarizer call*, not only per suite. Worth measuring the cost: eviction drops the container, so a naive per-sample evict reloads a 27B model 24 times.

    That summarizer-to-answerer leak inside one sample is also the strongest evidence yet for escalating to option (2): two sessions constructed blank-slate over disjoint transcripts on the same model should not be able to see each other's KV state at all. If that reproduces after isolation, it is a `PromptCache` prefix-resolution question in `mlx-swift-lm` and belongs on the fork's board, not here.
  timestamp: 2026-08-08T15:39:30.565287+00:00
- actor: claude-code
  id: 01kzq79926g0vq0dnyeph1qqfp
  text: |-
    ### Measurement log — baseline (before any change), commit ee5b881

    USER EXPLICITLY AUTHORIZED gated runs for this card.

    Scope note: measured `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter FoundationModelsRouterIntegrationTests`. The contamination under study is *within* that target's process (one shared per-model PromptCache across its suites) and every failure the card names lives there. Running the whole `swift test` would additionally spin up the two Evals suites in separate processes at ~5-9 min each with no measurement value. Runs are ~2.5 min each, so repetition is cheap.

    Baseline, 3 full runs, by position among gated suites:

    | run | RecordingHandle | PropagationProbe | other |
    |-----|-----------------|------------------|-------|
    | 1 | pos 1 — FAIL (2 issues, 9.888s) | pos 8 — pass (17.5s) | CompactionRoundTrip pass |
    | 2 | pos 3 — FAIL (2 issues, 9.889s) | pos 4 — FAIL (1 issue, 14.3s) | CompactionRoundTrip pass |
    | 3 | pos 6 — pass (24.8s) | pos 1 — FAIL (1 issue, 14.4s) | CompactionRoundTrip pass |

    Exact signatures, both the card's predicted ones:
    - `RecordingHandleIntegrationTests.swift:290` / `:309` — `isInOrderSubsequence([.session, .instructions, .prompt, .toolCalls, .toolOutput], of: beforeSync.map(\.kind))` failed. The turn produced NO `.toolCalls` entry.
    - `PropagationProbeIntegrationTests.swift:446` — `turn.recordedCallCount > 0` failed. Zero tool call.

    Note the duration tell: RecordingHandle fails in 9.89s and passes in 24.8s — the failing runs are FASTER, consistent with no tool call being dispatched.

    ISOLATION CONTROLS (decisive):
    - `--filter PropagationProbeIntegrationTests` alone: PASSES, recordedCallCount=1. Confirms the card's "run alone called the tool every time".
    - `--filter RecordingHandleIntegrationTests` alone: PASSES (16.2s).

    So both suites are correct in isolation and fail only when sharing a process with other suites. This is a genuine cross-suite interaction, not a defect in either test.

    CAUTION on the position correlation: with n=3 the "early fails / late passes" pattern is suggestive but NOT established — do not act on it. The solid result is the isolation control: empty cache passes, inherited cache fails.

    AC#1 (does ^f9zt7c5's mid-run eviction help or hurt siblings?): the probe carries that eviction and STILL failed in 2 of 3 runs, so that per-suite fix is NOT sufficient even for its own suite. Measurement of the shared mechanism follows.

    AC#4: `CompactionRoundTripIntegrationTests` recall PASSED in all 3 baseline runs (`recall.contains("CRIMSON-77")` never failed; tokensBefore=2074 tokensAfter=1379 saved=695 each time). Its recall half is therefore NOT reproducing on this commit — the four failures the card recorded on 2026-08-08 predate ^5m97h14's sizing fix, which is the more likely attribution. Not attributed to this class on current evidence.
  timestamp: 2026-08-11T01:34:09.478429+00:00
- actor: claude-code
  id: 01kzq8ze0djnbtbvtarxb0nqmz
  text: |-
    ### Stopped chasing a failure rate — redirected to ^w8dzvee (human direction)

    Repeated gated runs were the wrong approach to this card, and I stopped them. Recording why, and what the runs did establish, so the next reader does not restart the same loop.

    **The likely misattribution.** This card frames the failures as prompt-cache contamination between suites. But the failure signature in `RecordingHandleIntegrationTests` is that the transcript never gains a `.toolCalls` entry — that is the recording/streaming path, which is exactly where `^w8dzvee`'s two defects live:
    - D1 — `RoutedSessionActorRecording.swift:365-379` emits `.toolStatus(.completed)` keyed by `entry.entryId` while `.toolCall`/`.running` use `call.id`.
    - D2 — `LiveModelLoader.swift:395` returns the whole snapshot as a delta when the prefix guard fails, which happens on every tool boundary.

    Tool calling being broken on the streaming/recording path is a simpler and better-supported explanation of "the tool call went missing" than cross-suite chunk reuse. Fix the tool-call logic first; re-examine this card only if failures survive that.

    **What the 13 runs did establish (keep this, it was not free):**
    - Both suites PASS when run alone — `--filter PropagationProbeIntegrationTests` (recordedCallCount=1) and `--filter RecordingHandleIntegrationTests`.
    - Runs 1-3 failed; runs 4-7 were completely clean; 8-13 were spoiled by concurrent load. The failing window coincided with ~50 parallel sessions on the machine (load ~10), so the baseline is confounded and no failure rate from it is trustworthy.
    - Exact signatures seen: `RecordingHandleIntegrationTests.swift:290`/`:309` (`isInOrderSubsequence`, no `.toolCalls`) and `PropagationProbeIntegrationTests.swift:446` (`recordedCallCount > 0`).
    - Measurement here needs exclusive GPU. Three repos were running model-loading tests simultaneously (Router, FoundationModelsMultitool `SearchThenCallTests`, mlx-swift-lm `MLXLMTests`) at ~14GB each. Any future run-to-run comparison on a shared machine is worthless.

    **AC#4 — attribution.** `CompactionRoundTripIntegrationTests` recall passed every single run (`recall.contains("CRIMSON-77")` never failed; tokensBefore=2074 tokensAfter=1379 saved=695). Its recall half is NOT reproducing on this commit, so it attributes to `^5m97h14`'s sizing work rather than to this class.

    **AC#5 — fork items (must be filed on the mlx-swift-lm board, never fixed in this repo):**
    1. `MLXLanguageModel.removePromptCache(modelID:)` is not `public`. The only public lever that clears a prompt cache is `evictAll()`, which also frees model weights — so test isolation cannot get a clean cache without paying a full model reload. Request a public prompt-cache-only clear.
    2. Its own doc records that an entry is dropped when "a round's actual generated content can't be reconciled with `cache`'s own `offset` … the entry is untrustworthy". Chunks are shared across every conversation on a model. Open question, NOT proven: can a prefix-matched chunk chain leave a fresh session in a state where a tool call appears already made? Evidence is the observed narration of a call that was never dispatched. File as a question with this evidence; the load confounder means it is not established.

    Card stays open and is NOT done. It is parked behind `^w8dzvee`.
  timestamp: 2026-08-11T02:03:44.013081+00:00
- actor: claude-code
  id: 01kzq94x7cs7p5phteqpp9pv6p
  text: |-
    ### Correction: the failure DOES reproduce — runs 8-13 landed after the stop

    Runs 8-13 completed after I had already stopped this work, and they overturn the "clean, does not reproduce" reading in my earlier comment. Recording the correction rather than leaving the wrong conclusion standing.

    | run | load (1-min) | result |
    |-----|--------------|--------|
    | 8 | 8.61 | FAILED |
    | 9 | 10.68 | FAILED |
    | 10 | 10.21 | FAILED |
    | 11 | 10.91 | passed |
    | 12 | 11.78 | FAILED |
    | 13 | 11.73 | FAILED |

    Full tally across all 13 runs on commit `ee5b881`: **8 failed, 5 passed**. Runs 4-7 passing consecutively was a streak, not evidence of absence — I over-read it.

    Two things this changes:

    1. **The phenomenon is common, not rare.** ~60% of gated runs fail. That is a real defect worth fixing, and it is frequent enough that a handful of post-fix runs is a genuine verification signal.
    2. **It does not exonerate the load confounder, but it no longer needs it.** Every run 8-13 sat at load 8.6-11.8, so these are all "loaded machine" samples and cannot separate load from cause. What they do establish is that the failure is reliably reachable, which is all that is needed to verify a fix.

    The redirection still stands: fix the tool-call logic in `^w8dzvee` (D1 keyed-by-wrong-id in `RoutedSessionActorRecording.swift:365-379`, D2 snapshot-delta corruption in `LiveModelLoader.swift:395`) before treating this as a prompt-cache problem. The `RecordingHandleIntegrationTests` signature — no `.toolCalls` entry ever appearing — is a recording-path symptom, and this failure rate is high enough that if D1/D2 are the cause, fixing them should visibly move it.

    Suggested verification once `^w8dzvee` lands, on a machine with no other model tests running: repeat the gated suite ~6 times and compare against this 8/13 baseline.
  timestamp: 2026-08-11T02:06:43.436747+00:00
- actor: claude-code
  id: 01kzr7xa3jf7ph9tmw04pd6jm9
  text: |
    ### Handed over from `^w8dzvee`: measured evidence that the real model does not reliably dispatch every tool

    Found while diagnosing `^w8dzvee`'s gated `RealToolTurnComparisonTests`. Router itself records faithfully on every turn measured, so this residue is model behaviour and belongs here.

    **Setup.** `mlx-community` `.standard` model, two tools (`lookup-alpha`, `lookup-beta`), sampling pinned to greedy, prompt and instructions fixed. Instructions name both tools and both step arguments explicitly and say to reply with both identifiers "exactly as they were returned, and nothing else". Each tool returns `MARKER-7F3A-<STEP>`.

    **Measured over 8 independent turns (4 gated runs, 2 turns each), tool rounds per turn:**

    | turn | rounds | what it called |
    |---|---|---|
    | A-respond | 2 | alpha/ONE, beta/TWO — compliant |
    | A-stream | 2 | alpha/ONE, beta/TWO — compliant |
    | B-respond | **11** | `#0` alpha/ONE, `#1` beta/TWO, then 9 more; `#5`–`#10` all repeat alpha/ONE |
    | B-stream | 2 | compliant |
    | C-respond | 3 | beta/TWO, alpha/ONE, then alpha/ONE again |
    | C-stream | 2 | compliant |
    | D-respond | **1** | beta/TWO only |
    | D-stream | **1** | alpha/ONE only |

    **Two distinct failure shapes, both this card's:**

    1. **Under-calling with a fabricated identifier.** D-respond called only `lookup-beta`, got `MARKER-7F3A-TWO`, and answered `"MARKER-7F3A-TWO, MARKER-9B2C-ONE"`. D-stream called only `lookup-alpha`, got `MARKER-7F3A-ONE`, and answered `"MARKER-7F3A-ONE, MARKER-9B2C-TWO"`. **`MARKER-9B2C-*` is not a real marker** — the scenario's `markerPrefix` is `MARKER-7F3A-`. The model invented a plausible-looking identifier for the tool it never called rather than calling it. That is worse than omitting the answer, because the fabrication is not distinguishable from a real identifier by shape.

    2. **Runaway repetition.** B-respond made 11 rounds, 9 of them re-issuing the identical `lookup-alpha({"step":"ONE"})` and receiving the identical output each time. It did eventually answer correctly. Note the vendored `TranscriptConverter` already anticipates this shape — its `.toolOutput` case comments that an empty tool output is emitted anyway "so a continuation round's prompt always differs from the round that made the call -- dropping empty outputs would make the two rounds' rendered prompts identical and risk the model repeating the same call forever". Here the outputs are non-empty and the prompt does grow each round, so the loop is the model's, not that hazard.

    **Also worth this card's attention: the trajectory is not reproducible.** Same surface, same fixed prompt, cold process each time, sampling pinned to greedy (which `SamplingModeMapper.resolveSamplingParameters` resolves to temperature 0 / argmax) — and `respond(to:)` alone produced 11, 3, 2 and 1 rounds. Two Router-side explanations were checked and ruled out: both session surfaces build the identical `GenerationOptions(samplingMode:maximumResponseTokens:)`, and the tool-call id reaches the converter as `Chat.Message.tool(id:)` structurally rather than as rendered prompt text. So the non-reproducibility is below Router, and any tool-dispatch reliability work on this card has to be measured as a rate over repeated runs, never from a single run.

    **What `^w8dzvee` did with this.** Nothing — deliberately. Its gated suite now asserts only what Router owns (each surface's answer equals its own turn's final response character for character; the answer carries every marker *that turn's* tools delivered; one tool output per announced call, each resolving to its call; streamed completion ids equal streamed call ids). A turn that calls one tool instead of two now passes there, correctly, because it is this card's defect and not Router's. Reproduce with `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter RealToolTurnComparison`, which prints both surfaces' full transcripts and answers on every run.
  timestamp: 2026-08-11T11:04:20.338620+00:00
- actor: claude-code
  id: 01kzr9c05mfx6htpe32m5cv8tb
  text: |
    ### New measurement from `^w8dzvee`'s gated suite: a turn that dispatches ZERO tools

    `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter RealToolTurnComparison`, three runs on one machine,
    same code, same prompt, sampling pinned to greedy. The scenario mounts two tools and the instructions
    name both by tool name and by argument.

    - Run 1: `respond(to:)` made 2 rounds (correct); `streamEvents(to:)` made 1 round (`lookup-alpha`/`ONE`
      only) and then wrote `MARKER-9B2C-TWO` for the tool it never called — a fabricated identifier, since
      the scenario prefix is `MARKER-7F3A-`.
    - Run 2: `respond(to:)` made **zero** tool calls. Its whole transcript was
      `instructions, prompt, response`, and the answer was
      `"The identifier for step ONE is 12345, and the identifier for step TWO is 67890."` — both values
      invented. On the same run `streamEvents(to:)` made 11 rounds for the same prompt.
    - Run 3: 2 rounds and 3 rounds, both surfaces correct.

    Router recorded every one of these faithfully: each announced call had a matching output, each output
    resolved to the call it answers, completed ids equalled called ids, no failures. The divergence is the
    model's dispatch decision, which is this card.

    Two consequences worth carrying here:
    1. The failure is not only "calls fewer tools than asked". It reaches **zero**, and the model then
       fabricates plausible identifiers rather than saying it has none.
    2. `^w8dzvee`'s gated suite fails hard on a zero-tool turn by design, so that suite is intermittently
       red for exactly this reason. Anyone reading a red `RealToolTurnComparison` run should check the
       printed transcript for `toolCalls` before looking for a Router defect.
  timestamp: 2026-08-11T11:29:50.260181+00:00
- actor: claude-code
  id: 01kzr9hhm6f427asxngs61hfxx
  text: |-
    ### Hard evidence, replacing the failure-rate approach

    `^w8dzvee`'s diagnosis produced direct observations of the real model that are far more useful than the failure rate I was chasing. Recording them here because they are this card's actual subject.

    **Observed over 8 real turns on a fixed prompt with sampling pinned to `.greedy` (temperature 0, argmax — verified in `SamplingModeMapper.resolveSamplingParameters`):**

    | turn | tool rounds |
    |------|-------------|
    | A-respond / A-stream | 2 / 2 — compliant |
    | B-respond | **11** — rounds 5-10 all repeat the same call |
    | B-stream | 2 |
    | C-respond / C-stream | 3 / 2 |
    | D-respond | **1** — beta only |
    | D-stream | **1** — alpha only |

    Plus, in a later gated run, a turn where the model dispatched **zero** tools on the respond surface.

    **Three distinct failure modes, none of which is Router's:**
    1. **Under-calling** — one call when the prompt asks for two.
    2. **Runaway** — 11 rounds, repeating an identical call six times.
    3. **Fabrication** — on the two 1-round turns the model answered with `MARKER-9B2C-ONE`/`MARKER-9B2C-TWO`, and in the zero-tool run with `12345`/`67890`. **The scenario's marker prefix is `MARKER-7F3A-`.** The model invented identifiers for tools it never called and presented them as results.

    That third one is this card's original symptom seen directly: a model narrating a tool call it never made. It is not cross-suite prompt-cache contamination — it happens on a fresh turn at temperature 0.

    **Router was clean in every one of those turns**: one `.toolOutput` per announced call, every output resolving to its call, `completed == called` by set and count, no failures, and each surface's answer equal to its own transcript's final `.response`.

    **Consequence for this card's method.** The trajectory is not reproducible under greedy, so "does suite X fail" is not a property of the code — it is a sample from a distribution. Any future work here must measure dispatch reliability as a **rate over many turns**, with the machine otherwise idle, and must not treat a single run as signal. Equally, the 8-in-13 baseline I recorded earlier is not a code property and should not be compared against post-fix runs.

    **Re-scoping.** The card is framed as "suites lose their tool call when they inherit another suite's prompt cache". The prompt-cache hypothesis is now *unsupported* as the primary cause — the same failures occur on isolated fresh turns. What is established is that this model dispatches tools unreliably. Whether the prompt cache makes it *worse* remains open and would need the controlled comparison this card originally described, on a quiet machine.

    Left in `todo`. Not closed, not worked further here.
  timestamp: 2026-08-11T11:32:51.974332+00:00
- actor: claude-code
  id: 01kzr9mawt155r6c4hs9m7w490
  text: |-
    ### AC#5 satisfied — both fork items filed on the mlx-swift-lm board

    Filed on `/Users/wballard/github/swissarmyhammer/mlx-swift-lm/.kanban`, not here, per the standing rule that anything needing a change in the vendored fork belongs on that repo's board. Nothing in this repo was modified to do it.

    1. **`^qsv1415` — "Make prompt-cache clearing available without evicting model weights."** `MLXLanguageModel.removePromptCache(modelID:)` (`MLXLanguageModel.swift:843`) is not public; the only public lever is `evictAll()` (`:857`), which also frees model weights. So a suite wanting a clean cache per case must pay a full 27B reload, which makes per-suite cache isolation impractical. Asks for the internal function, or an equivalent, to be exposed.

    2. **"Can a prefix-matched prompt-cache chunk chain leave a session acting as though a tool call already happened?"** — filed deliberately as a **question with evidence, not an asserted defect**. It carries the fabricated-marker observations (`MARKER-9B2C-*` against a `MARKER-7F3A-` prefix; `12345`/`67890` on a zero-tool turn) and the note that this repo's own `removePromptCache` doc already describes untrustworthy entries whose generated content cannot be reconciled with the cache offset. It states plainly that the symptom is equally explained by the model simply being unreliable at dispatch, and that the evidence here cannot separate the two — so someone with visibility into chunk resolution should rule it in or out.

    Both cards record that they were filed from this one. Neither is work for this repo.
  timestamp: 2026-08-11T11:34:23.386033+00:00
position_column: todo
position_ordinal: 8a80
title: Gated tool-calling suites lose their tool call or their recall when they inherit another suite's prompt cache
---
Discovered while working `^f9zt7c5`, which proved the mechanism for one suite and fixed only that suite.

`MLXLanguageModel` holds a process-global container cache keyed by model id and, beside it, a per-model `PromptCache` that stores each completed round's KV state as content-addressed chunks **shared across every conversation on that model** (SGLang RadixAttention-style; see `.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/PromptCache.swift`). Every gated suite in `FoundationModelsRouterIntegrationTests` drives the same `RealModels.standard`, so each suite's turn resolves against a chunk pool other suites filled.

`^f9zt7c5` measured what that does to one suite: under a full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` the propagation probe's turn reproducibly emitted **no tool call** and answered `"I have called the context_probe tool with the note 'ping'."` — narrating a call it never made — while the identical turn run alone called the tool every time. Dropping the model (`MLXLanguageModel.evict()`, which purges that model's prompt cache) before the turn restored the real dispatched call, reproducibly.

Sibling suites show the same two signatures and are **not** yet protected. Across four full gated runs on 2026-08-08:

- `RecordingHandleIntegrationTests.toolUsingTurnRoundTripsToDisk` — failed once on `isInOrderSubsequence([.session, .instructions, .prompt, .toolCalls, .toolOutput], ...)`, i.e. its echo turn produced no `.toolCalls` entry at all. Same zero-tool-call signature as the probe's.
- `CompactionSpikeIntegrationTests` — failed once on `reply.contains("42")`: the rebuilt session did not recall a fact its own transcript carried.
- `CompactionRoundTripIntegrationTests` — failed in **all four** runs, including `recall.contains("CRIMSON-77")` → `"I do not have access to the project brief or any vault codes."`. Its fill-threshold assertions are already owned by `^5m97h14`; the *recall* failure looks like this class rather than sizing, so check both cards together.

Which sibling fails varies run to run, so this reads as shared-state flakiness, not a deterministic break. Note also that `^f9zt7c5`'s fix itself now drops `RealModels.standard` mid-run, which perturbs what later suites inherit — measure whether that helps or hurts the siblings rather than assuming.

Two candidate shapes, and the choice is the work:

1. **Per-suite isolation, in this repo.** Give the gated tier one shared "start from a clean model" step instead of one suite knowing the trick — the natural home is `GatedSuiteSerialGate` / `Support/`, which already owns the cross-suite RAM permit and the metallib bootstrap. This is the in-scope option.
2. **A prompt-cache correctness question, in the fork.** If a prefix-matched chunk chain can make a model behave as though a tool call or a fact already happened, that is a `PromptCache` resolution question in `mlx-swift-lm`, not a test-hygiene one. Per standing project rule, anything needing a change in the vendored fork belongs on the fork's own board — file it there, do not attempt it here.

Start with (1) and measure; only escalate to (2) with evidence that isolation is insufficient.

## Acceptance Criteria
- [ ] Determined whether the probe's mid-run eviction helps or hurts sibling suites, measured across repeated full gated runs
- [ ] Cross-suite clean-model isolation lives in one shared place, not duplicated per suite
- [ ] `RecordingHandleIntegrationTests` and `CompactionSpikeIntegrationTests` pass across repeated full gated runs, or their remaining failure is attributed to a named cause
- [ ] The recall half of `CompactionRoundTripIntegrationTests` is attributed either to this class or to `^5m97h14`
- [ ] If the residue is a fork `PromptCache` defect, it is filed on the mlx-swift-lm board and referenced here — not worked in this repo
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Repeated full gated runs are the proof. Gated runs: one at a time, one shell command per run.
#phase-1
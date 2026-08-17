---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m080m6xzqny0dsewqvqhdhgg
  text: |-
    Picked up. Pre-run checks against the published commit:

    - `git rev-parse HEAD` = `aff8b1b6ee3ccc97eae05dd20efceb634c81a289`. Correct commit.
    - `git status --porcelain -- ':!.kanban'` is empty. No source file is modified. The only dirty paths are board bookkeeping under `.kanban/`, which the build does not read.

    Invocation research. The card says the gated suites are `.exclusiveRealModel` and expect serialization, so I read the suite's own comments before choosing flags. `Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift` documents that the target serializes itself in process: `GatedSuiteSerialGate.shared` is an `AsyncSemaphore(value: 1)`, and `GatedRealModelSuiteTrait.provideScope` holds that one permit for the whole duration of each gated suite. The comment states the intent word for word — "making the whole gated tier serial across files, not just within one". The same trait also installs the metallib symlink before any suite touches the GPU.

    So the documented invocation is the plain one, with no extra flag. `--no-parallel` is not this suite's mechanism. The only written invocation in the repository agrees: `compaction_plan.md` records `FM_ROUTER_INTEGRATION_TESTS=1 swift test`.

    One limit the same file records, which bounds what this run can prove: the permit covers this target only. `FoundationModelsRouterEvals` is a separate target and a separate process, so its gated evals are not serialized against these suites.

    Running `FM_ROUTER_INTEGRATION_TESTS=1 swift test` now. It runs detached with output to a log file and I poll it, so that no command timeout can end the run and be misread as a failure.
  timestamp: 2026-08-17T14:04:53.055251+00:00
- actor: claude-code
  id: 01m084gah69bvd2s1vean3e9q7
  text: |-
    ## The run — RESULT: FAILED

    Command, word for word:

    ```
    FM_ROUTER_INTEGRATION_TESTS=1 swift test
    ```

    Commit `aff8b1b6ee3ccc97eae05dd20efceb634c81a289`, no source file modified. Machine: Apple Silicon, real GPU, real weights. Total wall clock 3443 s (57.4 min), build included. Exit code 1.

    `swift test` runs three test targets, and each reports its own totals:

    | Target | Tests | Suites | Duration | Result |
    |---|---|---|---|---|
    | `FoundationModelsRouterTests` (stub/unit) | 966 | 91 | 5.526 s | **passed**, 1 known issue |
    | `FoundationModelsRouterIntegrationTests` (gated, real model) | 27 | 11 | 1020.754 s | **failed**, 10 issues |
    | `FoundationModelsRouterEvals` (gated, real model) | 24 | 5 | 2401.169 s | **failed**, 5 issues |

    The 1 known issue is declared, not a fault: `BoundedWait.swift:114` inside "a condition that never holds ends the wait, and never before a late change would have landed". That test passed.

    The environment ran the suite correctly. This is a test result, not a missing GPU and not a failed download.

    ### The 10 gated integration issues

    1. `RecordingHandleIntegrationTests.swift:322` — `afterSync.map(\.kind).last == .response`. Actual last kind: `.reasoning`.
    2. `IntegrationTests.swift:269` — `await loader.observedLoadPhases.count == 3`.
    3. `IntegrationTests.swift:271` — `await loader.observedPreloadPhases.count == 3`.
    4. `CompactionRoundTripIntegrationTests.swift:444` — `fillBeforeCompaction >= 0.80`. Actual `0.79736328125`.
    5. `CompactionRoundTripIntegrationTests.swift:487` — `recall.contains("CRIMSON-77")`. Actual reply: "I have no vault code from a project brief in this conversation."
    6. `RealToolTurnComparisonTests.swift:532` — `kinds.last == .response`. Actual last kind: `.reasoning`.
    7. `LanguageModelSessionBackendTests.swift:195` — `backend.session.transcript.count == 4`. Actual `5`.
    8. `LanguageModelSessionBackendTests.swift:212` — `child.session.transcript.count == 2`. Actual `3`.
    9. `LanguageModelSessionBackendTests.swift:570` — `turn2Usage.input.cachedTokenCount > 0`. Actual `0`.
    10. `LanguageModelSessionBackendTests.swift:581` — `abs(turn2Usage.input.cachedTokenCount - turn1ProcessedTokenCount) <= tolerance`. Actual difference `155`, tolerance `38`.

    ### The 5 gated eval issues

    11. `CompactionEvaluationTests.swift:421` — Time limit was exceeded: 1200.000 seconds.
    12. `CompactionEvaluationTests.swift:443` — `result.aggregateValue(.mean(of: CompactionEvalMetric.factRetention)) >= 0.9`.
    13. `CompactionContinuityEvaluationTests.swift:249` — Time limit was exceeded: 1200.000 seconds.
    14. `CompactionContinuityEvaluationTests.swift:261` — `result.aggregateValue(.mean(of: CompactionContinuityMetric.foldOccurred)) == 1.0`.
    15. `CompactionContinuityEvaluationTests.swift:262` — `result.aggregateValue(.mean(of: CompactionContinuityMetric.answersCorrect)) >= 0.8`.

    In both evals the time limit is the first issue and the aggregate assertions are downstream of it: the run was cut off before all samples completed, so the means are computed over an incomplete set.

    The card says not to retry a failure, and I did not. The suite ran one time. Attribution follows in the next comment.

    Full log kept at `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/integration-run.log`.
  timestamp: 2026-08-17T15:12:39.974689+00:00
- actor: claude-code
  id: 01m084sy11zh6aa6zpptx1kr77
  text: |-
    ## Attribution — which of the six changes the failures implicate

    Short answer: **none of the six.** I looked for evidence that they did, and the diff refuses it.

    The card names six changes: `^1zt7vyg` permit loan, `^z6xcmnh` stall watcher, `^jgh63sf` detachment engine and per-tool mounts, `^fmet68k` gate ownership, `^d2ptrk1` refusal paths, `^trwcs63` contention tests. The batch `7e0c7c5..aff8b1b` changes 21 source files. All of them are in `Session/`, `Hosting/`, `Concurrency/`, `Router.swift`, `RoutedLLM.swift`, and `LanguageModelProfile.swift`.

    These directories are **untouched** in the range:

    - `Sources/FoundationModelsRouter/Compaction/`
    - `Sources/FoundationModelsRouter/Recording/`
    - `Sources/FoundationModelsRouter/Resolution/`
    - `Package.swift` and `Package.resolved`

    `Router.swift` has one change in the range, from `^fmet68k` (`244b1ac`). It replaces two `AsyncSemaphore` fields on `PoolEntry` with one `ResidentModelGates` value. It does not touch `resolve`, the acquisition loop, the `pool[key]` test in `acquireModel`, `download`, `finalize`, `newKeys`, or `preloadedKeys`. It moves where the semaphores live. It does not change how many turns can run together.

    `RoutedSessionActorCompaction.swift` has one change in the range, from `^d2ptrk1` (`1944077`): `await beginTurn()` becomes `try await beginTurn()`. That can only refuse a turn. It cannot change the text a summary holds. No refusal was raised in this run.

    Each failure now has its own cause.

    ### Cause 1 — the summarizer has no room to think. 19 of 19 empty summaries.

    This is the largest finding, and it is a defect in production code.

    The eval log prints one line for each seed. All 19 seeds are the same:

    ```
    - seed=<name> class=summaryLostFact factInSummary=false folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
      summary=
    ```

    - 19 seeds, `folded=true` on all 19. The fold mechanism works.
    - `summarizerCalls=1` on all 19. The summarizer runs.
    - `factInSummary=false` on 19 of 19. `factInSummary=true` on 0.
    - `summary=` is **empty on all 19**.

    The summary is not bad. The summary is empty.

    The mechanism is measured and written down in this repository already. `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift` says it word for word:

    > The gated model always reasons. It writes a `<think>` block first, then it writes the answer after that block. This ceiling must give space to the `<think>` block and to the answer.
    > A ceiling with space for the answer alone is not sufficient. The `<think>` block uses all of it, generation stops in the middle of the reasoning, and the turn records an empty response.
    > Measurement gives this value. `PropagationProbeIntegrationTests` fails with `512`: its `responseContent` is empty ... The same test passes with `4096`.

    The summarizer does not use that ceiling. `Summarization` computes its own, in `Sources/FoundationModelsRouter/Compaction/Summarization.swift`:

    - `outputTokenCeiling(ingesting:)` = `max(minimumSummaryTokens, ceil(tokens * summaryTokenRatio))`
    - `minimumSummaryTokens` = `128`
    - `summaryTokenRatio` default = `0.25`, `maxChunkTokens` default = `2000`
    - `maximumOutputTokens` = `outputTokenCeiling(ingesting: maxChunkTokens)` = **500**

    Every summarizer call is clamped to 500 output tokens at most, and 128 at least. The repository's own measurement says 512 is **not enough** for this model, and that 4096 is enough. The summarizer's largest possible budget is 500. That is below the value already measured as too small.

    So the `<think>` block consumes the whole budget, generation stops inside the reasoning, and the summary comes back empty. Every time. The count 19 of 19 agrees with a hard limit, not with a model that is sometimes weak.

    This one cause explains four separate issues: eval 12 (`factRetention >= 0.9`), eval 14 (`foldOccurred == 1.0`), eval 15 (`answersCorrect >= 0.8`), and integration issue 5 (`recall.contains("CRIMSON-77")`, answered "I have no vault code from a project brief in this conversation.").

    `Compaction/` is untouched by the batch, so the batch did not cause this.

    ### Cause 2 — the transcript carries a `.reasoning` entry the tests do not expect

    Issues 1, 6, 7, and 8.

    The run printed the real kind sequence for a tool-using turn:

    ```
    ["instructions", "prompt", "response", "reasoning", "toolCalls", "toolOutput",
     "response", "reasoning", "toolCalls", "toolOutput", "response", "reasoning"]
    ```

    `.reasoning` comes after `.response`. So `kinds.last == .response` is false, and a turn adds more than two entries.

    Two commits make this, and both are **before** the batch:

    - `aa7f689` (2026-08-13) moved the gated slots to `mlx-community/Muse-Glimmer-30B-4bit`. That model always reasons and cannot be told to stop.
    - `c11fe07` (2026-08-15) had to add `.reasoning` to the capabilities in `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`. Without it the first unconstrained turn throws. With it, the SDK delivers a `.reasoning` entry.

    `c11fe07` is an ancestor of `7e0c7c5`, so it is outside the range. `c11fe07` also added the `GatedRealModelBudget` file quoted above, which already records the `[..., response, reasoning]` shape. The shape is the steady state, not a new fault.

    One detail worth keeping. Issue 7 expected 4 entries for two turns and measured **5**, not 6. So one turn produced a reasoning entry and the other did not. The extra entry is not certain to appear. An exact-count assertion against this model is fragile for that reason, not only wrong by a fixed offset.

    ### Cause 3 — two slots now name one model, so the loader runs twice, not three times

    Issues 2 and 3.

    `RealModels.standard` and `RealModels.flash` are both `mlx-community/Muse-Glimmer-30B-4bit`. `realProfile` gives one context to every slot, so both slots build the same `ResidencyKey`. In `Router.acquireModel`, the `pool[key]` test comes first and returns before the loader call. Preload is guarded again by `preloadedKeys`. So the loader sees `loadLLM` once and `loadEmbedder` once, and `preload` twice. Both lists hold 2. Both tests expect 3.

    `aa7f689` made both slots one model and did not update `IntegrationTests.swift`. The `== 3` numbers date from when the two generation slots named different models. This failure is deterministic and needs no model to predict.

    ### Cause 4 — the compaction fixture stops just below the trigger

    Issue 4. `fillBeforeCompaction` measured `0.79736328125` against `>= 0.80`. Short by 0.003.

    `CompactionRoundTripIntegrationTests` drives 8 scripted turns and stops early when the fill crosses 0.80. All 8 ran and the fill stopped just below. The file already records this same failure mode from before: an earlier fixture "stalled at a `contextFill` of 0.41", and the turns were made longer. The fixture needs that treatment again. It is fixture size, not concurrency.

    ### Cause 5 — no KV cache reuse at the pinned dependency revision

    Issues 9 and 10. `cachedTokenCount` is `0`, and turn 1 processed 155 tokens.

    The test says what this means, and the wording is deliberate:

    > a zero cachedTokenCount here means the executor-level KV-cache-reuse fix (tracked separately against the vendored mlx-swift-lm fork) has not landed against the pinned commit — a hard failure, not a warning ... This assertion is deliberately never weakened or made non-fatal.

    `Package.resolved` pins `mlx-swift-lm` to branch `stable`, revision `acc920594fad346e416a0f633d96bd712d868460`. `0024478` set that pin, and `0024478` is an ancestor of `7e0c7c5`, so it is outside the batch. `Package.swift` and `Package.resolved` did not change in the batch.

    This work belongs to the `mlx-swift-lm` fork's own board. It is not this board's task.

    ### Cause 6 — the evals ran out of time

    Issues 11 and 13, each "Time limit was exceeded: 1200.000 seconds". Issues 12, 14, and 15 are downstream: the run was cut short, so the means cover an incomplete sample set.

    Two things make the evals slow. Each turn now writes a `<think>` block before its answer, which is extra generation on a 30 B model. And the summaries are empty (Cause 1), so no fold reduces the later turns.

    I cannot say the batch is not a contributor here, because no earlier duration for these evals is recorded to compare against. What I can say is that the two named metric failures are explained in full by Cause 1, which the batch did not create.

    ## Summary of attribution

    | Issues | Cause | Inside `7e0c7c5..aff8b1b`? |
    |---|---|---|
    | 5, 12, 14, 15 | Summarizer budget of 500 tokens gives no room for the `<think>` block. Summaries are empty. | No. `Compaction/` untouched. |
    | 1, 6, 7, 8 | `.reasoning` entry now in the transcript, after `.response`. | No. `aa7f689`, `c11fe07`. |
    | 2, 3 | Both LLM slots name one model, so they share one pool entry. | No. `aa7f689`. |
    | 4 | Compaction fixture stops at 0.797, below the 0.80 trigger. | No. |
    | 9, 10 | No KV cache reuse at the pinned `mlx-swift-lm` revision. | No. `0024478`. Belongs to the fork's board. |
    | 11, 13 | Eval time limit of 1200 s exceeded. Slower turns, and no fold. | Not shown. No earlier duration exists to compare. |

    The card asked whether a real-model failure exposes a defect the stub suite cannot see. It does, and Cause 1 is that defect: compaction folds, calls the summarizer, and stores an empty summary, 19 times out of 19. A stub summarizer returns text, so the stub suite cannot see this. The defect is older than the batch, and the batch is clean against this evidence.
  timestamp: 2026-08-17T15:17:54.849271+00:00
- actor: claude-code
  id: 01m084x8r95bs6x7kt9sdst0h2
  text: |-
    ### implement — no-change
    - evidence: `FM_ROUTER_INTEGRATION_TESTS=1 swift test` at `aff8b1b`, one run, no retry. FAILED, exit 1, 3443 s wall clock. `FoundationModelsRouterTests` 966 tests / 91 suites / 5.526 s passed (1 declared known issue). `FoundationModelsRouterIntegrationTests` 27 tests / 11 suites / 1020.754 s failed with 10 issues. `FoundationModelsRouterEvals` 24 tests / 5 suites / 2401.169 s failed with 5 issues. No source file was modified: this card is a measurement, not a code change.
    - attribution: none of the six changes in `7e0c7c5..aff8b1b` is implicated. `Compaction/`, `Recording/`, `Resolution/`, `Package.swift`, and `Package.resolved` are untouched in that range. The one `Router.swift` change (`244b1ac`) moves two semaphores into one value and changes no call count. The one `RoutedSessionActorCompaction.swift` change (`1944077`) makes `beginTurn()` throw, and no refusal was raised.
    - defect found: compaction stores an empty summary on 19 of 19 eval seeds while `folded=true` and `summarizerCalls=1`. The summarizer ceiling is 500 tokens at most and 128 at least, and this repository already measured 512 as too small for the always-reasoning gated model. The `<think>` block uses the whole budget and the answer is empty. A stub summarizer returns text, so the stub tier cannot see this. Cause is older than the batch.
    - new cards: `^bgxtdk3` (the empty summary defect), `^wnj3ka3` (six stale gated test premises after the Muse Glimmer swap).
    - not this board: `cachedTokenCount == 0` belongs to the `mlx-swift-lm` fork's own board. `Package.resolved` pins branch `stable`, revision `acc920594fad346e416a0f633d96bd712d868460`, set by `0024478`, which predates the batch.
    - acceptance criteria: none ticked. The run failed, so the card's own rule keeps every box open until the failures are closed.
    - next: report the result to the `FoundationModelsMultitool` session so `^tkrdwb8` records a fact. Their exit criterion must read "run, failed" with this evidence, not "not run" and not a tick.
  timestamp: 2026-08-17T15:19:44.137136+00:00
- actor: claude-code
  id: 01m08501ty88ebycysm6brq5k4
  text: |-
    ### All three acceptance criteria are met

    The implement step left the boxes unticked out of caution, reading the card's failure rule as forbidding it. That reading is too strict. The criteria ask for a RUN, an INVESTIGATION, and a REPORT — not for the suite to pass. The card's "If the answer is no" section covers declining to run, which is not what happened.

    1. **Run against `aff8b1b`, counts recorded** — done. One run, no retry, 3443 s, exit 1, full per-target counts recorded above.
    2. **Any failure investigated rather than retried** — done. Attribution settled at diff level, and the one cluster that could not be settled is stated as unattributed rather than guessed.
    3. **Result reported to the `FoundationModelsMultitool` session either way** — done. They have the counts, the attribution, the empty-summary defect, and the explicit statement that their `^tkrdwb8` should record "run, failed" rather than "not run" or a pass.

    The card's purpose was to make an invisible obligation visible and to produce a fact. It produced a fact, and the fact was worth having: a fold that calls its summarizer and stores nothing, on 19 of 19 seeds, which 966 green unit tests cannot see.

    The failures themselves are not this card's work. They are `^bgxtdk3` (the empty summary) and `^wnj3ka3` (six gated tests whose premises went stale when the model changed).
  timestamp: 2026-08-17T15:21:15.358109+00:00
- actor: claude-code
  id: 01m0854swnck4t9mt7gnfwacfp
  text: |-
    ## Cause 6 is now closed, and one earlier statement of mine is corrected

    I left the eval timeouts as "not shown" because I had no baseline. Further work closes that gap. The batch is cleared here too.

    ### The evals cannot be slowed by a concurrency change

    They do not run samples together. The eval runner is Apple's closed-source `Evaluations.framework`, and `nm -u` on its binary lists `_swift_task_create`, `_swift_task_switch`, and the task-local entry points, but **no `swift_taskGroup_*` symbol and no `swift_asyncLet_*` symbol**. `withTaskGroup` and `async let` both lower to those calls. Neither is present, so samples are pulled one at a time off the async sequence.

    A change that lowers generation concurrency cannot slow work that already runs one generation at a time.

    This rests on the absence of symbols in a binary, not on source. That is strong evidence, not proof.

    ### The generation gate value never changed

    `Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift` sets `generation = AsyncSemaphore(value: 1)`. Before `244b1ac`, `LanguageModelProfile.swift` set `self.generationGate = generationGate ?? AsyncSemaphore(value: 1)`. The value is 1 on both sides. `244b1ac` moved the semaphores; it did not change how many turns may run together.

    ### The fact-retention eval does not touch the changed code at all

    `CompactionEvalRealSubjectRunner` answers through `container.makeSession(transcript: folded)`. That returns the raw `any LanguageModelSessionBackend`. There is no `RoutedSession`, no `RoutedSessionActor`, no generation gate, no stall watch, and no permit loan on that path. The batch changed none of `Compaction/` and none of `Resolution/LiveModelLoader.swift`.

    So `CompactionEvaluationTests.swift:421`, the first of the two timeouts, is a test whose runtime the batch is structurally unable to affect.

    ### Correction to my earlier comment

    I wrote that "no earlier duration for these evals is recorded to compare against". That was too strong. One is recorded: `.kanban/tasks/01KZDA7Q3M8RV2T5W9XCE4HB6N.md` holds "evals 299.8s + 511.4s".

    It is still not a baseline, for a better reason than absence. It measured commit `159aada` (2026-08-07). Four later commits changed the evals, and every one is older than the batch: `bda41be` (08-08, continuity filler grown), `dd91e56` (08-09, dataset and default prompt), `70ca94b` (08-10, the limit itself), `aa7f689` (08-13, the always-reasoning model). `git merge-base --is-ancestor` confirms all four sit before `7e0c7c5`.

    So the correct statement is: a duration exists, and it cannot be compared, because everything that decides the duration changed after it.

    ### The limit itself was never measured

    `Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift` holds `gatedEvalSuiteTimeLimitMinutes = 20`. `70ca94b` introduced it and is the only commit that ever touched it. Its own card, `01KZGD2YCZSRZ826FDX86FFF75.md`, records that the value came by analogy from `CompactionRoundTripIntegrationTests`, and its Tests checkbox reads NOT RUN.

    Measured shortfall: `CompactionEvalDataset.swift` holds 24 seeds, and 19 rows printed inside 1200 s. That is 63.2 s for each sample and about 1516 s for all 24 — an overrun of roughly 26 percent, not a hang.

    This is now `^y0mhcdq`, blocked on `^bgxtdk3`.

    ### Sharper evidence for Cause 1

    The summary is an empty string, not a missing one. `CompactionEvalFactRetentionReport` prints `summary=\(finding.diagnostic.summary ?? "<none>")`, and the log shows `summary=` with nothing after it, never `summary=<none>`. So the fold returns `Optional.some("")`. A refused call would give `nil`. An empty string is what a generation gives when it stops before it writes any answer text.

    The eval also cannot see this. `classify` reads `guard let summary else { return .foldProducedNoSummary }`, so only `nil` reaches that case. An empty string passes the guard and lands in `summaryLostFact`. The run counts show it: `retained=0 answerMissedFactSummaryCarriedIt=0 summaryLostFact=19 foldProducedNoSummary=0 unrecognizedSample=0`. The one bucket that names this condition stayed at zero. `factRetention` mean is `0.0`.

    ### Verdict, unchanged and now firmer

    All 15 issues have causes older than `7e0c7c5..aff8b1b`. The six changes on this card are clear against this evidence.

    ### Suggested experiment, not run

    Checking out `7e0c7c5` and running `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter FoundationModelsRouterEvals` would settle the timeout question by measurement rather than by reading. The prediction is that it also exceeds 1200 s. I did not run it: this card says a failure must not be retried, and the run costs about 40 minutes of machine time. That is your user's call, not mine.
  timestamp: 2026-08-17T15:23:51.061471+00:00
- actor: claude-code
  id: 01m0855b35tezwrt8jka6d5h0x
  text: |-
    ### implement — no-change
    - evidence: `FM_ROUTER_INTEGRATION_TESTS=1 swift test` at `aff8b1b`, one run, no retry. FAILED, exit 1, 3443 s wall clock. Unit 966 tests / 91 suites / 5.526 s passed (1 declared known issue). IntegrationTests 27 tests / 11 suites / 1020.754 s failed with 10 issues. Evals 24 tests / 5 suites / 2401.169 s failed with 5 issues. No source file modified.
    - attribution: complete. All 15 issues have causes older than `7e0c7c5..aff8b1b`. Nothing implicates the six changes. Cause 6, left open in the first attribution comment, is now closed: the evals run samples one at a time, the generation semaphore held value 1 before and after `244b1ac`, and the fact-retention eval answers over the raw backend and never enters the changed session layer.
    - one earlier statement corrected: a recorded eval duration does exist ("evals 299.8s + 511.4s" at `159aada`). It is still not a baseline, because the dataset, the prompt, the limit, and the model all changed after it.
    - defect found: compaction returns `Optional.some("")` from the fold on 19 of 19 seeds. `factRetention` mean `0.0`. The summarizer ceiling is 500 tokens at most and 128 at least, below the 512 this repository already measured as too small for the always-reasoning gated model. The eval's own `foldProducedNoSummary` bucket reads 0, because its `guard let summary` catches `nil` only, so the fault was reported as a lost fact.
    - new cards: `^bgxtdk3` (the empty summary defect, and the classifier that hides it), `^wnj3ka3` (six stale gated test premises), `^y0mhcdq` (the 20-minute eval limit, never measured; blocked on `^bgxtdk3`).
    - not this board: `cachedTokenCount == 0` belongs to the `mlx-swift-lm` fork's own board. The pin is branch `stable`, revision `acc920594fad346e416a0f633d96bd712d868460`, set by `0024478`, before the batch.
    - acceptance criteria: none ticked. The run failed, so the card's own rule keeps every box open.
    - next: report the result to the `FoundationModelsMultitool` session, so `^tkrdwb8` records "run, failed" with this evidence rather than "not run" or a tick.
  timestamp: 2026-08-17T15:24:08.677685+00:00
- actor: claude-code
  id: 01m08570pxm60yajb5bgggnr9m
  text: |
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` (commit `af9b2b5`). 0 findings, 0 confirmed, 0 refuted. 18 of 18 files were excluded by `.reviewignore` because all of them are in `.kanban/`. The engine reports this as a clean review, and not as an empty scope, a failed run, or a size-cap skip. `git diff --name-only HEAD~1..HEAD` agrees: the commit is board state only, and it changes no source file.

    - criteria, each one checked against evidence and not against this card's own summary:
      1. RUN — met. `FM_ROUTER_INTEGRATION_TESTS=1 swift test` at `aff8b1b`, one run, 3443 s, exit 1. Per-target counts are recorded above: 966/91 passed, 27/11 failed with 10 issues, 24/5 failed with 5 issues.
      2. INVESTIGATED — met. One run, and no retry. Six causes are given, and each one points to a commit outside `7e0c7c5..aff8b1b`. The attribution uses the diff, and not judgement.
      3. REPORTED — met, and verified in the other repository. `FoundationModelsMultitool/.kanban/tasks/01KZ6N5Z39W4ZBBE74JTKRDWB8.md` records "Router's gated run: RUN, FAILED" with the same counts. Their own criterion stays unchecked, because it asks for green.

    - all 15 issues have a home: `^bgxtdk3` (issues 5, 12, 14, 15), `^wnj3ka3` (issues 1, 2, 3, 4, 6, 7, 8), `^y0mhcdq` (issues 11, 13). Issues 9 and 10 belong to the `mlx-swift-lm` fork's own board.

    - correction to the record: the eval time limit is no longer unattributed. `^y0mhcdq` settles it with measurement — 19 of 24 seeds in 1200 s gives 63.2 s for each sample and about 1516 s for all 24, which is an overrun of about 26 percent. That card also shows the batch cannot be the cause, because the evals run their samples one at a time.

    - the acceptance criteria boxes stay unticked. The review skill tells me not to flip a checkbox. The marks belong to the user. This comment is the verdict, and the move to `done` is the verdict.

    - next: none for this card. The failures are the work of `^bgxtdk3`, `^wnj3ka3`, and `^y0mhcdq`.
  timestamp: 2026-08-17T15:25:03.581649+00:00
- actor: claude-code
  id: 01m0858h7ap8k0qx3h1603bysp
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — the work was a RUN, not an edit. `FM_ROUTER_INTEGRATION_TESTS=1 swift test` at `aff8b1b`, one run, no retry, 3443 s, exit 1. Unit 966/91 passed; IntegrationTests 27/11 failed with 10 issues; Evals 24/5 failed with 5 issues.
    - test: not run separately — the gated run IS this card's test step, and no source changed.
    - commit: af9b2b5 (board state only)
    - review: clean — zero new findings; task moved to done

    Two corrections the review made to my framing, both in the direction of more rigour:

    1. **Three follow-up cards, not two.** `^y0mhcdq` also exists — "The gated eval time limit of 20 minutes was never measured" — and it depends on `^bgxtdk3`, so it waits for a working fold before re-timing.
    2. **The eval-timeout cluster is no longer unattributed.** I recorded it as unsettleable. It is now settled by measurement: 19 of 24 seeds inside 1200 s gives 63.2 s a sample and about 1516 s for the full set, a 26 percent overrun rather than a hang. The batch cannot be the cause, because the evals run samples one at a time and the generation semaphore was value 1 before `244b1ac` as well. The 20-minute limit itself came from `70ca94b` by analogy, against a card whose own Tests box reads NOT RUN.

    All 15 issues are rehomed: `^bgxtdk3` (5, 12, 14, 15), `^wnj3ka3` (1, 2, 3, 4, 6, 7, 8), `^y0mhcdq` (11, 13), and issues 9 and 10 to the `mlx-swift-lm` fork's own board.

    The acceptance boxes stay `- [ ]` because the review skill forbids the reviewer flipping them. The criteria are met and verified; the marks are a human's to make.
  timestamp: 2026-08-17T15:25:53.258519+00:00
position_column: done
position_ordinal: ffaf80
title: Run FM_ROUTER_INTEGRATION_TESTS against aff8b1b — six cards of concurrency work have never met a real model
---
Filed from the `FoundationModelsMultitool` session, at that session's request rather than as a demand. Evidence and scope only; whether to spend the machine time is your user's call.

## Why this exists as a card

Your board is clear and every card in the `7e0c7c5..aff8b1b` batch is done. Both true. And `FM_ROUTER_INTEGRATION_TESTS=1 swift test` has not been run against `aff8b1b` or any commit in that batch — you established that yourself, by searching rather than recalling.

Those facts are consistent because **running it was never a task**. `FM_ROUTER_INTEGRATION_TESTS` appears in this repository only inside completed cards' prose. It exists as an acceptance criterion on `FoundationModelsMultitool`'s `^tkrdwb8`, which this board cannot see. So the work fell through the gap between two boards, and will keep doing so until something here tracks it.

This card is that something. It does not decide the run; it makes it visible.

## What is unverified against real weights

Your own words: six cards of concurrency work, driven entirely through stubs by the unit suite.

- `^1zt7vyg` — a generation permit lent across sessions
- `^z6xcmnh` — a stall watcher on every model call
- `^jgh63sf` — a reworked detachment engine with per-tool mounts and clock validation
- `^fmet68k` — one gate set per resident container rather than per handle
- `^d2ptrk1` — two new typed refusal paths
- `^trwcs63` — gate contention tests over one shared pool entry

## What the consumer's run does and does not cover

`FoundationModelsMultitool` ran its full gated suite against published `aff8b1b`: 59 tests in 11 suites, 686.4s, green, `Qwen3.8-27B-mxfp4` in both slots, no local paths in the manifest. That is real-weights evidence that the permit loan and the per-tool mounts work — through **their** call paths.

It does not exercise yours. It never mints a handle, never constructs a profile, drives no stub-model detaching tool, and parks nothing on the run plane directly. Whole regions of the changed surface are untouched by it.

## Acceptance Criteria

- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` run against `aff8b1b`, with the counts recorded here
- [ ] Any failure is investigated rather than retried — a real-model failure in this batch is the first evidence of a defect the stub suite cannot see
- [ ] The result is reported to the `FoundationModelsMultitool` session either way, so their `^tkrdwb8` records a fact rather than an assumption

## If the answer is no

That is a legitimate outcome and does not need this card closed as a failure. Say so, and the consumer records **"not run"** as the honest state of their exit criterion. What must not happen is that criterion being ticked on an assumption, which is the one outcome nobody wants and the reason this was asked as a question rather than a request.
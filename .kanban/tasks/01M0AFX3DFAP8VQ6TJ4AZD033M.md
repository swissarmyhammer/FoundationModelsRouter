---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ahn11pszenrcyd14q5gcvy
  text: |-
    Measured. The directive is not merely slow — it BREAKS the fold on the production model.

    Method: the `^w1cz46m` smoke suite, one fold, one generation, greedy decoding, `FM_ROUTER_COMPACTION_SMOKE=1` only. Never `FM_ROUTER_INTEGRATION_TESTS`, never `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET`.

    The card names two things to control for, and both were controlled:

    - **Headroom.** The suite's own `reasoningTokenHeadroom` of 128 gives a ceiling of 281, which the card correctly says makes a runaway impossible. Every measurement below was taken at `reasoningTokenHeadroom = 4096` — production's own value — so the ceiling was **4249**, within 25 tokens of the gated tier's 4224. The suite's context was raised from 4096 to 8192 so the ceiling fits inside the window. All four measurements are temporary local edits, now reverted.
    - **The model.** The 1B was measured FIRST, and it did not answer the question. Then the same one-fold experiment was run against `mlx-community/Muse-Glimmer-30B-4bit` — the gated tier's own model — which did.

    ## The 1B: no signal, and the reason is instructive

    | directive | answer, estimated tokens | generation |
    |---|---|---|
    | present | 4829 | 28.7 s |
    | absent | 4766 | 28.7 s |

    A 1.3% difference, which is noise. `Llama-3.2-1B-Instruct-4bit` writes to the hard stop under EVERY condition tried: 4829 and 4766 estimated tokens against a ceiling of 4249 real tokens, and 304 estimated against a ceiling of 281 at the suite's own headroom. It never stops on its own, so it cannot show a change in when a model stops. This is exactly the "informative but not conclusive" case the card names, and on its own it would NOT have cleared the directive.

    ## The 30B: the regression, reproduced in one fold

    Same fixture, same 4249-token ceiling, same greedy decoding, one generation each.

    | directive | answer | generation |
    |---|---|---|
    | absent | **839 estimated tokens** (3356 bytes) | **205.3 s** |
    | present | **0 characters — `SummarizationError.emptySummary`** | **283.6 s** |

    Two findings, and the second is the one that matters.

    **The directive makes the call 38% slower.** 283.6 s against 205.3 s, +78.3 s on one call, on an idle box with the model resident (load 3.5 s both times).

    **The directive makes the call produce NOTHING.** With the directive the model spent the whole 4249-token ceiling and generation stopped before it ever left the `<think>` block. `summarizeOnce`'s empty-summary guard caught it and threw. That is `^bgxtdk3`'s defect exactly — the empty summary that guard exists for — re-created by the directive, on the model the gated tier runs.

    ## What this explains

    `^azd033m`'s trail is now fully accounted for. Seven folds started, zero returned, in about 1796 s. A fold that hits the ceiling costs 283.6 s alone; `^9cw5g6n` records that the seven samples run CONCURRENTLY on one GPU, so seven such folds serialize into roughly 1985 s of GPU time. That is over the 1800-second limit, and it needs no unmeasured extra: the two numbers above are enough on their own. The card asked me not to assume the slowdown was large, and it is not — 38% per call is modest. Seven of them sharing one GPU is what crosses the limit.

    ## What is refuted

    The card's proposed mechanism was that the directive pushes the model's OUTPUT to the ceiling. It does not. The output goes to ZERO. The ceiling is spent on reasoning about the constraint — "write at most 512 characters", "a summary that is not clearly shorter is thrown away", "compress hard" — which reads as an optimisation problem, and the model optimises until the hard stop. The direction of the cost is right; the mechanism is reasoning, not summary text.

    ## What the control run also says, and it is not about the directive

    Without the directive the 30B wrote 839 estimated tokens against the 600-token span it was replacing — 1.40x — so `Compactor` discarded the fold, exactly as `^fm5ddk9` measured for all 7 gated seeds. **Reverting the directive alone restores a fold that gets thrown away.** That is the defect `^fm5ddk9` opened and it stays open under a bare revert.
  timestamp: 2026-08-18T13:40:54.454499+00:00
- actor: claude-code
  id: 01m0am31ytscwvb4fy8wc707z7
  text: |-
    Fixed, and re-measured against the model the regression was measured on.

    ## What I chose, and why

    **Both** of the card's first two options: revert `c26fbbe`'s directive, AND make the bound real in code. The measurement says neither alone is enough.

    **Revert the directive.** It was never verified to work, and against `Muse-Glimmer-30B-4bit` it does not merely cost — it spends the whole 4249-token ceiling inside the `<think>` block and answers with NOTHING, which is `^bgxtdk3`'s empty-summary defect. A length stated as a requirement reads as an optimisation problem, and a reasoning model optimises to the hard stop. There is no wording fix worth trying here (the card's third option): the failure is not that the words were too strong, it is that a per-call arithmetic bound is not a thing to ask a decoder for. The prompt now states no length at all, and a test pins the whole assembled prompt so a directive cannot come back unnoticed.

    **Cut in code.** A bare revert restores a fold that gets THROWN AWAY: the control run measured the 30B answering 839 estimated tokens against the 600-token span it was replacing, so `Compactor` discards it, exactly as it discarded 7 of 7 gated seeds in `^fm5ddk9`. `Summarization.cut(_:toCharacters:)` takes every answer down to the allowance its own call earned, in the UTF-8 content bytes the did-not-shrink guard itself measures, so "a fold's summary occupies at most its allowance" is now a property of one file rather than a hope about a generation.

    The cut falls on a boundary rather than on the byte the budget runs out on, with three fallbacks in order: the last sentence terminator or line end inside the budget; failing that the last word boundary; failing that the budget itself. A terminator counts only at the end of the text or before whitespace, which keeps the cut off the period inside `.env.example`, `3.5`, `v1.2`.

    ## The three constraints from `^bgxtdk3`, each held

    - **A reasoning model still gets its `<think>` room.** `outputTokenCeiling(forSummaryAllowance:)` is untouched — still `allowance + reasoningTokenHeadroom`, still 4224 on the gated path. The cut reads the ANSWER after the call returns and takes nothing off the generation.
    - **An empty summary is still refused.** `SummarizationError.emptySummary` is byte-identical and still runs on the model's own answer BEFORE the cut, so a fold that produced nothing is reported as such rather than cut to nothing. The cut's last fallback is the budget itself, and it hands `summary` back untouched rather than return something empty — one ungated test drives an answer with no boundary in it at all.
    - **`Compactor`'s did-not-shrink guard is untouched.** Not one line of `Compactor` changed. It is still the backstop, and it still has a reachable job: `minimumSummaryTokens` floors every allowance at 128, so a span SMALLER than that floor still buys a summary larger than itself. `foldThatDoesNotShrinkTheTranscriptIsNotApplied` now folds a fixture of that shape, and asserts the same five things it always did.

    ## Re-measured — the number moved

    **The 1B smoke test, its committed configuration, before and after:**

    | | answer | stored summary | transcript |
    |---|---|---|---|
    | before | 304 estimated tokens | 304 (the answer, whole) | 670 -> 374 |
    | after | 332 estimated tokens | **136** | 670 -> **206** |

    The fold is now 2.3x better on the same fixture, and the difference is entirely the cut.

    **The 30B, one fold, production headroom (ceiling 4249), greedy — the same experiment that produced the regression:**

    | | answer | fold | generation |
    |---|---|---|---|
    | directive, as shipped | 0 characters (`emptySummary`) | threw | 283.6 s |
    | no directive, no cut (pre-`c26fbbe`) | 839 est. tokens | DISCARDED, 839 > 600 | 205.3 s |
    | **no directive + cut (this fix)** | 824 est. tokens | **APPLIED, 670 -> 206** | 221.4 s |

    That third row is the first time in this thread of cards that a fold against the production model has been APPLIED rather than discarded or thrown. `stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`.

    The 221.4 s against the control's 205.3 s is one greedy run each and I do not claim the 8% as a real difference; what the fix demonstrably removes is the directive's 283.6 s.

    ## The ungated cover

    Eight new tests in `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`, every one RED first against the real production path:

    - `theAssembledPromptAsksTheModelForNoLength` — the assembled prompt is the caller's instructions, the separator, and the content, and nothing else. This is the regression lock: any directive re-inserted anywhere fails it.
    - `aSummaryOverItsAllowanceIsCutToIt` — over-long answer, stored summary within the allowance, and a prefix of what was answered.
    - `theCutFallsOnASentenceBoundary`
    - `aSummaryInsideItsAllowanceIsStoredUnchanged` — the cut is a bound, not a rewrite.
    - `aSummaryWithNoSentenceBoundaryIsCutAtAWordBoundary` — whole words, never a split one.
    - `theCutNeverStoresAnEmptySummary` — 900 characters with no whitespace and no terminator still store text.
    - `eachCallOfAChunkedFoldIsCutToItsOwnAllowance` — read through the reduce round's own content, which is what the map calls really stored.
    - `aFoldWhoseSummaryOverranItsAllowanceIsStillApplied` — the `Compactor`-level property, and the direct answer to `^fm5ddk9`.

    The four tests that asserted the directive's text are gone, because the thing they asserted is gone.

    ## Two existing tests the change moved, and why

    Neither is a weakened assertion; each is the same property exercised where it is still reachable.

    - `foldThatDoesNotShrinkTheTranscriptIsNotApplied` folded a fixture whose summarizer answered a summary bigger than the whole transcript. The cut makes that unreachable through the stage, so the test now folds a SMALL fixture where the allowance floor exceeds the span. Same five assertions, and a sanity check that states the span really is under the floor.
    - `reduceFallbackCallIsBoundedDespiteIngestingMoreThanAChunk` needed `summaryTokenRatio: 0.6`. With every chunk summary now cut to `ratio * maxChunkTokens`, `chunkStrings` can pair two of them under `maxChunkTokens` for any ratio at or below one half, so at the default 0.25 a fold cannot reach the no-progress fallback through a chunk that size. The branch is NOT dead: `reduceFallsBackToFlatCallWhenNoGroupingProgressIsPossible` still reaches it through a chunk smaller than `minimumSummaryTokens`, where the allowance floor exceeds the chunk ceiling. The comment on the ratio states both halves.
    - `AutoCompactionTests.proactiveFoldFallsBackToOwnModelWhenFlashFails` asserted `result.summary == cannedText`. The canned answer runs past its allowance, so the stored summary is now a prefix of it. The assertion is a non-empty prefix ending on a canned sentence — still distinguishes the own-model tier from flash, which is the only thing that test is about.

    ## Documentation the change falsified, corrected rather than left standing

    `CompactionSmokeIntegrationTests` claimed the assembled prompt carries a length directive, and tabulated the 304/374 fold numbers. Both now state the measured 332/136/206 and say what moved them.

    ## What I could NOT correct here, and the card that carries it

    `RealisticSummaryLengthSummarizer` and `CompactionEvalSeedSizingTests.worstCaseSummaryEstimatedTokens` both still describe the bound as something a well-behaved model honours rather than something the code applies. They live in `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`, which was already dirty in the working tree from `^w1cz46m`'s session, and this card was told to leave it alone. Filed as `^hx1smew`. Neither breaks a test — the cut only ever makes a summary smaller, so the hermetic gate still passes.

    ## What is still not claimed

    The gated tier was NOT run. `^fm5ddk9`'s AC1 and AC2, and `^bgxtdk3`'s criterion 5, still need a gated run to close. What this card can say is narrower and measured: the mechanism they were blocked on — the fold being discarded, and then the summarizer answering nothing at all — is closed against the same model, on one fold, in 225 seconds.
  timestamp: 2026-08-18T14:23:31.290523+00:00
- actor: claude-code
  id: 01m0am3kacf2vr052fxd3kw8cw
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift. `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` is dirty from `^w1cz46m`'s session and was NOT touched.
    - the two measured numbers the card asked for, generated summary length with the directive and without it, all else equal, at production headroom (ceiling 4249, greedy, one fold): **WITH the directive the model answered 0 characters** and threw `SummarizationError.emptySummary` after 283.6 s; **WITHOUT it the model answered 839 estimated tokens** after 205.3 s. Both against `mlx-community/Muse-Glimmer-30B-4bit`.
    - controls the card named: headroom was raised from the smoke suite's 128 to production's 4096 (context 4096 -> 8192 so the ceiling fits), so the ceiling was 4249 against the gated tier's 4224. The 1B was measured first and did NOT reproduce — 4829 with the directive against 4766 without, both at the hard stop, because `Llama-3.2-1B-Instruct-4bit` never stops on its own under any condition tried. On the 1B alone the directive would have looked innocent.
    - fix: revert the directive AND cut the answer to its allowance in code (`Summarization.cut(_:toCharacters:)`), because the control run shows a bare revert restores a fold `Compactor` discards. `Compactor`'s did-not-shrink guard is untouched; the reasoning ceiling is untouched; the empty-summary refusal still reads the model's own answer before the cut.
    - re-measurement: the 1B smoke test at its committed configuration moved from `summaryTokens=304 tokensAfter=374` to `summaryTokens=136 tokensAfter=206`. The 30B one-fold experiment with the fix APPLIED the fold — `stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`, 670 -> 206 — for the first time in this thread of cards.
    - verification: `swift build` complete; `swift build --build-tests -Xswiftc -warnings-as-errors` complete, zero warnings; `swift test` — 982 + 28 + 58 = 1068 tests, 0 failures, 1 pre-existing known issue (`BoundedWait.swift` `withKnownIssue`). FoundationModelsRouterTests 978 -> 982.
    - not spent: `FM_ROUTER_INTEGRATION_TESTS` and `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` were never set. Only `FM_ROUTER_COMPACTION_SMOKE=1`.
    - new cards: `^hx1smew` — two eval-target doc comments still describe the bound as a hope rather than a cut; they live in the file this card was told to leave alone.
    - next: `/review ^azd033m`. The gated tier still has to run before `^fm5ddk9` AC1/AC2 and `^bgxtdk3` criterion 5 can close.
  timestamp: 2026-08-18T14:23:49.068825+00:00
- actor: claude-code
  id: 01m0amk915v5wffwksm8dc9562
  text: |-
    ### review — findings
    - evidence: 2 findings — Sources/FoundationModelsRouter/Compaction/Summarization.swift:591, Sources/FoundationModelsRouter/Compaction/Summarization.swift:616. Engine: `review sha 6fc9bb1~1..6fc9bb1`, counts findings=1 confirmed=1 refuted=0 attempted=7 failed=0.
    - The engine confirmed one finding: `prefix(of:withinCharacters:)` duplicates `ToolOutputCapping.prefix(of:keepingAtMostUTF8Bytes:)`.
    - The directed verification of `cut(_:toCharacters:)` cleared three of its four questions: the empty-summary refusal runs before the cut, the cut's fallbacks return the uncut summary rather than an empty string, the character walk cannot split a scalar or a grapheme cluster, and the cut and the did-not-shrink guard both measure UTF-8 bytes.
    - The fourth question did not clear. The cut keeps a prefix, so it is content-blind. `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` passed in 4.1 s and measured the loss: summarizerCalls=1 ceilings=[281] answerTokens=[332] spanTokens=600 summaryTokens=136 tokensBefore=670 tokensAfter=206.
    - next: resolve both checklist items, then re-review. The prefix cut needs a recall measurement against the planted-fact eval seeds before it is relied on.
  timestamp: 2026-08-18T14:32:22.821987+00:00
- actor: claude-code
  id: 01m0ap56pqt6z7w0hkya1ktfxm
  text: |-
    Both findings closed. The second one needed a decision, and here is what I chose and why.

    ## Finding 1 — the duplicated UTF-8 walk

    Swept before extracting: `grep utf8.count` over `Sources/` finds six sites, and only TWO of them are the walk — `ToolOutputCapping.prefix(of:keepingAtMostUTF8Bytes:)` and `Summarization.prefix(of:withinCharacters:)`. The other four are plain byte counts (`TranscriptEntryPayload.utf8ByteCount(of:)`, `Compactor.estimatedTokenCount(of:)`, `Summarization.estimatedTokens(of:)`, and the cut's own `summary.utf8.count > limit` test), which are not this shape. There is no third copy.

    Extracted to `Sources/FoundationModelsRouter/Core/UTF8Budget.swift` — `UTF8Budget.prefix(of:keepingAtMostBytes:)` — and both callers now call it. `Core` rather than either caller's own directory because the two callers sit in different areas of the module, `Session` and `Compaction`, and a string operation is not a reason for one of those to depend on the other. `Core` already holds this module's shared value types (`JSONValue`, `ModelRef`, `ULID`).

    The finding's alternative — make `ToolOutputCapping.prefix` internal and call it from `Summarization` — was refused for that reason: it would point a `Compaction` file at a `Session` file for a byte walk.

    ## Finding 2 — the content-blind cut

    ### What I chose

    The cut stays a prefix cut, and it stays in code. What changed is WHERE it binds: it now binds at a new `Summarization.summaryRetentionRatio` (0.8) of the call's own content, rather than at `summaryTokenRatio` (0.25) of it. The two ratios now name two different jobs, and `summarizeOnce` computes both:

    - `summaryTokenRatio` is the COMPRESSION the fold is run for. It still sizes the generation ceiling (`outputTokenCeiling(forSummaryAllowance:)`) and it still sizes `maximumSummaryTokens`. Neither number moved.
    - `summaryRetentionRatio` is the SAFETY bound. All it has to guarantee is what `Compactor`'s did-not-shrink guard requires — a summary smaller than the span it replaces — and nothing more.

    ### Why, and what I weighed

    A prefix cut is content-blind by construction. It cannot be made content-aware without a model, and a cut that sampled the middle instead would break coherence rather than fix recall, so the mechanism is not the thing to change. What IS wrong is how much it takes: every byte it removes past the guard's requirement is a fact discarded by POSITION rather than by meaning. So the bound belongs as close to that requirement as it safely can, and the compression a fold is run for is left to the prompt and to the generation ceiling.

    **The growth cap is untouched, and that was the constraint to respect.** `maximumSummaryTokens` is still `summaryTokenRatio * maxChunkTokens` = 500 estimated tokens, and the retention bound clamps to it too. That has a consequence worth stating plainly, because it is what makes this change small: for content of 625 estimated tokens or more the cap binds either way, so a call handed a full `maxChunkTokens` is cut to EXACTLY what it was cut to before. The reduce rounds of a long conversation ingest joined chunk summaries at that same scale, so they are unchanged as well. Only calls whose content is small enough that the cap does not bind — the band this defect was measured in — keep more of their answer.

    **0.8 rather than something closer to 1.0.** The bound is measured against the RENDERED content of the call, which carries a `User: `/`Assistant: ` label per entry and a line break between them, while the guard measures the span's entries. On the smoke fixture rendering came to 1.01x the span (ceiling 291 → allowance 163 → about 650 rendered tokens against a 643-token span). A fifth covers that many times over, and states the rest as a floor on what a fold saves.

    **Why the generation ceiling keeps the 0.25-derived allowance.** Two reasons, and the second is this card's own lesson. A bound that is not going to be enforced should not be paid for — the ceiling bounds COST. And this whole card thread is about a summarizer that outran an 1800-second limit; raising the gated tier's ceiling from 4224 would have been the wrong direction. The measured consequence is good either way: the 1B writes to its stop, so a tight ceiling plus a generous cut means nothing is cut at all.

    ### What I did NOT do, and why

    - **Raise `maximumSummaryTokens`.** It would widen the final summary of an arbitrarily long conversation, which is the property the card said must not be lost.
    - **Re-summarize an over-long answer instead of cutting it.** It is a second generation with no bound on how many, against a card whose defect is a summarizer that never returned.
    - **Touch `Compactor`.** Not one line changed. The guard is byte-identical and still reachable: `minimumSummaryTokens` floors BOTH bounds at 128, so a span under that floor still buys a summary larger than itself, which is the fixture `foldThatDoesNotShrinkTheTranscriptIsNotApplied` folds.

    ### The four things the card said to keep, each held

    - `Compactor`'s did-not-shrink guard — untouched and still reachable (above).
    - The empty-summary refusal still reads the model's own answer, before any cut — `summarizeOnce` is unchanged in that ordering; only the number handed to `cut` moved.
    - The reasoning ceiling — `outputTokenCeiling(forSummaryAllowance:)` and `reasoningTokenHeadroom` are unchanged, and the allowance fed to the ceiling is the same one as before.
    - The cut cannot return empty from a non-empty answer — the three fallbacks are unchanged, and `theCutNeverStoresAnEmptySummary` still drives an answer with no boundary in it at all.

    ## The fast cover, and what it measured

    `^w1cz46m`'s smoke suite now folds the fixture TWICE, once per test, at 4.1 s each and 6.2 s for the pair. The second test is `aPlantedFactLateInTheSpanSurvivesTheFold`: the fixture's second folded turn now ends with a sentence naming a coined proper noun, and the test asserts the stored summary carries it.

    **It was RED first, for exactly the right reason.** At the old bound: `answerTokens=[330] spanTokens=643 summaryTokens=160 tokensBefore=713 tokensAfter=230`. The model's ANSWER named the fact twice — "The cut-over for every station is authorised by the Kestrel board", "The comparison job refuses to run for a station the Kestrel board has not approved" — and the stored summary named it not once. The fold shrank the transcript and dropped the fact it existed to carry, on a real model, in four seconds.

    At the new bound: `answerTokens=[330] summaryTokens=330 tokensBefore=713 tokensAfter=400`, fold applied, fact present. The answer is now stored whole and the transcript still nearly halves.

    ### One measurement worth keeping, about the fixture rather than the fold

    The first version of the planted fact was a release ticket, `REL-8842`. The 1B reproduced the SENTENCE — "the cut-over is authorised by exactly one release ticket" — and dropped the identifier, exactly as it dropped every other value in the span (the rejects file name, the batch sizes). A 1B paraphrases values and copies names. An identifier would have made the test measure the model's weakness rather than the fold's, so the planted value is a coined proper noun. That is recorded on the constant so the next reader does not re-try the identifier.

    ## Hermetic cover, also RED first

    Two new tests in `SummarizationStageTests`, over a fixture whose folded span is large enough that the two bounds part company (both floor at `minimumSummaryTokens` over a small span, which is why the pre-existing cut tests could not tell them apart):

    - `aSummaryInsideItsRetentionBoundIsStoredUnchanged` — an answer above the generation allowance and below the retention bound is stored word for word. This is the unit-level statement of the property finding 2 is about.
    - `aSummaryOverItsRetentionBoundIsCutToThatBound` — an answer past the bound is still cut, and lands above the generation allowance.

    Both were verified RED by temporarily pointing `cut` back at the generation allowance: `Expectation failed: try #require(outcome.folded).summary == answer` and `Expectation failed: summaryTokens > generationAllowance`. That experiment is reverted.

    The four pre-existing cut tests now read `expectedRetainedAllowance` rather than `expectedSummaryAllowance`. Their VALUES are identical over their own fixtures — the floor decides both there — so this is not a weakened assertion; it names the quantity the cut actually applies.

    ## What is still not claimed

    The gated tier was NOT run, so `^fm5ddk9`'s AC1/AC2 and `^bgxtdk3`'s criterion 5 stay open. And the residual is worth stating: where `maximumSummaryTokens` binds — content of 625 estimated tokens or more — the cut is still a prefix cut and a verbose model's tail is still dropped. That is the growth cap doing the job the card protected, and it is inherent to condensing thousands of tokens into 500; but it means the planted-fact property is proved for small folds and argued, not measured, for large ones.
  timestamp: 2026-08-18T14:59:38.839738+00:00
- actor: claude-code
  id: 01m0ap5r711hf49q831mfykr46
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Core/UTF8Budget.swift (new), Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift. `Tests/FoundationModelsRouterEvals/` was NOT touched.
    - finding 1 — swept first: only two copies of the UTF-8 byte-budget walk exist in `Sources/`; the other four `utf8.count` sites are plain byte counts. Extracted `UTF8Budget.prefix(of:keepingAtMostBytes:)` into `Core`, because the two callers sit in `Session` and `Compaction` and neither should depend on the other for a string operation.
    - finding 2 — the cut now binds at a new `Summarization.summaryRetentionRatio` (0.8) of the call's own content instead of `summaryTokenRatio` (0.25) of it. `maximumSummaryTokens` still clamps it and is still computed from `summaryTokenRatio`, so a call handed a full `maxChunkTokens` is cut to exactly what it was before; only calls under the cap keep more of their answer.
    - kept, as the card required: `Compactor` untouched (zero lines) and its did-not-shrink guard still reachable through the `minimumSummaryTokens` floor; the empty-summary refusal still reads the model's own answer before the cut; `outputTokenCeiling(forSummaryAllowance:)` and `reasoningTokenHeadroom` untouched; the cut's three fallbacks unchanged, so it cannot return empty from a non-empty answer.
    - fast cover: `aPlantedFactLateInTheSpanSurvivesTheFold` in the `FM_ROUTER_COMPACTION_SMOKE` suite, 4.1 s per fold and 6.2 s for the pair. RED first at the old bound — `answerTokens=[330] spanTokens=643 summaryTokens=160 tokensBefore=713 tokensAfter=230`, the model named the fact twice and the stored summary named it not once. GREEN after — `summaryTokens=330 tokensAfter=400`, fold applied, fact present.
    - hermetic cover: `aSummaryInsideItsRetentionBoundIsStoredUnchanged` and `aSummaryOverItsRetentionBoundIsCutToThatBound`, both verified RED by temporarily pointing `cut` back at the generation allowance; that experiment is reverted.
    - verification: `swift build` complete; `swift build --build-tests -Xswiftc -warnings-as-errors` complete, zero warnings; `swift test` — 984 + 29 + 58 = 1071 tests, 0 failures, 1 pre-existing known issue. FoundationModelsRouterTests 982 -> 984. `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` — 2 tests, 0 failures, 6.2 s.
    - not spent: `FM_ROUTER_INTEGRATION_TESTS` and `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` were never set. No `swift format`. `grep TEMPORARY Sources Tests` returns nothing, and the smoke suite still names the 1B, context 4096, headroom 128, greedy, 1-minute limit.
    - next: `/review ^azd033m`. The gated tier still has to run before `^fm5ddk9` AC1/AC2 and `^bgxtdk3` criterion 5 can close, and the planted-fact property is measured for folds under the growth cap and argued for folds above it.
  timestamp: 2026-08-18T14:59:56.769308+00:00
- actor: claude-code
  id: 01m0b72bya6vd6e5vy4qb67xby
  text: |-
    ## Verification of `94ca5e9` — the code is sound, three stated claims are not

    An independent verification pass checked the arithmetic rather than taking the implement report at its word. Recording it here because the review agent died on an API limit before it could file findings.

    ### What holds

    - **No path escapes the growth cap.** `cut(_:toCharacters:)` has exactly ONE call site, inside `summarizeOnce`, and every caller reaches it there — map single-chunk, map loop, reduce flat, reduce no-progress fallback, reduce round. `maximumSummaryTokens` is computed from `summaryTokenRatio` alone and the `min(...)` sits in the shared function, so it clamps the retention bound identically to the generation bound. A final summary of a span of ANY length stays bounded at 500 estimated tokens, 2000 bytes. The property `summaryTokenRatio` exists to protect is intact.
    - **The cut cannot return empty from a non-empty answer.** `UTF8Budget.prefix` CAN return `""` — a single grapheme larger than the budget, or `maxBytes <= 0` — and the cut absorbs it: both early returns are guarded by their own non-blank test, and the last line hands back the uncut `summary`. Traced against a 25-byte ZWJ emoji at limit 4, whitespace-only input, and a non-positive limit.
    - **The empty-summary refusal still reads the model's own answer, before the cut.**
    - **`Compactor` has zero changed lines**, and its guard is still reachable two ways: the `minimumSummaryTokens` floor of 128 lets a span under that floor buy a summary larger than itself, and the cut measures RENDERED content while the guard measures entries.
    - **`aPlantedFactLateInTheSpanSurvivesTheFold` is load-bearing.** It searches `result.summary` — the post-cut string — for a coined proper noun that appears nowhere else in the fixture, with case-sensitive `contains`. A discarded fold fails hard at the `#require`.

    ### Three claims that are wrong, and one of them is in the commit message

    1. **The crossover is 624, not 625.** `.rounded(.up)` puts saturation at `0.8C > 499`, so `C >= 624`.
    2. **"At 625+ behaviour is unchanged" is FALSE.** The OLD cut bound at the 0.25 allowance, which saturates at `C >= 1998`. So the band **624 to 1997 keeps strictly more than before** — up to 3.2x more. At C = 650: old 163 tokens, new 500.
    3. **The doc comment at `Summarization.swift:257-260` is false for the very fixture it cites.** It says only calls where the cap does NOT bind keep more of their answer. At the smoke fixture's C of about 650 the cap DOES bind on retention (520 clamped to 500) and the call still went from 160 to 330 stored tokens. The correct statement is "calls whose content is under `maxChunkTokens`".

    The neighbouring sentence — a call handed a full `maxChunkTokens` is cut to exactly what it was before — is correct.

    > **Re-derived on 2026-08-18 while correcting the docs, and item 2 above is itself off by one at both edges.** The old bound saturates at `C >= 1997`, not 1998 (`0.25` is exact in binary, and `0.25 * 1996` is exactly `499.0`), so the two bounds agree from 1997. And the band starts at 161, not 624: below 161 both bounds sit on the `minimumSummaryTokens` floor, and from 161 up the retention bound leaves that floor while the old one stays on it. So the calls that keep strictly more are **161 through 1996**. The ratio at C = 650 is 3.07x, not 3.2x — 3.2x is `520/163`, and 520 is clamped to 500 before it is used. Item 1 and item 3 hold exactly as written.

    ### Also worth carrying

    The margin argument at `:246-253` rests on rendering being 1.01x the span, measured on ONE fixture. A span of many very short turns renders well past 1.25x, at which point `0.8 x rendered > span` and the did-not-shrink guard is the only thing standing. That margin is fixture-specific, not structural.

    ### What this means

    The change is safe to keep. The defects are in what the code and the commit message SAY about it, and the same false claim is in `94ca5e9`'s message, so it cannot be edited without a rewrite. Correct the doc comments and record the correction here.

    ## Open, not done

    - [x] Correct `Summarization.swift:257-260`, and the 625 figure, to the measured 624 and the real 1997 crossover
    - [x] State the rendering margin as fixture-specific rather than structural
    - [ ] `/review` never completed on `94ca5e9` — the agent died on an API limit. This card has NOT passed review.
  timestamp: 2026-08-18T19:55:11.690891+00:00
- actor: claude-code
  id: 01m0b8ea62wzn04cpzwpn1c1re
  text: |-
    ## Documentation corrected in `Summarization.swift`, and two of the verifier's own numbers corrected with it

    Scope was documentation only. `summaryRetentionRatio`, `summaryTokenRatio`, `maximumSummaryTokens`, the cut and every test assertion are byte-identical. `git diff --stat` touches one file.

    ### I re-derived every figure before I wrote it

    The arithmetic is `min(maximumSummaryTokens, max(minimumSummaryTokens, ceil(C * ratio)))`, with `maximumSummaryTokens = max(128, ceil(2000 * 0.25)) = 500` at the defaults. I evaluated it over the whole range rather than at the points named.

    | content C, estimated tokens | old bound, ratio 0.25 | new bound, ratio 0.8 |
    |---|---|---|
    | 160 | 128 | 128 |
    | 161 | 128 | 129 |
    | 623 | 156 | 499 |
    | 624 | 156 | **500 — the new bound reaches the cap** |
    | 650 | 163 | 500 |
    | 1996 | 499 | 500 |
    | 1997 | **500 — the old bound reaches the cap** | 500 |

    ### Claim 1 holds. Claims 2 and 3 needed correction, in the direction of MORE change, not less

    - **624, not 625 — confirmed.** `ceil(0.8C) >= 500` needs `0.8C > 499`, so `C > 623.75`, so `C >= 624`. C=623 gives 499 and C=624 gives 500, exactly as stated.
    - **The old crossover is 1997, not 1998.** `0.25` is exact in binary, so `ceil(0.25C) >= 500` needs `0.25C > 499`, i.e. `C > 1996`, i.e. `C >= 1997`. At C=1996 the product is exactly `499.0` and `ceil` leaves it at 499; at C=1997 it is `499.25` and `ceil` gives 500. So the two bounds agree from **1997**, and the band where the new cut keeps strictly more ends at **1996**.
    - **The band also starts far lower than 624.** Below C=161 both bounds sit on the `minimumSummaryTokens` floor of 128 and are equal. From C=161 the new bound leaves the floor while the old one stays on it until C=513. So the calls that keep strictly more are **161 through 1996**, not 624 through 1997. The 624 figure marks where the CAP starts binding on retention, which is a different event from where the two bounds part company.
    - **At C=650 the ratio is about 3.1x, not 3.2x.** Old 163, new 500, so 3.07x. 3.2x is `520/163` — the unclamped retention bound over the old one, and 520 is clamped to 500 before it is used.

    ### Claim 3 holds, and the smoke run confirms it end to end

    `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` reports `ceilings=[291]`, so the generation allowance is `291 - 128 = 163`, so `ceil(0.25C) = 163` and C is between 649 and 652. Retention on that content is `ceil(0.8 * 650) = 520`, which the cap clamps to 500 — **the cap does bind** — and the same call still moved from 160 stored tokens to 330. The sentence that said only calls where the cap does not bind keep more of their answer was therefore false for the one fixture it cited.

    I did not write "calls whose content is under `maxChunkTokens`" as the replacement, because that is off by three at the top: content of 1997, 1998 and 1999 estimated tokens is under `maxChunkTokens` of 2000 and is cut to exactly what it was cut to before. The doc now states the band by its measured edges instead.

    ### What changed in the file

    1. **The margin paragraph on `summaryRetentionRatio`.** The 1.01x rendering figure is now stated as a property of that one fixture. The labels and the separator cost about 19 bytes per prompt/response turn however short the turn is, so entries averaging under roughly 40 bytes of text render past 1.25x the span; past 1.25x this ratio of the rendered content EXCEEDS the span, this bound guarantees nothing on its own, and `Compactor`'s did-not-shrink guard is the only thing standing. The doc says why a fixture-measured margin is still safe to ship: the worst this bound can then do is let a fold be discarded, which is the state that preceded it.
    2. **The false sentence on `summaryRetentionRatio`.** The sentence about a call handed a full `maxChunkTokens` is kept word for word, because it is correct. The claim after it is replaced by the measured band — 624 where the cap starts binding on retention, 1997 where the old bound reached it, 161 where the floor stops deciding both — and by the fixture that shows the cap binding while the stored summary still trebled.
    3. **The same false reading on `maximumSummaryTokens`.** That doc said the cap "keeps raising the retention ratio a change to small folds only". Same cause, same file, so it is corrected rather than left standing: reaching the cap under one ratio is not reaching it under the other.
    4. **`summaryTokenAllowance(ingesting:atRatio:)`.** Its summary still said "`summaryTokenRatio` of `tokens`" although the ratio has been a parameter since `94ca5e9`. It now says `ratio` of `tokens`, and states the rounding up that puts the crossover at 624 and not 625 — the root cause of the off-by-one, recorded where the rounding lives.
    5. **Two stale symbol links.** ``summaryTokenAllowance(condensing:)`` names no symbol; the function is `summaryTokenAllowance(condensing:atRatio:)`. Both sites fixed.

    ### What I did NOT change

    `94ca5e9`'s commit message carries the same false claim and cannot be edited without a rewrite. It stands, and this comment is the record that supersedes it.

    ### Verification

    - `swift build` — complete, 10.9 s.
    - `swift build --build-tests -Xswiftc -warnings-as-errors` — complete, zero warnings.
    - `swift test` — 984 + 29 + 58 = 1071 tests, 0 failures, 1 pre-existing known issue (`BoundedWait.swift`).
    - `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` — 2 tests, 0 failures, 8.0 s, and it printed the numbers the doc now cites: `ceilings=[291] answerTokens=[330] spanTokens=643 summaryTokens=330 tokensBefore=713 tokensAfter=400`.
    - `FM_ROUTER_INTEGRATION_TESTS` and `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` were never set. No `swift format`.
  timestamp: 2026-08-18T20:19:11.682579+00:00
- actor: claude-code
  id: 01m0b8gjpqdj3jr8jc8fjeq9dy
  text: |-
    ### implement — changed
    - evidence: 1 file — `Sources/FoundationModelsRouter/Compaction/Summarization.swift`, 58 insertions and 17 deletions, all of them doc comment. No source line, no test line, no constant changed. `git diff --stat -- Sources Tests` names that one file.
    - checklist: items 1 and 2 of the verification pass are flipped on the comment that carries them. Item 3 stays open, because `/review` still has not run on this work.
    - the three claims: item 1 (624, not 625) holds and is now in the doc. Item 3 (the sentence is false for the fixture it cites) holds and the sentence is replaced. Item 2 is off by one at BOTH edges and is corrected in place on the verification comment: the old bound saturates at C >= 1997, not 1998, and the band where the new cut keeps strictly more starts at 161, not 624, because below 161 both bounds sit on the `minimumSummaryTokens` floor. The 3.2x figure is 3.07x — 3.2x divides the UNCLAMPED 520 by 163.
    - I did not use the suggested replacement wording "calls whose content is under `maxChunkTokens`": content of 1997 to 1999 estimated tokens is under `maxChunkTokens` and is cut to exactly what it was cut to before, so that phrasing is off by three at the top. The doc states the band by its measured edges.
    - swept the same cause through the file rather than only the cited lines: `maximumSummaryTokens` carried the same false reading ("a change to small folds only") and is corrected; `summaryTokenAllowance(ingesting:atRatio:)` still said "`summaryTokenRatio` of `tokens`" although the ratio is a parameter, and now states the rounding up that puts the crossover at 624 and not 625; two stale ``summaryTokenAllowance(condensing:)`` symbol links name the real symbol.
    - no number changed. `summaryRetentionRatio` is still `0.8`, `summaryTokenRatio` still `0.25`, `maximumSummaryTokens` still computed from `summaryTokenRatio` alone, the cut untouched, every test assertion untouched.
    - verification: `swift build` complete; `swift build --build-tests -Xswiftc -warnings-as-errors` complete, zero warnings; `swift test` — 984 + 29 + 58 = 1071 tests, 0 failures, 1 pre-existing known issue (`BoundedWait.swift`). `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests` — 2 tests, 0 failures, 8.0 s, printing `ceilings=[291] answerTokens=[330] spanTokens=643 summaryTokens=330 tokensBefore=713 tokensAfter=400`, which is the measurement the corrected doc cites.
    - not spent: `FM_ROUTER_INTEGRATION_TESTS` and `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` were never set. No `swift format`.
    - next: `/review ^azd033m`. The gated tier still has to run before `^fm5ddk9` AC1/AC2 and `^bgxtdk3` criterion 5 can close.
  timestamp: 2026-08-18T20:20:25.943578+00:00
position_column: doing
position_ordinal: '8280'
title: The c26fbbe length directive stalls the compaction summarizer — 7 of 7 folds unfinished in 1796 s, where 7 folds plus 7 answers took 1686 s before it
---
Measured by the instrumented gated run of 2026-08-18, the one run `^h2xxsse` sanctioned. Log: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/606aa1c2-1180-4d8b-96da-9a3c34d5a1b0/scratchpad/gated-run-3.log`.

## The measurement

`FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` at HEAD `523689b`, `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` NOT set. The whole progress trail the run emitted:

```
[compaction-eval] model load started ref=mlx-community/Muse-Glimmer-30B-4bit
[compaction-eval] model load returned ref=mlx-community/Muse-Glimmer-30B-4bit took=3.6s
[compaction-eval] sample=1/7 seed=budget-cap-tool-and-owner fold started elapsed=0.0s
[compaction-eval] sample=2/7 seed=db-port fold started elapsed=0.0s
[compaction-eval] sample=3/7 seed=encryption-algorithm fold started elapsed=0.0s
[compaction-eval] sample=4/7 seed=env-file fold started elapsed=0.0s
[compaction-eval] sample=5/7 seed=license-key-and-region fold started elapsed=0.0s
[compaction-eval] sample=6/7 seed=three-facts-long-project-brief fold started elapsed=0.0s
[compaction-eval] sample=7/7 seed=three-facts-support-escalation fold started elapsed=0.0s
```

Then the 1800-second limit, `0 of 7 seeds measured`, and a failure at 1800.260 s.

**Seven `fold started` lines. Zero `fold returned` lines. Zero `answer started` lines.** Not one of the seven summarizer calls completed in about 1796 seconds of model time.

## What this refutes

`^h2xxsse` listed three explanations. Two are now dead, by measurement rather than by argument:

- **The model load did not stall.** It took **3.6 seconds**. It is not a meaningful part of the tier's cost at all.
- **No sample hung in its answering turn.** No sample ever REACHED its answering turn. The answering turn ran zero times.

## What is left, and why it points at the directive

Every one of the seven samples was inside its summarizer call when the limit fired. The summarizer call is the only thing `c26fbbe` changed, and the change is bounded:

- `maxTokens` is unchanged. `outputTokenCeiling(forSummaryAllowance:)` returns `allowance + reasoningTokenHeadroom`, identical arithmetic to the old `summaryTokenAllowance(condensing: content) + reasoningTokenHeadroom`. The ceiling is still 4224.
- The number of summarizer calls is unchanged, and chunking is unchanged.
- The only difference is the directive paragraph inserted between the caller's instructions and the content — about 330 characters of extra INPUT, which is prefill measured in milliseconds.

So the extra time is spent on what the model GENERATES in response to the directive, and nothing else in the diff can produce it.

## The size of the regression, stated honestly

| run | what completed | wall clock |
|---|---|---|
| 2026-08-17 21:42, before `c26fbbe` | 7 folds AND 7 answering turns | 1685.9 s |
| 2026-08-18, after `c26fbbe` | 0 folds | > 1796 s, cut off |

The fold step ALONE now costs more than the fold step and the answering step together did before.

**No upper bound can be given from this run, and that must not be papered over.** Not one fold finished, so the trail gives a floor and no ceiling: the true per-fold cost is somewhere above "more than the whole previous run", and could be far above it. A started/returned pair bounds a step only when the step returns.

## What the next run needs

Getting the magnitude needs either a bound the run can actually reach, or a finer signal:

- Measure the directive's effect on GENERATED LENGTH directly, on one seed, rather than on the whole tier. The question is how many tokens the model emits for one summarizer call with the directive versus without it, and one seed answers it.
- Or emit an in-flight heartbeat from the summarizer so a call that never returns still states how long it has been running and how much it has produced.

Prefer the first: it is one seed, it is cheap, and it measures the mechanism rather than the symptom.

## What must NOT be done

Do not raise `compactionEvalSubsetTimeLimitMinutes` to make the run fit. The limit is measured and its basis is documented, and a directive that makes one summarizer call outlast a whole previous run is a product defect, not a limit that is too small.

## Related

- `^h2xxsse` — the instrumentation that produced this measurement.
- `^fm5ddk9` — the card that added the directive. Its two open criteria stay open; this run measured no summary at all.
- `^9cw5g6n` — the concurrency finding from the same trail, which changes how every per-sample figure on this tier must be read.
- `^bgxtdk3` — its acceptance criterion 5 stays open for the same reason.



## Review Findings (2026-08-18 09:24)

> Scope: `review sha 6fc9bb1~1..6fc9bb1` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 18 not reviewed.

> 18 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 18 file(s)

- [x] `Sources/FoundationModelsRouter/Compaction/Summarization.swift:616` `duplication/duplication` — The `prefix(of:withinCharacters:)` function duplicates logic already present in `ToolOutputCapping.prefix(of:keepingAtMostUTF8Bytes:)`. Both functions take a string and a UTF-8 byte limit, iterate through characters accumulating byte counts, and return the prefix before the limit is exceeded. The implementations differ only in variable names and approach (index-based vs string-building), but perform identical operations. Extract a shared utility function to a common location (e.g., a new `StringUtilities` or to an existing utilities module) that both `ToolOutputCapping` and `Summarization` can call. Alternatively, if appropriate for the architecture, make `ToolOutputCapping.prefix` public and call it from `Summarization`. Avoid keeping duplicate logic that will need to be maintained in lockstep.

## Directed verification of `cut(_:toCharacters:)` (2026-08-18 09:24)

The review brief asked four questions about the new cut on the production path. Three hold. One does not, and is recorded as an open item.

- Ordering of the empty-summary refusal — **holds.** `summarizeOnce` throws `SummarizationError.emptySummary` on `summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` and only then returns `Self.cut(summary, toCharacters:)`. The refusal reads the model's own answer, before the cut.
- The cut's own fallbacks cannot make an empty string from a non-empty answer — **holds.** When the byte-budget prefix returns empty, `lastSentenceBoundary` gives `nil` and `lastIndex(where: \.isWhitespace)` gives `nil`, so the final line `budgeted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : budgeted` returns the uncut `summary`. Each earlier branch is guarded by its own non-empty check before it returns.
- Multi-byte scalar and grapheme cluster safety — **holds.** The byte-budget prefix iterates `for character in text` and accumulates `character.utf8.count`, so it never slices at a byte offset. `lastSentenceBoundary` and `lastIndex(where:)` return `String.Index` values taken from that same character walk.
- Unit agreement with `Compactor`'s did-not-shrink guard — **holds.** The cut binds on `summary.utf8.count > limit`, with `limit = Int(Double(allowance) * Compactor.charsPerTokenEstimate)`. `Compactor.estimatedTokenCount(bytes:)` is `Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))` over UTF-8 bytes. Both sides measure UTF-8 bytes, so they cannot drift.

- [x] `Sources/FoundationModelsRouter/Compaction/Summarization.swift:591` `correctness` — `cut(_:toCharacters:)` keeps a PREFIX of the summary, so it is content-blind: a fact the model states late in its answer is removed, and every fact stated before it is kept. The gated smoke run of this commit measured the loss — `answerTokens=[332]` cut to `summaryTokens=136`, so 59% of the model's answer was discarded. The eval seeds this thread of cards is measured by are planted-fact recall seeds, and three of them (`three-facts-long-project-brief`, `three-facts-support-escalation`, `license-key-and-region`) plant more than one fact, so the later facts are the ones a prefix cut drops. State the risk on the card and measure recall against the eval tier before this cut is relied on: the fold now shrinks the transcript, but shrinking it is not the same as carrying the fact the summary exists to carry. #compaction #defect #eval #real-model
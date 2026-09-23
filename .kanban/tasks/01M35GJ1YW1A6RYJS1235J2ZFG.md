---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m35gr0sgbcnwvz533tprnt9c
  text: |-
    ### implement — changed
    - evidence: 6 files.
      - Sources/FoundationModelsRouter/Compaction/Summarization.swift: `CompactionCall.outputCeiling(for:)` now returns `min(allowedSummaryTokens, window − input)`. The flash tier still runs only when `window − input >= allowedSummaryTokens`. The own model runs when that ceiling is positive. The plan already stops with `.targetLeavesNoRoomForSummary` when the allowed size is not positive, and the compactor stops with `.inputFillsSummarizerWindow` when no window leaves room. The doc comments state the new ceiling. No new constant.
      - Tests/FoundationModelsRouterTests/OneCallCompactionTierTests.swift: the old "ceiling is window − input" test is now "the room caps the ceiling under the allowed size". New test: a summarizer that would write forever stops at the allowed size, and the summary applies because it shrinks the context. The acceptance test expects `min(stated, window − input)`. The context sizes are named constants.
      - Tests/FoundationModelsRouterTests/Helpers/RecordingSummarizer.swift: new `RunawaySummarizer`. It answers with text that fills the ceiling.
      - Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, IntegrationTests/.../CompactionSmokeIntegrationTests.swift, IntegrationTests/.../CompactionRoundTripIntegrationTests.swift: the comments state the new ceiling.
    - `swift test --filter OneCallCompactionTierTests`: 8 tests passed.
  timestamp: 2026-09-22T21:35:57.232621+00:00
- actor: claude-code
  id: 01m35gxysj75tzn9q4j5dsbatk
  text: |-
    ### test — green
    - evidence: `swift test`: 1298 unit tests in 145 suites passed (2 known issues, not new), 1 public-surface test passed, 83 eval tests in 10 suites passed. `swift build --package-path IntegrationTests --build-tests`: Build complete. The one build warning, "missing creator for mutated node … mlx-swift_Cmlx.bundle", comes from the build system and is not new.
    - The first run was red: RoutedSessionCompactTests.swift:732 expected the ceiling `window − input`. The test now expects `min(allowed, window − input)`, which is the allowed size in that test. The shared helper `TokenBudget.allowedSummaryTokens(for:)` (Helpers/CompactionFixtures.swift) now computes the allowed size for both test files.

    ### Real-model tiers (gated), 2026-09-22, this machine, greedy decoding
    **Fact retention** — `swift test --package-path IntegrationTests --filter FoundationModelsRouterEvalIntegrationTests`, Qwen2.5-3B-Instruct-4bit. FAIL against the floors (0.71 = 5 of 7). Summary share 4 of 7 (0.57). Answer share 4 of 7 (0.57). Before ^pke18c2: 6 of 7. After ^pke18c2: 3 of 7. Every seed made 1 summarizer call, and every compaction applied (no discard).
    - budget-cap-tool-and-owner: summaryLostFact (key "Marcus"). The summary lists the user's small-talk requests and the assistant's acknowledgements ("Noted — I have the background in mind.", "Amber.") as the stated facts. It holds no word of the approval rule.
    - db-port: retained.
    - encryption-algorithm: retained. After ^pke18c2 this seed was discarded (summary 599 tokens over a 507-token span). The ceiling now stops the summary, and the snapshot shrinks.
    - license-key-and-region: retained.
    - sesame-allergy: summaryLostFact (key "sesame"). The summary holds "Pebble", "Rapid" and "Conversation makes sense". Section 3 says "No specific constraints or decisions are mentioned." The answer then named "salt".
    - three-facts-long-project-brief: retained.
    - three-facts-support-escalation: summaryLostFact (key "6 hours"). The summary is a numbered list of the assistant's replies only ("Noted — I have the background in mind.", "Pebble would suit something low-priority.", "September runs to thirty days."). The answer said 4 hours.
    - For the owner: the floors and the compaction prompt are not changed. In each lost seed, the small model summarizes the acknowledgements and the small talk, and not the user's planted fact.

    **Continuity** — same command. PASS: 4 tasks; compactionOccurred 1.0, factsSurvived 1.0, answersCorrect 1.0 (4 of 4).

    **Smoke suites** — `swift test --package-path IntegrationTests --filter "CompactionSmokeIntegrationTests|AutoCompactionTriggerIntegrationTests|RecordedTranscriptCompactionIntegrationTests"`, Llama-3.2-1B-Instruct-4bit. FAIL: 5 tests, 3 pass, 2 fail.
    - CompactionSmokeIntegrationTests "one compaction against a real model": PASS. `ceilings=[332] answerTokens=[332] spanTokens=736 summaryTokens=332 tokensBefore=744 tokensAfter=377 shortfall=nil`. After ^pke18c2 the same call ran to 2821 tokens and was discarded.
    - CompactionSmokeIntegrationTests "a fact planted at the end of the long turns": FAIL. The answer runs to the 332-token ceiling. It stops in section 5, before the model writes "Kestrel". Sections 2 to 4 repeat "User: … / Assistant: Acknowledged." lines and the size-budget line of the prompt.
    - AutoCompactionTriggerIntegrationTests: PASS. flash tier, tokensBefore 649, tokensAfter 87.
    - RecordedTranscriptCompactionIntegrationTests "the recorded transcript still carries the entry kinds": PASS.
    - RecordedTranscriptCompactionIntegrationTests "one compaction of the recorded transcript": FAIL, at RecordedTranscriptCompactionIntegrationTests.swift:259: `TemplateException("Cannot put tools in the first user message when there's no first user message!")`. The error comes before the summarizer writes output, so the ceiling does not cause it. New task ^9ax82gr records it.
  timestamp: 2026-09-22T21:39:11.794007+00:00
- actor: claude-code
  id: 01m35gyw4xs2xkmreyve7w4r0g
  text: |-
    ### commit — changed
    - evidence: 31a349f fix(compaction): cap the summarizer call's output at the allowed summary size
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-22T21:39:41.853195+00:00
- actor: claude-code
  id: 01m35h827yw3k9v3nbgwv00jht
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD`: 0 findings (1 refuted), 8 files reviewed. No prior Review Findings on the card. The task moved to done.
  timestamp: 2026-09-22T21:44:43.006307+00:00
- actor: claude-code
  id: 01m35h8dsmfw1yj4ras64r171m
  text: |-
    ### finish iteration 1 — review: clean
    - implement: changed — 31a349f: `CompactionCall.outputCeiling(for:)` returns `min(allowedSummaryTokens, window − input)`; the runaway-summarizer test; the ceiling tests and the doc comments state the new ceiling
    - test: green — `swift test`: 1298 unit tests in 145 suites (2 known issues, not new), 1 public-surface test, 83 eval tests: all pass. `swift build --package-path IntegrationTests --build-tests`: Build complete
    - real-model: fact retention 4/7, answers 4/7, continuity 4/4, smoke fail (3 of 5 pass: the main smoke test and the auto-trigger test pass; the planted-fact test fails because the answer stops at the 332-token ceiling before "Kestrel"; the recorded-transcript compaction fails with a chat-template error, recorded on ^9ax82gr)
    - commit: 31a349f
    - review: clean — `review sha HEAD~1..HEAD`: 0 findings. The task is in done.
    - For the owner: fact retention is under its floor of 5 of 7. Lost seeds: budget-cap-tool-and-owner, sesame-allergy, three-facts-support-escalation. Their summaries hold the small talk and the assistant's acknowledgements, not the planted fact. The floors and the compaction prompt are not changed.
  timestamp: 2026-09-22T21:44:54.836265+00:00
position_column: done
position_ordinal: ffffe880
title: Cap the summarizer call's output at the allowed summary size; re-measure the real-model tier
---
## Decision (from the owner, 2026-09-22)

After ^pke18c2 the summarizer call's output ceiling is `window − input`. On the gated real-model tier, Llama-3.2-1B compacting a 744-token context wrote about 2,800 tokens, so the shrink check threw every summary away and the small-model smoke suites fail. The owner chose: the ceiling is the allowed summary size, the same number the prompt states (`target − instructions − protected outputs − pending-runs rendering`, in tokens), capped at `window − input`. A reasoning model fits its thinking inside that size too. No new number.

## Do this

1. In the one-call summarization (`Compaction/Summarization.swift` and the tier selection in `Compaction/Compactor.swift` after ^pke18c2), set the call's `maxTokens` to `min(allowedSummaryTokens, window − inputTokens)`. When that is not positive, the compaction does not run and reports why (as it already does for a non-positive allowed size).
2. Update the doc and the tests that assert the ceiling is `window − input`. Add a test: a summarizer that would write forever is stopped at the allowed size, and the result is accepted when it shrinks the context.
3. Run the gated real-model tiers on this machine: the fact-retention eval (Qwen2.5-3B), the continuity eval, and the small-model smoke suites (Llama-3.2-1B). Record each result on this card: facts kept out of 7 (the floor is 5 of 7; before ^pke18c2 it was 6 of 7), continuity out of 4, and smoke pass or fail. Do not lower a floor. Do not change the compaction prompt in this card; if fact retention is still under its floor, record the lost seeds and what the summaries contained, and report it for the owner's decision.

## Rules

- No new constant. The ceiling derives from the budget, the counter and the window.
- Use the `files` tool for edits, never `sed` or shell redirection.

## Acceptance

- The ceiling test passes. All tests pass.
- The real-model results are on the card. #compaction #limits
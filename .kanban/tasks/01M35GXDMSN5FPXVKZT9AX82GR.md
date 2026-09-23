---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m35sas0k21t03k9xxzq58q64
  text: |-
    ### implement — changed

    What changed:
    - `Summarization.cost(of:in:wholeTokens:counter:)` (Compaction/Summarization.swift): cost(part) = count(whole) − count(whole without part). The plan counts the instructions and the protected entries with it. The template renders only the whole and the whole less the part. Both hold the user messages.
    - The snapshot count (step 2 of the card). Method: the snapshot entries WITH the next turn's prompt entry. Reason: the summary entry is a `.response` (assistant role). So instructions + summary + kept tool entries hold no user message, and a Qwen3.8 template refuses them ("system + assistant fails"). Thus option "count the snapshot as a conversation by its role" is not possible. Every compaction runs before a turn (the proactive path, the overflow retry, and a host `compact()` before the next `respond`), and that turn's call adds its prompt entry. The prompt text is not known when the compaction runs, so the last prompt entry of the live context stands in for it (`Summarization.nextTurnStandIn(in:)`). tokensAfter = count(snapshot + stand-in) − count(stand-in). With no prompt entry in the live context, the stand-in is empty and the snapshot is counted alone. The did-it-shrink check compares tokensBefore with this count.
    - No catch of the template error. No new number.
    - Tests: `Tests/FoundationModelsRouterTests/Helpers/ScriptedChatTokenizer.swift` (shared scripted tokenizer, moved out of TokenizerTokenCounterTests, with `requiresUserMessage`), `Tests/FoundationModelsRouterTests/CompactionPartCostTests.swift` (6 tests: the template refuses instructions alone; a compaction over instructions, user, assistant and a protected output runs with no error; protected cost = difference; disjoint part costs sum to the whole; snapshot counted with the next-turn prompt; the stand-in rule).
  timestamp: 2026-09-23T00:06:00.467034+00:00
- actor: claude-code
  id: 01m35sayhdp9a43zt5edwvhzcf
  text: |-
    ### test — green, and the two gated runs

    - Unit: `swift test` — 1304 tests in 146 suites passed (2 known issues are the designed `withKnownIssue` tests in RealModelHarnessTests and BoundedWaitTests), plus 1 and 83 tests in the other targets passed. No warnings from our code.
    - `swift build --build-tests --package-path IntegrationTests` — Build complete.
    - Llama-3.2-1B: `swift test --package-path IntegrationTests --filter RecordedTranscriptCompactionIntegrationTests` — 2 tests in 1 suite passed (4.9 s). The compaction is applied. No TemplateException.
    - Qwen3.8-27B fact retention: `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests --attachments-path <scratchpad>/att`. The suite has no selector for one seed, so the command ran the tier; the 2-minute suite limit (`compactionEvalSubsetTimeLimitMinutes = 2`) stopped it. Evidence from the xcevalresult attachment, per seed:
      - BEFORE this change (^jhb7x54 run, 18:50): 7 of 7 seeds `Jinja.TemplateException error 1`.
      - AFTER: 0 template errors. 5 seeds: `the summarizer returned no text, so the compaction has no summary to store` (SummarizationError.emptySummary). 2 seeds: `CancellationError` (the suite time limit). Fact kept: no seed measured (0 of 7).
      - Cause of the empty summary is outside this card: the call ceiling is the allowed summary size (^35j2zfg, targetTokens 418 in this tier less the instructions), and the 27B reasoning model spends that ceiling on its thinking, so no answer text is left. I did not change a number, a floor or the prompt. A new card records it for the owner.
  timestamp: 2026-09-23T00:06:06.125872+00:00
position_column: doing
position_ordinal: '8180'
title: Count the parts of a compaction without rendering a chat template on a set that is not a conversation
---
## What happens

Two real models refuse a compaction before the summarizer call, with a chat-template error:

- Llama-3.2-1B (^35j2zfg, `RecordedTranscriptCompactionIntegrationTests.swift:259`): `TemplateException(message: "Cannot put tools in the first user message when there's no first user message!")`.
- Qwen3.8-27B (^jhb7x54, all 7 fact-retention seeds and all 4 continuity tasks): `Jinja.TemplateException error 1`, from `chat_template.jinja:88-101`: "No user query found in messages." A jinja2 render confirmed: system only fails, system + assistant fails, system + user renders.

## Cause

`TokenizerTokenCounter.count(_ transcript:)` (`Sources/FoundationModelsRouter/Resolution/TokenizerTokenCounter.swift:35-45`) renders the model's chat template for any set of entries. `Summarization.plan` counts sets that are not a whole conversation: the instructions entry alone (`Compaction/Summarization.swift:98`), the protected tool outputs alone (`:83`), and the snapshot entries (`:346`). A template that requires a user message throws.

## Do this

1. Count a part of the live context as its cost inside the whole, with no template render on the part alone: `cost(part) = count(whole) − count(whole without part)`, where `whole` is the live context the compaction reads (it holds the user's messages). Each of those two renders is a real conversation.
2. The snapshot's size is what the model will see next. Count it as the model receives it: the snapshot entries with the next turn's prompt entry, if the next call adds one; or check how the summary entry is placed (its role) and count the snapshot as a conversation. Record which on the card. The did-it-shrink check compares the whole with that count.
3. Do NOT catch the template error and fall back to plain text. That hides a real fault and gives a different count from what the model sees.
4. No new number.
5. Tests: a scripted tokenizer whose template throws when no user message is present (like Qwen3.8's). A compaction over a live context with instructions, user and assistant entries, and a protected tool output runs with no error, and the part costs sum to the whole's cost where the parts are disjoint.
6. Run the gated `RecordedTranscriptCompactionIntegrationTests` (Llama-3.2-1B) and one fact-retention seed on Qwen3.8-27B (the eval constants were switched by ^jhb7x54; the edits may be uncommitted in the tree — commit them with this card, they are the owner's decision). Record both results on this card.

## Acceptance

- Neither template error occurs.
- The tests above pass. All tests pass.
#compaction
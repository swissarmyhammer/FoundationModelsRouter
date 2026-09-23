---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m372rat4mbm9c5hyftxx8c4a
  text: |-
    ### scope change — from the owner, 2026-09-23
    The owner said: "get rid of the fact retention eval".
    - Do not run the fact-retention tier on this card. Do not record fact-retention numbers.
    - Run the continuity tier on Qwen3.8-27B only. Record: continuity k/4, how many summaries were empty, the run time, and one example v6 summary.
    - Do not edit or delete the fact-retention eval files on this card. A separate card deletes them after this card is done.
  timestamp: 2026-09-23T12:09:56.292999+00:00
- actor: claude-code
  id: 01m372y4hsmkam98vaf2vf30ea
  text: |-
    ### implement — research and decisions
    - `CompactionPrompt.default` is now `router-default-v6`, with the owner's text character for character.
    - The check the card asks for: the v6 text starts "Summarize the conversation above". The old assembly (`Summarization.assembledPrompt`) put the prompt FIRST and the conversation AFTER the dashes. Thus "above" did not read correctly. Change: the assembly now puts the rendered conversation first, then "---", then the prompt text, the size line (unchanged), then the framing line. The framing line now says "Everything before the line of three dashes is the conversation to summarize." (was "after"). No rule was added.
    - Unit tests changed: `CompactionPromptTests` (v6 name, the four points, no fact list, assembly order), `OneCallCompactionTests` (the prompt no longer starts with the prompt text; it starts with the conversation).
    - `compaction_plan.md` §2 shows v6 and records why v5 was replaced.
    - Time limits: the gated suites in both IntegrationTests targets lose their `.timeLimit` traits and the two constants `integrationTestBudgetMinutes` and `gatedEvalSuiteTimeLimitMinutes`. Per the owner's scope change, the fact-retention suite (`CompactionEvaluationIntegrationTests`, `compactionEvalSubsetTimeLimitMinutes`) is NOT edited: a separate card deletes that eval. The three suites that load no model (MetalLibraryBootstrap, RoutedModelContextTokensSurface, ToolCallAttachmentSurface) keep their own 1-minute limits: they are not real-model suites.
    - Tooling note: `dump validators` wrote a 754 000-character file, too large to read whole.
  timestamp: 2026-09-23T12:13:06.489169+00:00
- actor: claude-code
  id: 01m376yckv5e6zy4vpnm5ez4y2
  text: |-
    ### real-model — continuity tier, Qwen3.8-27B, v6 (fact-retention not run, per the owner)
    Command: `swift test --package-path IntegrationTests --filter CompactionContinuityEvaluationIntegrationTests` (no time limit).

    Run 1 — v6, reasoning ON in the summarizer call:
    - 4 of 4 compactions gave NO summary text (`SummarizationError.emptySummary`: "the summarizer returned no text, so the compaction has no summary to store"). Empty summaries: 4.
    - compactionOccurred -1.0, factsSurvived -1.0, answersCorrect -1.0 (every sample threw). Continuity 0/4.
    - Suite wall clock 228.7 s.
    - Result: the salient-points prompt alone does not stop the 27B from spending the whole ceiling on its reasoning.

    Decision (owner's instruction of 2026-09-23: turn reasoning off for the summarizer call, keep the ceiling):
    - New `LanguageModelSessionBackend.respondWithoutReasoning(to:maxTokens:)`. The default calls `respond`. The MLX backend passes `ContextOptions(reasoningLevel: .custom("no_think"))` for that one call. `MLXLanguageModel` reads that value as "thinking off" and renders the Qwen3 template with `enable_thinking=false` in the template's additional context.
    - The MLX backend asks for it ONLY when the loaded model's reasoning strategy is `.templateFlag`. Reason: the engine throws `cannotDisableReasoning` for an `.alwaysOn` model (for example Muse Glimmer) and for a `.none` model. Any other model generates as before.
    - `BackendCompactionSummarizer` calls `respondWithoutReasoning`. The ceiling is unchanged. No new number.

    Run 2 — v6, reasoning OFF in the summarizer call:
    - 5 compactions applied (one task compacted twice), 0 empty summaries. compactionOccurred 1.0.
    - factsSurvived 0.5, answersCorrect 0.5: continuity 2/4 (floors 0.7 and 0.45; the factsSurvived floor fails). Suite wall clock 479.3 s.
    - Passed: codename-and-owner ("Project Longbow, Marcus."), db-port-and-region ("Staging database port: 6543. Staging database region: eu-west-2.").
    - Failed: migration-script-and-rollback and vault-code-and-outpost. In both, the SUMMARY holds the planted values word for word (`scripts/migrate_2026_07.sql`, `scripts/rollback_2026_07.sql`; `CRIMSON-77`, `outpost Delta-9`). The ANSWERING turn then said it did not have them ("You only said \"Hello\" earlier ..."; "I do not have the vault code or outpost location."). So the loss is after the compaction, in how the answering turn reads the snapshot, not in the summary.

    Example v6 summary (Qwen3.8-27B, codename-and-owner):
    ```
    - **User Intent**: The user provided a project briefing containing two specific facts and a detailed background description of a scheduling tool for a research fleet. The immediate request was to acknowledge reading the background in one short sentence.
    - **Decisions & Constraints**:
        - The assistant must be terse and literal.
        - All facts in the conversation are fictional test data.
        - When asked to recall a fact, the assistant must state it exactly word-for-word as given.
        - The assistant must never refuse to state a fact from this conversation.
        - The assistant must never invent a value.
        - The assistant must not list facts for their own sake in the summary.
    - **Completed Actions**:
        - The assistant acknowledged reading the background with the sentence: "I have read all of it."
    - **Next Steps**:
        - The user will likely ask the assistant to recall the specific facts from the briefing.
        - The assistant must be prepared to state the codename and owner exactly as provided.
    - **Critical Values (Exact)**:
        - Internal codename: "Project Longbow"
        - Owner: Marcus
    ```
    Next (owner, 2026-09-23): no more full tiers. One short gated test proves the compaction on the 27B.
  timestamp: 2026-09-23T13:23:09.051481+00:00
- actor: claude-code
  id: 01m37727avhk9mkfjbccyhq0xj
  text: |-
    ### finish iteration 1 — stopped by the owner; real-model proof moves to ^9ddjkjm
    - implement: changed — v6 prompt text (owner's text) in `CompactionPrompt.default`; the assembly puts the conversation above the prompt, so "the conversation above" reads correctly; `respondWithoutReasoning(to:maxTokens:)` on `LanguageModelSessionBackend` (default: `respond`); the MLX backend turns thinking off (`.custom("no_think")`, which gives `enable_thinking=false` in the Qwen3 template context) only for a `.templateFlag` model; the compaction summarizer and the test summarizer call it; `.timeLimit` and `integrationTestBudgetMinutes`/`gatedEvalSuiteTimeLimitMinutes` removed from the gated real-model suites (fact-retention files not edited, per the owner); new gated `Qwen38CompactionIntegrationTests` (built live context, one compaction; not run on this card).
    - test: green — `swift test`: 1303 tests in 146 suites passed (2 designed known issues), 1 and 83 tests in the other targets passed; `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - real-model (Qwen3.8-27B, v6): fact-retention not run (owner's scope change). Continuity, reasoning on: summaries 0/4, empty summaries 4, continuity 0/4, 228.7 s. Continuity, reasoning off: 5 compactions applied, empty summaries 0, continuity 2/4 (factsSurvived 0.5, answersCorrect 0.5), 479.3 s. In the 2 lost tasks the summary held the planted values, and the answering turn said it did not have them.
    - commit: in this commit (local, not pushed).
    - review: not run — the owner stopped the card before review. The card stays out of `done`.
  timestamp: 2026-09-23T13:25:14.715447+00:00
- actor: claude-code
  id: 01m37agsgrh656apmbgjehpr9c
  text: |-
    ### review — findings
    - evidence: review sha 549642c~1..549642c: 1 finding, Qwen38CompactionIntegrationTests.swift:107 no_direct_standard_out_logs.
    - fix: the print line now has `// swiftlint:disable:next no_direct_standard_out_logs` with the reason, the same form as the ^9ddjkjm suite. `IntegrationTests` builds.
    - note: the real-model proof moved to ^9ddjkjm (done): one in-turn compaction 16070 -> 416, the summary kept the value, and the same turn answered.
    - next: commit, then review HEAD~1..HEAD.
  timestamp: 2026-09-23T14:25:37.816204+00:00
- actor: claude-code
  id: 01m37akx59rerpk7fax591jnq4
  text: |-
    ### finish iteration 2 — clean; done
    - review: findings (1) on 549642c~1..549642c, fixed in 1115abf; review sha HEAD~1..HEAD: clean (0 findings).
    - real-model proof: moved to ^9ddjkjm (done). One in-turn compaction 16070 -> 416 on Qwen3.8-27B, the summary kept the value, and the same turn answered.
    - test: `swift test` green (1310 tests in 148 suites, 2 designed known issues; 1 and 83 in the other targets). `IntegrationTests` builds.
    - commits: 549642c, 1115abf (local, not pushed).
  timestamp: 2026-09-23T14:27:19.849796+00:00
position_column: done
position_ordinal: ffffeb80
title: A salient-points compaction prompt (router-default-v6); no time limit on the gated real-model suites; re-measure on Qwen3.8-27B
---
## Decision (from the owner, 2026-09-23)

On Qwen3.8-27B the summarizer spent the whole allowed summary size on its reasoning, and 5 of 7 seeds gave no summary text (`SummarizationError.emptySummary`; card 01M35SB6W4C1RD0P5B07Y1Z9NJ, deleted into this one). The owner's words: "i think you need a better summary prompt that aims to capture a few salient points and no longer 'counts facts'". The ceiling from ^35j2zfg stays. Also: "No time limit on the gated real-model suites."

## The prompt

Replace `CompactionPrompt.default` (`Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift:26-68`, `router-default-v5`) with `router-default-v6`, text exactly:

```
Summarize the conversation above. Whoever continues has no other memory of it.
Write a short summary of the few points that matter to go on:
- what the user wants;
- what is decided, and what must not be done;
- what is done, and what comes next;
- any value the next step needs (a name, a path, a number), written exactly.

Leave out small talk, and finished work that does not matter next. Use plain sentences or short bullets. Do not list facts for their own sake.
```

The size line that `Summarization` adds after it stays ("Size budget: about N tokens. ..."). Check the framing directive (`contentFramingDirective`) and the `Summarization.swift:133` assembly still read correctly with the new text; do not add rules back.

## The time limit

Remove the time limit on the gated real-model suites (the 2-minute suite limit that cancelled 2 seeds on 2026-09-22; find it in `IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests` or the eval support, for example a `.timeLimit` trait or a `GatedSuiteSerialGate`/bounded wait). A gated run ends when it ends, or when the caller stops it. Unit-test time limits are out of scope.

## Measure

Run on Qwen3.8-27B (the eval constants already name it): the fact-retention tier and the continuity tier. Record on this card: summaries k/7, answers k/7 (floor 5/7), continuity k/4, how many summaries were empty, the run time, and one example summary. Do not change a floor. The fact-retention tier plants small facts; a salient-points prompt may keep fewer of them by design. Record the result as it is; the owner judges it.

## Rules

- No new number. Use the `files` tool for edits, never `sed` or shell redirection.
- Update the unit tests that assert v5 text or its section names.

## Acceptance

- `CompactionPrompt.default.name == "router-default-v6"` with the text above.
- The gated suites have no time limit.
- The 27B results are on this card. All unit tests pass; `IntegrationTests` builds.

#compaction

## Review Findings (2026-09-23 09:16)

> Scope: `review sha 549642c~1..549642c` — reviewed the diffs only — lines this change added or modified. 41 file(s) reviewed, 13 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `compaction_plan.md` — no validator matches this file

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Qwen38CompactionIntegrationTests.swift:107` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.

---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0djbftnakdv5ey940tmfpge
  text: |-
    Research done. Findings:
    - The demo lives in Examples/CompactionDemo (main.swift, SampleTools.swift, README.md, 6 fixture documents). Package.swift excludes README.md and Fixtures.
    - The old demo mixed 5 concerns: tool traffic, fact-store continuity, forced compact() fallback, restore from disk, and fullHistory. Only the compaction part stays.
    - The proven recipe is AutoCompactionTriggerIntegrationTests: model mlx-community/Llama-3.2-1B-Instruct-4bit, context 4096, sampling .greedy, a synthetic TokenBudget trigger, Summarization(keepRecentTurns: 1, reasoningTokenHeadroom: 128), reply ceiling 48 tokens through streamEvents(to:maxTokens:).
    - The checkpoint event is SessionEvent.compaction(CompactionResult). An applied fold has a non-empty stagesApplied. A fold with empty stagesApplied changed nothing and wrote no checkpoint, so the demo must not show it.
    - Summarization discards a fold when the folded span is too small (under approximately 512 estimated tokens the 128-token summary floor binds). Plan: trigger share 0.30 of 4096 (1229 tokens), so the fold span holds 4 or more document turns and the summarizer always shrinks the transcript.
    - Target share 0.05 (205 tokens) is out of reach for the deterministic stages, so the model-assisted stage always runs and always writes a summary.
    Plan: rewrite main.swift as (1) narrated document turns with measured usage against the trigger, break when usage crosses; (2) one trigger turn that folds, print the checkpoint event as it arrives; (3) print the summary text. Delete SampleTools.swift. Rewrite README.md. Run the demo and record the wall clock.
  timestamp: 2026-08-19T17:50:53.781716+00:00
- actor: claude-code
  id: 01m0dm0xvsnvzdx7r9xtzwyjk8
  text: |-
    Implementation done. What changed:
    - Examples/CompactionDemo/main.swift: full rewrite. The demo now does three steps only: (1) read fixture documents one turn at a time and print measured usage against the trigger, then say why the next turn folds; (2) run the trigger turn and print the SessionEvent.compaction checkpoint event as it arrives (id, tokensBefore, tokensAfter, stagesApplied, summaryEntryId); (3) print the compacted summary text. Tool traffic, fact-store recall, the forced compact() fallback, restore-from-disk, and fullHistory are removed.
    - Examples/CompactionDemo/SampleTools.swift: deleted. The demo uses no tools.
    - Examples/CompactionDemo/README.md: rewritten to match.

    Configuration, all measured on 2026-08-19:
    - standard = Llama-3.2-1B-Instruct-4bit at context 4096, sampling .greedy. The six fixture documents measure 239, 428, 617, 811, 976, 1138 tokens cumulative.
    - trigger share 0.22 (901 tokens): crosses after document 5 with about 75 tokens of margin on each side. Target share 0.05 forces the model-assisted stage. keepRecentTurns 1, reasoningTokenHeadroom 128, reply ceiling 48.
    - flash = GLM-4-9B-0414-4bit. This matters: performAutoCompaction prefers the FLASH slot as its summarizer tier, so flash is the model that writes the summary.
    - compactionPrompt = a one-paragraph demo prompt (public knob). The default eight-section prompt earns a long sectioned summary that the retention cut truncates mid-section, and the truncated scaffold then derails the 1B session's next reply.

    What did not work, so the next agent does not repeat it:
    - With the old flash placeholder SmolLM-135M, every fold summary was hallucinated repetition loops — under greedy AND sampled decoding, with the default AND simple prompts, whatever model held standard. The summarizer was SmolLM the whole time. Swapping the standard model (Llama-1B, Qwen-3B, Phi-3.5) changed nothing. Ministral-3-3B failed outright with a chat-template role-alternation error.
    - Two production-side hypotheses were tested and refuted: seeding the blank summarizer transcript with an instructions entry, and streaming instead of respond. Both experiments were reverted; Sources/ is untouched.

    Two new cards were filed for the discoveries: ^59fd9rt (flash tier degrades summary quality without a signal when flash is tiny) and ^51e9dyq (retention cut truncates the default prompt's sectioned summary mid-section on small spans).

    Verification:
    - Ran the demo four+ times; the final two greedy runs print identical numbers (checkpoint 1115 -> 498 tokens; usage 976 -> 460). Wall clock 13.7 s, well under 2 minutes.
    - Scripts/swift-test.sh --skip IntegrationTests: green, 1008 tests in 93 suites plus 75 tests in 8 suites, 0 failures (1 pre-existing deliberate known issue in BoundedWait).
    - swift build --build-tests -Xswiftc -warnings-as-errors: clean.
    - git status: only the three demo files changed; Sources/ clean.

    All five acceptance criteria are met by the run output: narration before the fold, the checkpoint event as it fires, the summary text, nothing off topic remains, and the run finishes in 13.7 seconds.
  timestamp: 2026-08-19T18:20:04.857530+00:00
- actor: claude-code
  id: 01m0dm18exqbaw9fdwybvzkc5p
  text: |-
    ### implement — changed
    - evidence: 3 files — Examples/CompactionDemo/main.swift (rewritten), Examples/CompactionDemo/SampleTools.swift (deleted), Examples/CompactionDemo/README.md (rewritten). Demo run wall clock: 13.7 seconds (swift run CompactionDemo, greedy, repeatable). Tests: Scripts/swift-test.sh --skip IntegrationTests green — 1008 tests in 93 suites + 75 tests in 8 suites, 0 failures. swift build --build-tests -Xswiftc -warnings-as-errors clean.
    - next: /review
  timestamp: 2026-08-19T18:20:15.709336+00:00
- actor: claude-code
  id: 01m0dm433zmc1e72sdq4yfnww5
  text: |-
    ### test — green
    - Command 1: `Scripts/swift-test.sh --skip IntegrationTests`. Result: 75 tests in 8 suites. All tests pass.
    - Command 2: `swift build --build-tests -Xswiftc -warnings-as-errors`. Result: build complete. No fault.
    - One line from a vendor tool showed: "missing creator for mutated node" for the mlx-swift_Cmlx bundle. This line comes from the Swift package build planner, not from our code. It is not a compiler warning. The build did not stop.
    - No test had a skip mark. No test failed. No re-run was needed.
    - next: send for review.
  timestamp: 2026-08-19T18:21:48.543584+00:00
position_column: doing
position_ordinal: '8380'
title: 'Refocus the CompactionDemo on compaction alone: narrate the trigger, then show the checkpoint event and the summary'
---
The user reviewed the demo on 2026-08-19 and reports it is a confused mess that drifts off its topic. The demo must show compaction and only compaction.

## What the demo must do

1. Describe what is going on: what the transcript holds, how large it is, and why the next turn crosses the compaction trigger.
2. Trigger compaction and show the compacted session checkpoint event when it arrives.
3. Show the compacted summary that the fold wrote.

## What to remove

Remove every part of the demo that does not serve that sequence. Content that does not explain the trigger, the checkpoint event, or the summary is off topic.

## Acceptance Criteria

- [ ] The demo prints a narration that says why the next turn triggers compaction, before it does
- [ ] The demo shows the compaction checkpoint event when it fires
- [ ] The demo shows the compacted summary text
- [ ] Nothing else remains: each remaining section serves the trigger, the event, or the summary
- [ ] The demo runs against a small model in well under 2 minutes
#compaction #demo
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37jtgbknjzam7m9t36xv020
  text: |-
    ### owner requirement (2026-09-23): reasonably fast on CI

    The owner's words: "and i need them to be reasonably fast on CI". A 27B test takes about 300 s and loads 14 GB. That does not fit CI.

    Decision (recorded by the orchestrator under the owner's "decide, don't ask" rule for compaction):
    - The three integration tests run on a small Qwen3-family model. It has the same chat-template behaviour as the 27B: the "user message required" check and the `enable_thinking` switch. Pick the smallest mlx-community Qwen3 instruct model that writes a non-empty summary for the three cases, for example `mlx-community/Qwen3-0.6B-4bit` or `Qwen3-1.7B-4bit`. Record which one and why on this card.
    - Put the model reference in one constant, shared by the three tests. Load it once for the suite.
    - Keep each test to one summarizer call, or one turn with one tool call. Seed the contexts directly and keep the windows small.
    - Target: the three tests together finish in well under a minute after the model load. Record the measured time.
    - Find how CI runs the gated integration suites (`.github/workflows`, or the CI config in the repo). Make the three compaction tests run there, with the model download cached if the workflow supports it. If CI cannot run a real model at all, record that and make the tests runnable with one documented command.
    - The Qwen3.8-27B tests from ^9ddjkjm and ^dvyt1dx stay as local checks. Name them so that the CI filter does not select them.
  timestamp: 2026-09-23T16:50:44.723563+00:00
- actor: claude-code
  id: 01m37jw33777m9hwgaxfp5cqkv
  text: |-
    ### owner correction (2026-09-23): stay on Qwen3.8-27B; make the tests small, not the model

    This comment REPLACES the "small Qwen3-family model" part of the comment above. The owner's words: "i'm not sure a 'smaller model' is the answer, qwen 27B is small."

    - The three integration tests run on `mlx-community/Qwen3.8-27B-mxfp4`. Keep it in one shared constant, and load it once for the suite.
    - The 300 s of the ^9ddjkjm run came from the test shape: a context of 16,070 tokens and a full tool turn. The speed comes from a small test shape instead:
      - seed each context directly, with a few hundred tokens;
      - set the window (a test number) so that this small context is over the trigger;
      - reasoning off for the summarizer call (commit 549642c already does this);
      - case 1 and case 3: one summarizer call (case 3 adds the one turn the owner asked for, with a short answer);
      - case 2: one turn, one tool call, and a small tool result that crosses the trigger.
    - Target: the three tests together take seconds after the model load. Record the measured time for each test on this card.
    - Shrink the existing ^9ddjkjm test to this shape, or replace it. Do not keep a 16,000-token version.
    - CI: make the three tests run where CI runs the gated suites, with the model cached. If CI cannot hold the 27B, record the reason, and give one documented command that runs them.
  timestamp: 2026-09-23T16:51:36.679499+00:00
position_column: todo
position_ordinal: '8180'
title: 'Compaction test suite: unit and gated integration tests for the three compaction cases, all run by the suites'
---
## Decision (from the owner, 2026-09-23)

"i don't need a one off run, i need real unit and integration tests". Compaction is proven by tests that live in the suites and run with them, not by runs recorded on cards.

## The three cases (the owner's list)

1. **We can compact.** A live context is compacted by one call.
2. **A tool call triggers a compaction.** Inside a turn, a tool result crosses the trigger, one compaction runs, and the same turn answers.
3. **A long context compacts.** A small window (a test number), a context over the trigger at the start of a turn: the compaction runs before the turn, and the turn answers.

## Do this

1. **Unit tests** (scripted model, always run, in `Tests/FoundationModelsRouterTests`): confirm each case has a unit test. Case 1: `OneCallCompactionTests`. Case 2: `ToolResultCompactionTests`. Case 3: find the turn-start test in `AutoCompactionTests`; if none asserts "context over the trigger at turn start → one compaction before the turn → the turn answers → the snapshot is smaller", add it. Keep each test short.
2. **Integration tests** (real Qwen3.8-27B, in `IntegrationTests`, gated the same way as the other real-model suites): one test per case, each short (at most one turn and one tool call; the context is built directly, not generated).
   - Case 1: `Qwen38CompactionIntegrationTests` "one compaction of a built live context" exists. Keep it.
   - Case 2: `Qwen38ToolResultCompactionIntegrationTests` exists. Keep it.
   - Case 3: add it, in the same file as case 1 or next to it.
   Share the model load across the three (one load, not three), so the suite runs in about the time of its model calls.
3. **Run the gated suite** with the filter that selects these three tests, and make it pass. A failure is a fault to fix, in the code or in the test's sizing. Do not loosen an assertion about compaction (a summary with text, a smaller snapshot, the compaction event, the answer). Tool-call count is not an assertion.
4. Document in the `IntegrationTests` README (or the file that lists the gated suites) the one command that runs the three compaction tests.

## Rules

No invented numbers in `Sources/`; numbers in tests stay in tests. Use the `files` tool for edits. Decide design points yourself and record them here.

## Acceptance

- `swift test` passes and includes the three unit tests.
- The gated command runs the three integration tests, and all three pass on Qwen3.8-27B. The run time is recorded on this card.

#compaction
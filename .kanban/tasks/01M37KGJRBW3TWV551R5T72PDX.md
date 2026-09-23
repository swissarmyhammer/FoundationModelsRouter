---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: After a turn-start compaction, Qwen3.8-27B does not use the summary to answer
---
## Finding (from ^yyjvyga, 2026-09-23)

In the gated test "a long context compacts" (`Qwen38CompactionIntegrationTests`), a seeded context compacts before the turn. The summary keeps the fact: "Key value: Port 6543." The turn prompt asks "Which port does the staging database listen on?". The model answers: "I do not have access to your specific infrastructure configuration, so I cannot tell you which port your staging database listens on."

The test passes, because it asserts only that the answer is not empty.

## Do this

1. Find how the summary entry reaches the model after a compaction (the entry type, the chat template role, the text around the summary).
2. Find why the model does not treat the summary as its own context.
3. Fix the cause, and add an assertion to the gated test that the answer holds "6543".

#compaction
---
depends_on:
- 01KY7E2TP9DBGFV8RJJJKDAE4B
position_column: todo
position_ordinal: '9480'
title: Tool-output capping in the interop tool loop (TokenBudget.toolOutputLimit)
---
Harness plan §5.1 seam 2 absorbed — better here than any wrapper: tool OUTPUTS are what blow windows mid-turn, and Router's interop tool loop sees each result before the model does. Add toolOutputLimit to TokenBudget; oversized results truncate with an explicit marker ('… [truncated: N of M tokens]') and the truncation reflects in the toolStatus stream event — never silent. Replaces the harness's ObservedTool capping job (the event-emission job is the rich-stream task).
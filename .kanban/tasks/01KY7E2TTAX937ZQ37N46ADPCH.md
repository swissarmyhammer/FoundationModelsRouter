---
depends_on:
- 01KY7E2TP9DBGFV8RJJJKDAE4B
position_column: doing
position_ordinal: '80'
title: 'Rich session event stream: text/reasoning/toolCall/toolStatus/compaction/turnEnded'
---
Harness-collapse item (harness plan §4 HarnessEvent absorbed). Add an event-element variant of streamResponse (String-only today): textDelta, reasoningDelta, toolCall(id:name:argumentsJSON:), toolStatus(id:status:summary:), compaction(CompactionResult), turnEnded(TokenUsage). Correlation ids are load-bearing: two concurrent same-name tool calls distinguishable; ids surface 1:1 to consumers (FoundationModelsACPAgent maps them onto ACP toolCallId). The chokepoint already sees all of this as transcript entries.
---
assignees:
- claude-code
position_column: todo
position_ordinal: '9880'
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
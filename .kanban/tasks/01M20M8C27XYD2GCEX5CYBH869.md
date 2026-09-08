---
position_column: todo
position_ordinal: '80'
title: The transcript recorder discards a whole turn on divergence, and it must only append
---
### What

`recordTranscriptDelta` discards a whole turn when its baseline check
fails. There is no case where that is correct. A transcript appends.

Read from `Session/RoutedSessionActorRecording.swift`: when
`TranscriptDiffer.divergence(from:in:)` gives a value, the actor writes
one `divergence` marker, writes **no** diff, and resets the baseline.
Every entry of that turn goes away, and nothing says which entries were
lost.

**Measured cost.** Over 24 transcripts of a 2026-09-07 evaluation run in
`FoundationModelsACPAgent`:

```
toolOutput   409
response      33   (with NO entry: recordFailedTurn appends none)
divergence    29
session       24
instructions  24
prompt         0
toolCalls      0
reasoning      0
```

Not one `prompt`, `toolCalls` or `reasoning` entry in 24 transcripts.
`toolCalls` carries `argumentsJSON`, so the source of every tool call is
gone and a person cannot read what the model asked for.

`emitSessionEvents(for:)` runs over recorded diff partials, and a
divergence makes none, so the wire loses `SessionEvent.toolCall` too.

### The rule

**A transcript only appends. It never discards an entry, for any
reason.**

The turn happened. The record must say so. A divergence is a note ABOUT
the record — it is a second thing to append, never a reason to drop the
first thing.

This card does not ask for the discard to be narrowed, or made
conditional, or kept for a special case. It asks for the discard path to
go away. If a reason to drop an entry is found while doing this work,
stop and write it on this card for a person to judge, because we cannot
think of one.

### What to do

- Delete the branch that writes a marker and no entries. Append the
  turn's entries, then append the `divergence` marker beside them.
- State what the baseline becomes after a divergence, and why. A reset
  that loses entries is not an answer.
- Make `recordFailedTurn` append its `.response` WITH its entry. An
  empty `{}` records nothing and is the same defect in a second place.
- Emit the session events for the appended entries, so the wire carries
  `SessionEvent.toolCall` on this path too.
- Read every other path that can drop an entry, and remove those as
  well. This is one example of the cause, not the whole of it.

- [ ] No path writes a marker and no entries
- [ ] `recordFailedTurn` appends a response that holds its entry
- [ ] The wire carries the tool calls of a diverged turn
- [ ] Every other discarding path is found and removed

### Acceptance Criteria

- [ ] A turn that diverges is recorded whole: its prompt, its
      `toolCalls` with `argumentsJSON`, and its response with an entry.
- [ ] The `divergence` marker stands beside those entries.
- [ ] `SessionEvent.toolCall` reaches the wire for a diverged turn.
- [ ] No code path in the recorder drops a transcript entry.

### Tests

- [ ] A test forces a divergence and asserts the turn's entries are
      appended, and the marker stands beside them.
- [ ] A test asserts a recorded `toolCalls` entry holds its
      `argumentsJSON`.
- [ ] A test asserts `SessionEvent.toolCall` is emitted on the diverged
      path.
- [ ] A test asserts the entry count never falls between two reads of
      one session.

### Why this is separate from its trigger

The companion card asks why the baseline check fails at all. This card
holds whatever that answer turns out to be: the transcript must not lose
a turn for ANY reason. Do the two independently, and land this one even
if the trigger takes longer.

Raised from FoundationModelsACPAgent, card ^jz016kq.
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39nzmvqex441tmf9pg5ynsf
  text: |-
    ### Default values — approval reported by a peer session (2026-09-24)

    The peer session foundationmodelsacpagent-e5 reports that the owner approved these three defaults as configurable starting points. The owner's words, as the peer quoted them: "those seem fine as configurable starting points".

    - window with no new line: 2,048 generated tokens;
    - minimum line length that counts in the test: 20 characters;
    - recoveries per turn: 2.

    Each value stays a configuration value that a host can change. Name each constant in the log.

    Status: this approval came through a peer session, not directly from the user of this session. The user of this session must confirm it before the implementation starts.
  timestamp: 2026-09-24T12:24:27.767396+00:00
position_column: todo
position_ordinal: '8380'
title: Stop a generate call that repeats itself, with a configurable detector and a default
---
## The measurement

Transcript: `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/bench/preds.t90.transcripts/django__django-13964/01M38ATWY3RB45SQSYD5BX53P8/transcript.jsonl`. Model mlx-community/Qwen3.8-27B-mxfp4. The two long calls of ^gfxd7av contain only reasoning, and most of each call repeats itself.

Measured by the peer session:

- seq 132 (reasoning entry seq 131): 162,595 characters, 3,128 lines, 205 distinct. The share of new lines (lines not seen earlier in the same entry), per tenth of the text: 37%, 28%, then 0% for the last eight tenths. Approximately 32,000 of its 39,617 tokens added nothing.
- seq 225 (reasoning entry seq 224): 50,006 characters. New lines per tenth: 91%, 79%, 85%, 76%, 67%, then 0% for the last five tenths.

Measured again in this session (the text split on "\n", blank lines included, tenths by line count):

- seq 131: 162,596 characters, 4,197 lines, 210 distinct. New lines per tenth: 32%, 18%, then 0% for the last eight tenths.
- seq 224: 50,007 characters, 550 lines, 140 distinct. New lines per tenth: 84%, 78%, 49%, 42%, 0%, 0%, 0%, 0%, 0%, 2%.

The two methods split lines in different ways, so the numbers are different. The pattern is the same: the share of new lines goes to zero and stays there.

This is not a cycle of the same text with a fixed period. The model writes the lines that it already wrote again, in a different sequence. The signal that makes it different from normal reasoning: the share of new lines goes to zero and stays at zero.

## Requirements

1. Router monitors the reasoning (and the text) of the call in flight. Router stops the call when the call no longer makes new lines. Router already stops a call when it cancels the task that reads the stream. The engine examines cancellation between tokens.
2. After the stop, recover as for a ceiling stop (^46bz58k): a short prompt that tells the model to act, and a bound on the number of recoveries. The repeated part must NOT go back into the context that the model receives. Keep the part that was new, or remove that reasoning entry from the render. The recorded transcript keeps full fidelity (see ^tpsc0nf decision 3): the full entry stays in the transcript.
3. A configuration value with a default that is on, so that a host changes it only when necessary. For example, a struct next to `TokenBudget` with:
   - `enabled` (default true);
   - the window, in generated tokens, that must contain at least one new line;
   - a minimum line length for the test, so that short lines that repeat by nature (```, """, ")", "...") do not count. In seq 132 the lines that repeated most were these: ``` 226 times, """ 184 times;
   - the number of recoveries per turn.
4. A log line, and a usage or event record, when the detector stops a call. They give the number of tokens that the call generated and the share of new lines, so that a host can see the stop.

## The default values are the user's decision

Rule of this user: each hard-coded limit is the user's decision, one value at a time. Do not choose a default value without the user. Name each constant in the log.

Proposals of the peer (NOT approved):
- window: approximately 2,048 generated tokens. With this value, seq 132 would stop after approximately 8,000 tokens, not 39,617.
- minimum line length: no value proposed.
- recoveries per turn: no value proposed.

Before the implementation, measure the defaults on more runs, write the measurements on this card, and ask the user to approve each value. The two calls above are the first two data points.

## Acceptance

- A test: a stream whose new-line share goes to zero for one full window is stopped, and the log line and the event record are emitted with the token count and the new-line share.
- A test: normal reasoning with repeated short lines (```, """, ")") is not stopped.
- A test: after a stop, the next model call does not receive the repeated part. The recorded transcript still contains the full entry.
- A test: recoveries stop at the configured number per turn.
- A test: `enabled: false` turns off the detector.

## Related

- ^gfxd7av: the question about which ceiling stopped the two long calls.
- ^46bz58k: recovery after a ceiling stop.
- ^tpsc0nf: the render to the model and the full-fidelity transcript.

## Source

A peer session (foundationmodelsacpagent-e5) asked for this card on behalf of the owner. FoundationModelsACPAgent will show the setting in its config.yaml when the Router API exists.
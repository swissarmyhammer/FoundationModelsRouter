---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Detect a repetition loop in the response text before the token ceiling
---
## Problem

Recursive Flint's response text fell into a loop of short apology lines: "I am sorry. I am stopping now. I am not going to do anything else." and "Okay, I am stopping now. I am sorry for the confusion. …", repeated hundreds of times. Generation ran to the 16,384-token ceiling. The repetition watch did not stop it. The transcript shows only one `repeatedPartRemoval`, and it is a `reasoningClosure`, not a response-text stop.

## Evidence

Same transcript as the stray-`</think>` card: `FoundationModelsACPAgent/bench/preds.flint1.transcripts/django__django-13447/01M7DNSKBHGQ8K547VC8M5638S/transcript.jsonl`, seq 707 and 1140 (responses of 63,740 and 61,192 chars), generationCall seq 709 and 1137. Each runaway cost about 2.7 minutes of decode.

The loop is a cycle of two or three near-identical sentences, and some variants differ by a word ("I am truly stopping now" / "I am stopping now"). Find out why `RepetitionDetector` misses it. Candidates:
- the response text is not watched;
- the period or n-gram settings miss a 2–3 sentence cycle;
- the near-identical variants defeat an exact match.

## Wanted

The repetition watch stops a response-text loop like this one well before the ceiling, within a few hundred tokens of the cycle starting. The existing repetition recovery then runs. No false positives on legitimately repetitive text, such as lists or tables: keep the existing detector tests green, and add one for a list of similar lines that must not stop.

## TDD

Write the failing hermetic test first, using the actual apology loop text from seq 707 as a fixture. Done when `swift build --build-tests` and `swift test` are green. No real-model runs.
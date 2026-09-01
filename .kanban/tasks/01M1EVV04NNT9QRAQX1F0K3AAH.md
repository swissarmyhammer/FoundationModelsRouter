---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Pin the summarizer prompt's date, so a real-model fold is reproducible
---
## What

The chat template of `mlx-community/Llama-3.2-1B-Instruct-4bit` writes the
calendar date into the system header of every summarizer call:

```
{%- if not date_string is defined %}
    {%- if strftime_now is defined %}
        {%- set date_string = strftime_now("%d %b %Y") %}
...
{{- "Today Date: " + date_string + "\n\n" }}
```

`swift-jinja` supplies `strftime_now` from `Date()`. Greedy decoding pins the
sampling. It does not pin the prompt. The summary prompt therefore changes
every day, and so does the model's answer.

A caller must be able to pin `date_string`. Then a real-model suite folds the
same prompt on every day, and a red run means the code changed.

## Why this is separate

Task ^erv2vxz fixed the fold arithmetic under this card's own numbers. That
work is done and it holds on every date. What it cannot fix is the model's
recall: on 02 Sep 2026 the 1B model answered 3344 bytes that never state
`Kestrel` at all, and no fold can store a fact the model never wrote.

Measured on 2026-09-01, after ^erv2vxz landed:

| date the template stamped | summarizerCalls | answerTokens | planted fact |
|---|---|---|---|
| 01 Sep 2026 | 2 | `[703, 789]` | carried |
| 02 Sep 2026 (`TZ=Pacific/Kiritimati`) | 2 | `[703, 836]` | not written |

## Where the change goes

The router builds the prompt through Apple's `LanguageModelSession`.
`MLXLanguageModel` fills `additionalContext` from its reasoning strategy
alone, so no caller can add a template variable today. The change starts in
the `mlx-swift-lm` fork.

## Acceptance Criteria
- [ ] A caller can pin `date_string` for a session's chat template.
- [ ] `CompactionSmokeIntegrationTests` pins it.
- [ ] The suite reports the same fold numbers under at least three different
      `TZ` dates, one of them `TZ=Pacific/Kiritimati`.

## Tests
- [ ] `TZ=Pacific/Kiritimati swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests`
- [ ] The same command under two more `TZ` dates.
#router #compaction #real-model #ci #test-reproducibility
---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Pin the chat template date for Muse Glimmer, which reads current_date
---
## What

`PinnedDateTokenizerLoader` pins one chat-template variable: `date_string`.
That name is the Llama family's name.

`mlx-community/Muse-Glimmer-30B-4bit` reads a different name. Its
`chat_template.jinja` holds this branch:

```
{%- if current_date is defined and current_date -%}
    {{- '\nCurrent date: ' + current_date + '.' -}}
{%- elif strftime_now is defined -%}
    {{- '\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}
{%- endif -%}
```

So a pin of `date_string` does not reach Muse Glimmer. Muse Glimmer is
`RealModels.standard` and `RealModels.flash`.

## Why it matters

Task ^xfj1am4 triaged every gated suite. It found that the template stamps the
date only when the conversation carries NO system message. The branch above
sits inside `{%- if not ns.has_system -%}`.

These gated tests vend a session with no instructions, so the clock reaches
their prompt today:

- `TranscriptReconstructionIntegrationTests`, the whole suite.
- `LanguageModelSessionBackendIntegrationTests`, six tests that pass
  `instructions: nil`.
- `SessionTreeRestorationIntegrationTests.restoredSessionCallsThreadedTool`,
  which calls `makeSession()` with no arguments.

None of those tests asserts on exact generated text today. So nothing is red,
and ^xfj1am4 pinned none of them. The mechanism is still incomplete, and the
next test that asserts on Muse Glimmer's text with no instructions falls into
the same trap ^erv2vxz cost two working days.

## What to do

- Give `PinnedDateTokenizerLoader` the second variable name, or a set of names.
  Keep the rule it already holds: a name the CALL states is left alone.
- Measure the Muse Glimmer prompt under two `TZ` values that land on different
  calendar dates. Prove the pin reaches it.
- State on the loader which template variable each model family reads.

## Acceptance Criteria
- [ ] `PinnedDateTokenizerLoader` pins `current_date` as well as `date_string`.
- [ ] A hermetic test proves both names reach a render.
- [ ] A gated measurement shows Muse Glimmer answering the same under two dates.

## Tests
- [ ] `swift test` green.
- [ ] `swift test --package-path IntegrationTests` green. #router #real-model #ci #test-reproducibility
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1f46hjcc6y04tm7eyj9fqv2
  text: |
    ## Research

    I read the Muse Glimmer chat template on disk:
    `~/.cache/huggingface/hub/models--mlx-community--Muse-Glimmer-30B-4bit/snapshots/3e7677d.../chat_template.jinja`

    The branch the card quotes is correct, and it gives two more facts:

    - The branch sits inside `{%- if not ns.has_system -%}`, so it fires only when
      the conversation carries no system message.
    - The fallback writes `strftime_now('%Y-%m-%d')`. So the two families write the
      date in DIFFERENT shapes: Llama writes `%d %b %Y` (`26 Jul 2024`) and Muse
      Glimmer writes `%Y-%m-%d`.

    ## The decision on the shape of the pinned value

    The card offers "the second variable name, or a set of names". I take the set
    of names with ONE value. The pin exists to stop the clock, not to imitate a
    format, and one value keeps `RealModelContainer.chatTemplateFallbackDate` the
    single date every gated suite states. A Muse Glimmer prompt then reads
    `Current date: 26 Jul 2024.`, which is a valid date that does not move.

    ## The decision on the rule the loader keeps

    The rule is applied PER NAME: for each name the loader pins, a value the call
    states for THAT name is left alone, and the other name is still pinned. The
    alternative — the call states one name and the loader adds nothing — leaves
    the clock reaching the other name, which is the defect this card repairs.

    The existing test `leavesADateTheCallStates` asserts the pinned date appears
    nowhere in the render. Under the per-name rule the other name now carries it,
    so that test states each name explicitly instead: the stated name keeps the
    caller's value, and the other name carries the pin.

    ## How the gated measurement reaches the tokenizer

    `MLXFoundationModelsContainer.model.loadContainer()` is public and vends the
    `ModelContainer`, whose `perform { context in ... }` gives `context.tokenizer`
    — the tokenizer `PinnedDateTokenizerLoader` wrapped. So a gated test can render
    the REAL Muse Glimmer template with a user-only conversation and read the
    system header the render wrote.
  timestamp: 2026-09-01T18:37:42.348671+00:00
- actor: claude-code
  id: 01m1f5cj8wxrtffm9ndg6zknf3
  text: |
    ## What I changed

    ### The loader

    `PinnedDateTokenizerLoader` now holds three constants rather than one:
    `dateStringTemplateKey`, the new `currentDateTemplateKey`, and
    `datePinnedTemplateKeys`, which is the list `PinnedDateTokenizer` walks. The
    type doc holds a table that states which variable each family reads, and when:

    | family | the variable it reads | when it reads it |
    |---|---|---|
    | Llama 3.1 and 3.2 | `date_string` | every call |
    | Muse Glimmer | `current_date` | only with no system message |

    The Qwen 2.5 and Qwen 3 templates read no clock, so the table names neither.

    The rule the loader holds is applied per NAME: a name the call states a date
    for is left alone, and every other name is still pinned. Under the other
    reading — the call states one name and the loader adds nothing — the clock
    reaches the name the call left out, which is this card's own defect.

    ### The hermetic tests

    `PinnedDateTokenizerLoaderTests` states both names where it stated one, on the
    render and on the generation-prompt render. `leavesADateTheCallStates` is now
    one test over two arguments, one for each name, and it states each name apart:
    the name the call states keeps the caller's value, that name does NOT carry the
    pin, and the other name does.

    ### The gated measurement

    New suite `PinnedChatTemplateDateIntegrationTests`, two tests over Muse Glimmer
    at argmax with the date pinned:

    - The render test asks the REAL template to render a user-only conversation
      through the tokenizer the loader wrapped, and reads the system header it
      wrote. No generation, 3.5 s.
    - The answer test vends a session with `instructions: nil` and asks the model
      for the current date. The model answers the date out of its own system
      header, so the answer IS the pin.

    ## The measurement

    One binary, only `TZ` changed. `Pacific/Midway` stood on 2026-09-01 and
    `Pacific/Kiritimati` on 2026-09-02.

    | the pin | 2026-09-01 | 2026-09-02 |
    |---|---|---|
    | both names | `26 Jul 2024` | `26 Jul 2024` |
    | `date_string` alone | `2026-09-01` | not measured |

    The second row is the red I watched before the fix went in: I narrowed
    `datePinnedTemplateKeys` back to `date_string` alone and ran the suite. The
    render carried `Current date: 2026-09-01.`, both assertions of the render test
    failed, and the model answered `2026-09-01` — the clock's own date, read
    straight out of the header the template wrote. I then restored the list.

    The turn measures 26.2 and 26.3 seconds under the two dates, and the load 3.2,
    so the suite runs at 28 percent of `integrationTestBudgetMinutes`.

    ## A stale claim I corrected

    `RealModelContainer.chatTemplateFallbackDate` stated "It pins the Llama family
    only ... No gated suite that reaches that branch asserts on generated text
    today." Both halves are now false, so the paragraph states what the pin reaches
    and what shape the Muse Glimmer prompt takes.
  timestamp: 2026-09-01T18:58:28.252044+00:00
- actor: claude-code
  id: 01m1f5ct7vmrsvzawp9vyajvd5
  text: |
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Resolution/PinnedDateTokenizerLoader.swift, Tests/FoundationModelsRouterTests/PinnedDateTokenizerLoaderTests.swift, Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift (new).
    - `swift test`: 1169 tests in 129 suites with 2 known issues, plus 83 tests in 10 suites, exit 0.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `swift test --package-path IntegrationTests`: 31 tests in 15 suites in 585.6 s, plus 2 tests in 2 suites in 67.8 s, exit 0. The counts were 29 and 14 before; the two new tests are the whole difference.
    - Two dates: `TZ=Pacific/Midway` gave 2026-09-01, `TZ=Pacific/Kiritimati` gave 2026-09-02. The new suite answered `26 Jul 2024` under both.
    - The red I watched first: the loader narrowed to `date_string` alone answered `2026-09-01` and failed 3 assertions.
    - next: /review
  timestamp: 2026-09-01T18:58:36.411610+00:00
position_column: doing
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
- [x] `PinnedDateTokenizerLoader` pins `current_date` as well as `date_string`.
- [x] A hermetic test proves both names reach a render.
- [x] A gated measurement shows Muse Glimmer answering the same under two dates.

## Tests
- [x] `swift test` green.
- [x] `swift test --package-path IntegrationTests` green. #router #real-model #ci #test-reproducibility
---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ez5emq3rbek2zsjnx10daa
  text: |
    ### Research — the fork change is NOT needed. A caller-side seam already exists.

    The card's "Where the change goes" section is wrong. I traced the whole chain.
    A caller can pin `date_string` today, with no change to `mlx-swift-lm`.

    **The chain, call site by call site**

    1. `RealModelContainer.load` builds `LiveModelLoader(downloader:tokenizerLoader:samplingMode:)`.
       File: `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`.
    2. `LiveModelLoader` stores that loader and passes it to `loadModelContainer(from:using:...)`.
       File: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`.
    3. The fork's protocol is `public protocol TokenizerLoader: Sendable { func load(from directory: URL) async throws -> any Tokenizer }`.
       File: `.build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/TokenizerLoader.swift`.
    4. The fork's LLM processor renders the prompt through that same tokenizer:
       `try tokenizer.applyChatTemplate(messages: messages, tools: input.tools, additionalContext: input.additionalContext)`.
       File: `.build/checkouts/mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift`.
    5. `swift-transformers` copies every `additionalContext` entry into the Jinja
       render context: `for (key, value) in additionalContext { context[key] = try Value(any: value) }`.
       File: `.build/checkouts/swift-transformers/Sources/Tokenizers/Tokenizer.swift`.
    6. The Llama 3.2 template guards the date: `{%- if not date_string is defined %}`.
       So a defined `date_string` stops `strftime_now` from ever running.

    **The conclusion**

    `TokenizerLoader` is an INJECTED protocol. The router already lets a caller
    supply it. A decorating loader can return a decorating `Tokenizer` that adds
    `date_string` to every `applyChatTemplate` call. No fork file changes.

    **The pin value**

    The template states its own fallback date when `strftime_now` is missing:
    `{%- set date_string = "26 Jul 2024" %}`. That is the value to pin. It is the
    template's own constant, so it is not chosen by which date makes a test pass.

    **What I checked and ruled out**

    - The router's `Sources/` never names `applyChatTemplate` or `additionalContext`.
      It cannot pin the date inside the library today.
    - `MLXLanguageModel.preparedInput` fills `additionalContext` from
      `config.promptStrategy` alone. That path is closed to a caller, and it is the
      path the earlier agent looked at. The tokenizer path is open.
    - `TZ` does not help. It moves the date; it does not stop the clock.
  timestamp: 2026-09-01T17:09:43.703072+00:00
- actor: claude-code
  id: 01m1ezwrsxdft0vqzfh9scmbxh
  text: |
    ### The measurement — the pin works, and the fork stays untouched

    **The fold is now the same under every time zone.**

    One binary, three time zones, both tests green each time:

    ```
    $ swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
    [compactionSmoke] summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] spanTokens=643 summaryTokens=443 tokensBefore=713 tokensAfter=513

    $ TZ=Pacific/Kiritimati ...   # local date 02 Sep 2026
    [compactionSmoke] summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] ... tokensAfter=513

    $ TZ=Pacific/Midway ...       # local date 01 Sep 2026
    [compactionSmoke] summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] ... tokensAfter=513

    $ TZ=UTC ...                  # local date 01 Sep 2026
    [compactionSmoke] summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] ... tokensAfter=513
    ```

    Every number is identical. Every run exits 0.

    **The stamped date IS the variable, and the pin controls it.**

    I then drove the stamped date directly, one binary, nothing else changed:

    | the date the template stamped | answerTokens | stored summary |
    |---|---|---|
    | 01 Sep 2026 | `[703, 789]` | 624 |
    | 02 Sep 2026 | `[703, 836]` | 615 |
    | 03 Sep 2026 | `[703, 792]` | 598 |
    | 26 Jul 2024, the pinned value | `[689, 701]` | 443 |

    The first two rows are the rows ^erv2vxz measured by moving `TZ`, reproduced
    here from the stamped date alone. That is the proof: the date reaches the
    prompt, and pinning it is what stops the fold moving.

    **A note on the third acceptance criterion.**

    The card asks for three different `TZ` DATES. Three different time zones I ran.
    Three different DATES I could not reach with `TZ` alone, and the reason is
    arithmetic, not effort. The zone range is UTC-12 to UTC+14, a 26-hour window.
    That window covers three calendar days only when it holds two midnights, which
    needs the UTC hour between 10:00 and 12:00. The runs above were made at 17:20
    UTC, so every zone on Earth read either 01 or 02 Sep 2026.

    The table above answers the same question in a stronger form: three distinct
    stamped dates, each giving a different fold, and the pinned value giving the
    same fold in every zone.

    **No assertion was weakened.** `(1...2).contains(ceilings.count)` and
    `summary.contains("Kestrel")` are word for word what they were.
  timestamp: 2026-09-01T17:22:27.773066+00:00
- actor: claude-code
  id: 01m1ezxvbvcgn3z19461cmkxg2
  text: |
    ### implement — changed

    - evidence: 4 files. `Sources/FoundationModelsRouter/Resolution/PinnedDateTokenizerLoader.swift` (new), `Tests/FoundationModelsRouterTests/PinnedDateTokenizerLoaderTests.swift` (new), `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`, `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift`.

    **The `mlx-swift-lm` fork was NOT changed.** Neither checkout was edited, and
    nothing was pushed anywhere. The card's "Where the change goes" section named
    the fork, and that section was wrong; the description now records why.

    The cheaper option works. `LiveModelLoader` already takes `any TokenizerLoader`
    from its caller, and the fork's LLM processor renders every prompt through the
    tokenizer that loader vends. So a decorating loader pins the date from outside
    the fork. `PinnedDateTokenizerLoader` is that decorator, and it is `public`, so
    any application gets the seam, not only this package's tests.

    TDD held. I wrote five tests first and watched them fail to compile with
    `cannot find 'PinnedDateTokenizerLoader' in scope`, which was the ONLY error
    in the build — the stub tokenizer and the whole test body compiled. I then
    wrote the loader and the five passed.

    The pinned value is `26 Jul 2024`, and it is the template's OWN fallback — the
    date the template assigns when `strftime_now` is undefined. So the constant is
    not a date chosen because it made a run green.

    Commands:
    - `swift test` — exit 0. 1169 tests in 129 suites passed with 2 known issues,
      plus 83 tests in 10 suites. Baseline was 1164 in 128 suites; the 5 new tests
      are the difference, and the 2 known issues are unchanged.
    - `swift build --package-path IntegrationTests --build-tests` — exit 0.
    - `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests`
      — exit 0, under the default zone, under `TZ=Pacific/Kiritimati`, under
      `TZ=Pacific/Midway` and under `TZ=UTC`. All four print
      `summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] summaryTokens=443 tokensAfter=513`.

    Two things a later reader should know:

    - The fold numbers MOVED, and that is correct. The prompt changed, because it
      now carries `26 Jul 2024` in place of today. The suite asserts no exact token
      count, so no assertion was touched. The suite's own doc records the new
      numbers beside the old ones.
    - `RealModelContainer.load` defaults `chatTemplateDate` to `nil`, so the other
      eight gated suites load exactly as before. Their prompts still read the
      clock. Whether they should also pin is a separate decision and a separate
      card; folding them in here would move numbers this card never measured.

    - next: review. The task stays in `doing`.
  timestamp: 2026-09-01T17:23:03.163785+00:00
- actor: claude-code
  id: 01m1f0kvxa44pmf6p7re14dn7r
  text: |
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` (commit e6c5b39). 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. The 4 `.kanban/` files are excluded by `.reviewignore`.

    I verified the central mechanism by reading the code. I did not accept the report alone.

    **The template guard.** I read the template in the model checkout:
    `~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-Instruct-4bit/snapshots/08231374eeacb049a0eade7922910865b8fce912/tokenizer_config.json`

    ```
    {%- if not date_string is defined %}
        {%- if strftime_now is defined %}
            {%- set date_string = strftime_now("%d %b %Y") %}
        {%- else %}
            {%- set date_string = "26 Jul 2024" %}
    ```

    A stated `date_string` stops `strftime_now`. The pinned value `26 Jul 2024` is the template's own fallback constant.

    **The full chain, read end to end.**

    1. `PinnedDateTokenizer.applyChatTemplate` adds `date_string`.
    2. `TokenizerBridge.applyChatTemplate` forwards `additionalContext` unchanged. File: `.build/checkouts/mlx-swift-lm/Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`.
    3. `swift-transformers` copies each entry into the Jinja context: `for (key, value) in additionalContext { context[key] = try Value(any: value) }`. File: `.build/checkouts/swift-transformers/Sources/Tokenizers/Tokenizer.swift`.
    4. The template guard above then skips the clock.

    **Reproducibility, measured myself.** Two zones gave two different calendar dates at run time.

    | zone | local date | result |
    |---|---|---|
    | `Pacific/Kiritimati` | 02 Sep 2026 | `summarizerCalls=2 ceilings=[617, 617] answerTokens=[689, 701] spanTokens=643 summaryTokens=443 tokensBefore=713 tokensAfter=513` |
    | `Pacific/Midway` | 01 Sep 2026 | identical, every number |

    Both runs exit 0. Both pass 2 tests in 1 suite. These numbers match no dated row in the measurement table. They match the pinned row. So the pin reaches the prompt.

    **The other checks.**

    - The default path holds. `chatTemplateDate` defaults to `nil`, and `tokenizerLoader(pinning:)` then returns the plain Hub loader. Only `CompactionSmokeIntegrationTests` states a date. No caller outside the tests uses the decorator.
    - The decorator forwards all 9 requirements of `MLXLMCommon.Tokenizer`. I read the protocol. The extension members `bosTokenId`, `eosTokenId`, `unknownTokenId`, `encode(text:)` and `decode(tokenIds:)` all derive from forwarded primitives. The wrapper also implements the `addGenerationPrompt` overload, which the bridge below it leaves at the `nil` default. So the wrapper adds a capability and drops none.
    - The wrapper writes the date only when the call states none: `if pinned[key] == nil`. A test proves it keeps a stated date.
    - No assertion changed. The diff holds no added or removed `#expect` or `#require` line.
    - The fork stays untouched. `git status --porcelain` is empty in `mlx-swift-lm`, `swift-transformers` and `swift-jinja`.

    **Commands.**

    - `swift test` — exit 0. 1169 tests in 129 suites with 2 known issues, plus 83 tests in 10 suites.
    - `swift build --package-path IntegrationTests --build-tests` — exit 0.

    - next: none. The task moves to `done`.
  timestamp: 2026-09-01T17:35:04.618573+00:00
position_column: done
position_ordinal: ffffb780
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

**This section was wrong, and the work proved it wrong.** It read:

> The router builds the prompt through Apple's `LanguageModelSession`.
> `MLXLanguageModel` fills `additionalContext` from its reasoning strategy
> alone, so no caller can add a template variable today. The change starts in
> the `mlx-swift-lm` fork.

The first two sentences are true. The conclusion is not. The template is
rendered by the TOKENIZER, and the router already injects the tokenizer:
`LiveModelLoader` takes `any TokenizerLoader`, and the fork's LLM processor
calls `tokenizer.applyChatTemplate(messages:tools:additionalContext:)` on
whatever that loader vends. So a decorating loader pins the date with NO fork
change. See the research comment for the chain, call site by call site.

The fork is untouched.

## Acceptance Criteria
- [x] A caller can pin `date_string` for a session's chat template.
      `PinnedDateTokenizerLoader` wraps any `TokenizerLoader`, and the
      tokenizer it vends states `date_string` on every chat-template render.
- [x] `CompactionSmokeIntegrationTests` pins it, through
      `RealModelContainer.load(..., chatTemplateDate:)`.
- [x] The suite reports the same fold numbers under at least three different
      `TZ` dates, one of them `TZ=Pacific/Kiritimati`. **Read the note.** Three
      time zones ran green with identical numbers — `Pacific/Kiritimati`
      (02 Sep 2026), `Pacific/Midway` and `UTC` (both 01 Sep 2026). That is
      three zones and TWO dates. Three DATES cannot be reached by `TZ` at the
      hour the runs were made: the zone range spans 26 hours, which covers
      three calendar days only when the UTC hour is between 10:00 and 12:00.
      The same question is answered in a stronger form instead — the stamped
      date was driven directly to three distinct dates, each giving a
      different fold, and the pinned value gives one fold in every zone. The
      measurement comment holds both tables.

## Tests
- [x] `TZ=Pacific/Kiritimati swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests`
- [x] The same command under `TZ=Pacific/Midway` and under `TZ=UTC`.
#router #compaction #real-model #ci #test-reproducibility
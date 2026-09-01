---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1f2j04s0na0mc7hhndzg208
  text: |
    ## Triage of every gated suite

    I read every gated suite in `IntegrationTests/`. I asked one question for each
    suite. Does a red run mean the code changed, or can it mean the date changed?

    ### A second fact the card does not state

    The date reaches a prompt only if the model's chat template reads the clock. I
    read the chat template of every model the gated suites drive. Three families
    behave differently.

    | model | clock in the template | variable |
    |---|---|---|
    | `Llama-3.2-1B-Instruct-4bit` | yes, always | `date_string`, `strftime_now` |
    | `Qwen2.5-3B-Instruct-4bit` | no | none |
    | `Qwen3-4B-4bit` | no | none |
    | `Muse-Glimmer-30B-4bit` (`RealModels.standard`) | yes, but only with NO system message | `current_date`, `strftime_now` |

    The Qwen templates hold no date word at all. I searched each template for every
    identifier that holds `date`, `now`, `time` or `today`. Both Qwen templates
    returned an empty list.

    `Muse-Glimmer-30B-4bit` keeps its template in `chat_template.jinja`. It stamps
    `Current date:` only inside its `{%- if not ns.has_system -%}` branch. A suite
    that states `instructions:` supplies a system message. That suite gets no date.
    A suite that states `instructions: nil` gets one.

    `PinnedDateTokenizerLoader` pins `date_string`. Muse Glimmer reads
    `current_date`. So today's pin cannot reach Muse Glimmer. I record this gap
    below.

    ### The verdict for each suite

    | suite | model | asserts on generated text? | can the date reach it? | verdict |
    |---|---|---|---|---|
    | `CompactionSmokeIntegrationTests` | Llama-3.2-1B | yes, fold numbers and a planted fact | yes | ALREADY PINNED |
    | `RecordedTranscriptCompactionIntegrationTests` | Llama-3.2-1B | yes, summary tokens against span tokens | yes | PIN |
    | `AutoCompactionTriggerIntegrationTests` | Llama-3.2-1B | yes, context fill across the turn | yes | PIN |
    | `CancelledGenerationTeardownIntegrationTests` | Llama-3.2-1B | no, only that a reply is not empty | yes | no pin |
    | `MetalLibraryBootstrapIntegrationTests` | none | no, it adds four integers on the GPU | no | no pin |
    | `CompactionRoundTripIntegrationTests` | Qwen2.5-3B | yes, it recalls `CRIMSON-77` | no | no pin |
    | `SessionTreeRestorationIntegrationTests` | Qwen2.5-3B and Muse Glimmer | yes, it recalls `42` on the Qwen | Qwen no; Muse yes on one test | no pin |
    | `PropagationProbeIntegrationTests` | Qwen3-4B | yes, the tool call and its token | no | no pin |
    | `RealToolTurnComparisonTests` | Qwen3-4B | yes, two markers in the answer | no | no pin |
    | `RecordingHandleIntegrationTests` | Muse Glimmer, with instructions | no, event kinds and identity | no | no pin |
    | `TranscriptReconstructionIntegrationTests` | Muse Glimmer, no instructions | no, kinds and counts match the live run | yes | no pin |
    | `LanguageModelSessionBackendIntegrationTests` | Muse Glimmer | recall tests state instructions; date-reached tests assert kinds and counts | mixed | no pin |
    | `CompactionSpikeIntegrationTests` | Muse Glimmer, with instructions | yes, it recalls `42` | no | no pin |
    | `IntegrationTests` | Muse Glimmer, with instructions | no, guided keys and non-empty replies | no | no pin |
    | `CompactionEvaluationIntegrationTests` | Qwen2.5-3B | yes, fact retention shares | no | no pin |
    | `CompactionContinuityEvaluationIntegrationTests` | Qwen2.5-3B | yes, fact retention shares | no | no pin |

    No suite is undecided.

    ### The measurement that settles the two pins

    I ran both suites unpinned, one binary, only `TZ` changed.

    `Pacific/Midway` gave 01 Sep 2026. `Pacific/Kiritimati` gave 02 Sep 2026.

    `RecordedTranscriptCompactionIntegrationTests`:

    | date | summarizer calls | answerTokens | stored summary | transcript |
    |---|---|---|---|---|
    | 01 Sep 2026 | 6 | `[864, 806, 650, 708, 863, 756]` | 756 | 4297 -> 2687 |
    | 02 Sep 2026 | 5 | `[830, 715, 650, 626, 722]` | 722 | 4297 -> 2653 |

    One calendar day bought a whole extra generation. The suite doc claims three
    identical runs. That claim holds only inside one day.

    `AutoCompactionTriggerIntegrationTests`:

    | date | replyCharacters | fold | context fill |
    |---|---|---|---|
    | 01 Sep 2026 | 143 | 733 -> 438 | 0.167 -> 0.114 |
    | 02 Sep 2026 | 136 | 733 -> 438 | 0.167 -> 0.114 |

    The fold held on these two dates. The turn's own reply did not. That reply
    enters the transcript, and the fourth assertion reads the transcript. The suite
    doc already records a day when that assertion went red on a fold that saved too
    little.

    ### A gap this card found, for a new card

    `PinnedDateTokenizerLoader` pins only `date_string`. `Muse-Glimmer-30B-4bit`
    reads `current_date`. A suite that drives Muse Glimmer with `instructions: nil`
    therefore still takes the clock into its prompt. No such suite asserts on
    generated text today, so nothing is red. The mechanism is incomplete all the
    same.
  timestamp: 2026-09-01T18:09:00.569318+00:00
- actor: claude-code
  id: 01m1f3h7vg0559j7xey5p8kr6t
  text: |
    ## What I changed

    I pinned two suites. I did not pin the other thirteen.

    ### The shared constant

    `RealModelContainer.chatTemplateFallbackDate` now holds `26 Jul 2024`. It is
    the Llama template's own fallback date. Its doc comment states why the value is
    the template's own, and not a date chosen to make a run green.

    Three suites pin the date, so one constant replaces three copies.
    `CompactionSmokeIntegrationTests` had a private copy from task ^f0k3aah. That
    copy now reads the shared constant, and its own measurement table stays where
    it is.

    ### The two pins

    `RecordedTranscriptCompactionIntegrationTests` and
    `AutoCompactionTriggerIntegrationTests` each state their own
    `chatTemplateDate` constant. Each constant's doc comment records the two-date
    measurement that argues for the pin. Each suite doc comment records the numbers
    the suite reports now.

    I weakened no assertion. I widened no bound. I skipped no test.

    ## The numbers each pinned suite reports now

    `RecordedTranscriptCompactionIntegrationTests`, measured 2026-09-01:

    | what the run measured | value |
    |---|---|
    | the folded span | 2366 |
    | summarizer calls | 4, each at a ceiling of 628 |
    | what the model answered, per call | 793, 679, 708 and 661 |
    | the stored summary | 661 |
    | the fold's transcript | 4297 -> 2592 |
    | wall clock | 19.1 s, of which 1.8 s the load |

    `AutoCompactionTriggerIntegrationTests`, measured 2026-09-01:

    | what the run measured | value |
    |---|---|
    | the synthetic trigger, in tokens | 82 |
    | context fill before the turn | 0.167236328125 |
    | context fill after the turn | 0.1142578125 |
    | the fold's transcript | 733 -> 426 |
    | the turn's own reply | 147 characters |
    | wall clock | 7.2 s, of which 1.8 s the load |

    Both suites reported exactly those rows under both dates. The clock no longer
    reaches either fold.

    `CompactionSmokeIntegrationTests` reported `answerTokens=[689, 701]` and a
    stored summary of 443 under both dates. That is the row its doc comment already
    holds, so moving its constant changed nothing.

    ## The follow-up card

    I raised `^g8rywv2`. `PinnedDateTokenizerLoader` pins `date_string` only, and
    Muse Glimmer reads `current_date`. The card states the branch, the three gated
    tests the clock still reaches, and why none of them is red today.
  timestamp: 2026-09-01T18:26:04.272455+00:00
- actor: claude-code
  id: 01m1f3hfrgzk8t7brvntw69gzw
  text: |
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordedTranscriptCompactionIntegrationTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift
    - `swift test`: 1169 tests in 129 suites with 2 known issues, plus 83 tests in 10 suites, exit 0.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `swift test --package-path IntegrationTests`: 29 tests in 14 suites in 550.5 s, plus 2 tests in 2 suites in 66.4 s, exit 0.
    - Two dates: `TZ=Pacific/Midway` gave 01 Sep 2026, `TZ=Pacific/Kiritimati` gave 02 Sep 2026.
    - Both pinned suites and the smoke suite reported identical numbers under both dates.
    - next: /review
  timestamp: 2026-09-01T18:26:12.368715+00:00
position_column: doing
position_ordinal: '80'
title: Decide which other gated suites must pin the chat template's date
---
## What

Task ^f0k3aah gave every caller a way to stop a chat template reading the
clock: `PinnedDateTokenizerLoader`, reached through
`RealModelContainer.load(ref:context:samplingMode:chatTemplateDate:)`.

Only `CompactionSmokeIntegrationTests` passes a date. The parameter defaults to
`nil`, so the other gated suites still put today's date into every prompt.

## Why it matters

The defect ^f0k3aah fixed was not special to compaction. The Llama family
stamps `Today Date: <today>` into every system header, and `strftime_now` reads
the clock. Any suite that asserts on the exact text a model wrote is a new
sample on every calendar day. ^erv2vxz measured that costing two whole working
days before anyone found the cause.

## What to do

Read each gated suite in `IntegrationTests/`. For each one, answer one
question: does a red run mean the code changed, or can it mean the date
changed?

- A suite that asserts on exact generated text, or on numbers derived from it,
  must pin the date.
- A suite that asserts only that something ran, or that a value is in a wide
  range, does not need it.

Pin the ones that need it, one at a time, and record the fold numbers each one
reports before and after. The numbers WILL move, because the prompt moves.

## Acceptance Criteria
- [x] Every gated suite is listed, with the answer to the question above.
- [x] Each suite that needs the pin has it.
- [x] Each pinned suite's new numbers are recorded in its own doc comment.

## Tests
- [x] `swift test --package-path IntegrationTests` green.
- [x] Each pinned suite green under two different `TZ` dates.
#router #real-model #ci #test-reproducibility
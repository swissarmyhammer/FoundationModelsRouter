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
- actor: claude-code
  id: 01m1hz138brqkapvyye4r4fr6j
  text: |-
    ### review — findings
    - evidence: `review sha fc40844..37c7942` — 2 findings (2 confirmed, 0 refuted) — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:168, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:190
    - next: Remove the `print(…)` calls from the new integration test file. Log to the logging system, or silence each debug-only line with `// swiftlint:disable:next no_direct_standard_out_logs` and the reason. Then run `/review ^g8rywv2` again.
  timestamp: 2026-09-02T21:05:04.267598+00:00
- actor: claude-code
  id: 01m1hz49s0jwvjvkpf50pgh02t
  text: |-
    ### finish iteration 1 — review: findings
    - implement: changed — carried from 2026-09-01, commit 37c7942; 4 files, see the "### implement — changed" comment
    - test: green — carried from 2026-09-01, commit 37c7942; `swift test`: 1169 tests in 129 suites with 2 known issues, plus 83 tests in 10 suites, exit 0; `swift build --package-path IntegrationTests --build-tests`: exit 0; `swift test --package-path IntegrationTests`: 31 tests in 15 suites, plus 2 tests in 2 suites, exit 0
    - commit: 37c7942 (carried from 2026-09-01)
    - review: findings — `review sha fc40844..37c7942`, 2 findings, 2 confirmed, 0 refuted: IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:168 no_direct_standard_out_logs (print); IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:190 no_direct_standard_out_logs (print)
  timestamp: 2026-09-02T21:06:49.248220+00:00
- actor: claude-code
  id: 01m1hzbjz7ppbzgefn2vv457qj
  text: |-
    ## Research for the two review findings

    Both findings are `no_direct_standard_out_logs` on the two `print(...)` calls in
    `PinnedChatTemplateDateIntegrationTests.swift`. The file holds no other
    `print(`, `debugPrint(` or `dump(` call.

    The rule offers two doors: a dedicated logging system, or
    `// swiftlint:disable:next no_direct_standard_out_logs` directly above the line
    with the reason after it. I looked for a logging path the target can use:

    - `os.Logger` through `makeModuleLogger` writes to the unified log, not to the
      piped run output. The `phaseLabel` doc says a grep collects the run table's
      per-test measurements out of that output, so a Logger would lose the line.
    - `CompactionEvalProgressLog.emit` lives in `FoundationModelsRouterEvalSupport`.
      The `FoundationModelsRouterIntegrationTests` target does not link that
      product, and the helper's own `print` has no directive either.
    - Every other gated suite in the target (`IntegrationTests.swift`,
      `LanguageModelSessionBackendTests.swift`, `PropagationProbeIntegrationTests.swift`)
      prints its phase line with a bare `print` and a `[<phaseLabel>]` tag. That is
      the convention the file already matched, and it is the thing the rule names.

    So the fix is the directive on each of the two lines, with the reason after it.
    The repository holds no earlier directive of this rule, so this is the first.

    ## Measurement

    swiftlint 0.65.0 with the rule's own regex and `match_kinds: [identifier]`:

    | file | findings |
    |---|---|
    | `PinnedChatTemplateDateIntegrationTests.swift` after the fix | 0 |
    | `PropagationProbeIntegrationTests.swift`, the same shape with no directive | 2 |

    The second row shows the rule was armed while the first row measured 0.
  timestamp: 2026-09-02T21:10:48.039662+00:00
- actor: claude-code
  id: 01m1hzbsv3c0y5zdyw5238yc73
  text: |-
    ### implement — changed
    - evidence: 1 file — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift (+2 lines: a `// swiftlint:disable:next no_direct_standard_out_logs <reason>` directive directly above each of the two `print` calls).
    - Both review findings of 2026-09-02 16:02 are checked.
    - `swift build --package-path IntegrationTests --build-tests 2>&1`: exit 0, 0 warnings from this repository (only the `missing creator for mutated node` line, which is not from this repository). Run after a `touch` of the file, and a `-v` run showed the file compiled.
    - `swift build 2>&1` at the root: exit 0, 0 warnings from this repository.
    - swiftlint 0.65.0 with the rule's regex: 0 findings on the fixed file, 2 on `PropagationProbeIntegrationTests.swift` as the armed control.
    - Not run: `swift test --package-path IntegrationTests` (11 minutes, real models); the change is a comment-only diff under `IntegrationTests/`.
    - next: /test
  timestamp: 2026-09-02T21:10:55.075617+00:00
- actor: claude-code
  id: 01m1j1yxs30bnqh4da7371d40w
  text: |-
    ### test — red

    - `swift build 2>&1` — exit 0. No warning from this repository.
    - `swift test 2>&1` — exit 0. 1216 tests in 131 suites passed, with 2 known issues. Plus 83 tests in 10 suites passed. No warning from this repository.
    - `swift build --package-path IntegrationTests --build-tests 2>&1` — exit 0. No warning from this repository.
    - `swift test --package-path IntegrationTests 2>&1` — exit 1. 34 tests in 17 suites, 1 test failed. Plus 2 tests in 2 suites passed. No warning from this repository.

    Failing test: "a fact planted at the very end of the folded span is still in the summary the fold stores", in `CompactionSmokeIntegrationTests.swift`. The fold drops the word "Kestrel" from the stored summary.

    This failure comes from old code. It does not come from the change on this card. The change on this card is only the two `swiftlint:disable:next` comment lines in `PinnedChatTemplateDateIntegrationTests.swift`.

    I ran the failing test three times, alone and inside the full gated run. Each run failed the same way. The failure is real, not random.

    I did not edit any source file to fix it. A real fix must choose between two rules that each have their own test already. I wrote the full finding on a new card, ^3dy1ry9, for a person to decide.

    I also saw one other gated test fail on the first full run: the time-limit test in `CompactionSpikeIntegrationTests.swift`. I ran that test alone. It passed in 16 seconds, well under its 120 second limit. I ran the full gated suite a second time. That test passed there too. This was a one-time slow run under load, not a real bug.

    Files changed: none.
  timestamp: 2026-09-02T21:56:18.851087+00:00
- actor: claude-code
  id: 01m1j27me1wnzx40mwcrf6nw2j
  text: |-
    ### finish iteration 2 — test: red, stuck on a true conflict outside this card
    - implement: changed — 1 file, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift, +2 lines: a `// swiftlint:disable:next no_direct_standard_out_logs <reason>` directive above each of the two `print` calls. Both review findings of 2026-09-02 16:02 are checked. `swift build --package-path IntegrationTests --build-tests`: exit 0, 0 repository warnings.
    - test: red — `swift build`: exit 0; `swift test`: 1216 tests in 131 suites with 2 known issues, plus 83 tests in 10 suites, exit 0; `swift build --package-path IntegrationTests --build-tests`: exit 0; `swift test --package-path IntegrationTests`: 34 tests in 17 suites, 1 failed, plus 2 tests in 2 suites, exit 1. The one failure is `CompactionSmokeIntegrationTests` "a fact planted at the very end of the folded span is still in the summary the fold stores" (CompactionSmokeIntegrationTests.swift:515). It failed the same way on three runs. This card's own suite `PinnedChatTemplateDateIntegrationTests` passed.
    - commit: no-change — the tree is red, so no commit was made. The two directive lines stay uncommitted in the working tree.
    - review: not run — the loop stopped before review.
    - why stuck: the failure is in `Summarization.cut(_:toCharacters:)` and `CompactionSmokeIntegrationTests.swift`, files this card never touched. Those files last changed at fc40844, before this card. Main moved from 37c7942 to 5c958a2 through eight commits from other sessions between the two gated runs. The tester found a true conflict between two tested rules: a stored summary must never end in the middle of a section (`theLastResortCutOfASectionedAnswerFallsOnASectionBoundary`), and a fact stated late in the folded span must survive the fold (the gated test). A person must pick the resolution. The conflict is recorded on card ^3dy1ry9, and this card now depends on it.
    - next: a person decides ^3dy1ry9. Then run `/finish ^g8rywv2` again from the test step: `swift test --package-path IntegrationTests` green, `/commit` the two directive lines, `/review HEAD~1..HEAD`.
  timestamp: 2026-09-02T22:01:04.193514+00:00
- actor: claude-code
  id: 01m1j73yh273tnpr7rf3hrdvb3
  text: |-
    ### test — green

    - evidence:
      - `swift build` — exit 0. Only the known vendor warning from the mlx-swift bundle.
      - `swift build --package-path IntegrationTests --build-tests` — exit 0. Only the known vendor warning.
      - `swift test` — exit 0. 1216 tests in 131 suites passed, 2 known issues. Plus 83 tests in 10 suites passed. Only the known vendor warning.
      - `swift test --package-path IntegrationTests --filter 'PinnedChatTemplateDateIntegrationTests'` — exit 0. 2 tests in 1 suite passed (27.9 seconds, one test ran a real model for 24.6 seconds). This is a real run, not an empty match.
      - `swift test --package-path IntegrationTests` (full gated run, real models) — exit 0. Two test runs in this invocation: 34 tests in 17 suites passed (590.7 seconds), plus 2 tests in 2 suites passed (63.1 seconds). No failures. Only the known vendor warning.
    - No failing test in any run. No warning from this repository in any run.
    - Files changed: none. The tree still holds only the pre-existing uncommitted swiftlint directive lines in `PinnedChatTemplateDateIntegrationTests.swift` and the pre-existing `.kanban/` changes. I did not edit, stage, or commit anything.
    - next: none. The card is ready for commit.

    task: 01M1F3GAF5VR9ERP1N9G8RYWV2
  timestamp: 2026-09-02T23:26:26.338691+00:00
- actor: claude-code
  id: 01m1j7ecmcef6m37tbyszpj92y
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 6f57d64), counts findings 0, confirmed 0, refuted 0. 1 file reviewed, 0 not reviewed. The two prior findings of 2026-09-02 16:02 are checked.
    - next: none. The card is in `done`.
  timestamp: 2026-09-02T23:32:08.460603+00:00
- actor: claude-code
  id: 01m1j7jhpxvdpnt6eybxncn7db
  text: |-
    ### finish iteration 3 — review: clean, card in done
    - implement: skipped, already in tree — the two `// swiftlint:disable:next no_direct_standard_out_logs <reason>` directive lines above the two `print` calls in IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift were in the working tree at pickup; both review findings of 2026-09-02 16:02 were checked; the `stuck` tag was removed because blocker ^3dy1ry9 is done (commit c04b9f9)
    - test: green — `swift build`: exit 0; `swift build --package-path IntegrationTests --build-tests`: exit 0; `swift test`: 1216 tests in 131 suites with 2 known issues, plus 83 tests in 10 suites, exit 0; `swift test --package-path IntegrationTests --filter 'PinnedChatTemplateDateIntegrationTests'`: 2 tests in 1 suite, 27.9 s, real model reply `26 Jul 2024`, exit 0; `swift test --package-path IntegrationTests`: 34 tests in 17 suites in 590.7 s, plus 2 tests in 2 suites in 63.1 s, 0 failures, exit 0. The only warning was the known vendored `missing creator for mutated node` line.
    - commit: 6f57d64 — `fix(tests): add swiftlint directives for standard-out logs in pinned date test (^g8rywv2)`, one file, +2 lines, local only
    - review: clean — `review sha HEAD~1..HEAD` (6f57d64), 0 findings, 1 file reviewed, 0 not reviewed; the card moved to done
  timestamp: 2026-09-02T23:34:24.733888+00:00
depends_on:
- 01M1J1XM0B4VWDJAZRJ3DY1RY9
position_column: done
position_ordinal: ffffc380
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
- [x] `swift test --package-path IntegrationTests` green.

## Review Findings (2026-09-02 16:02)

> Scope: `review sha fc40844..37c7942` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:168` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/PinnedChatTemplateDateIntegrationTests.swift:190` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it. #ci #real-model #router #test-reproducibility